import Foundation
import Darwin

/// One SSH process per connection. Pipes are nonblocking and only touched on this actor.
actor SSHSerialTransport {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var reader: Task<Void, Never>?
    private var readEvents: DescriptorReadEvents?
    private var readBuffer = [UInt8](repeating: 0, count: 16_384)
    private var generation = UUID()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var incoming = Data()
    private var diagnostics = Data()
    private var ready = false
    private var paths: [String]?
    private var failure: SerialTransportError?
    private var writing = false
    private var scanning = false
    private var scanComplete = false
    private(set) var supportReport: SSHSupportReport?
    private var supportGeneration = UUID()

    func checkedSupport(for token: UUID) -> SSHSupportReport? {
        supportGeneration == token ? supportReport : nil
    }
    private let executableURL: URL
    private let askPassURL: URL?
    private let knownHostsURL: URL?

    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
         askPassURL: URL? = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.url(forAuxiliaryExecutable: "ReceiveScriptWorker") : nil,
         knownHostsURL: URL? = nil) {
        self.executableURL = executableURL
        self.askPassURL = askPassURL
        self.knownHostsURL = knownHostsURL
    }

    deinit {
        reader?.cancel()
        readEvents?.cancel()
        try? input?.close()
        try? output?.close()
        try? errors?.close()
        if let process, process.isRunning { process.terminate() }
        continuation?.finish()
    }

    func scan(_ ssh: SSHConfiguration, generation token: UUID) async throws -> [SerialPort] {
        do {
            try start(ssh, configuration: nil, token: token)
            try await awaitReady(token: token, scanning: true)
            let result = paths ?? []
            close(ifGeneration: token)
            return result.map { SerialPort(path: $0) }
        } catch {
            close(ifGeneration: token)
            throw error
        }
    }

    func open(_ ssh: SSHConfiguration, configuration: SerialConfiguration, generation token: UUID) async throws -> AsyncThrowingStream<Data, Error> {
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        do {
            try start(ssh, configuration: configuration, token: token)
            continuation = pair.continuation
            continuation?.onTermination = { [weak self] _ in Task { await self?.close(ifGeneration: token) } }
            try await awaitReady(token: token, scanning: false)
            return pair.stream
        } catch {
            pair.continuation.finish()
            close(ifGeneration: token)
            throw error
        }
    }

    private func start(_ ssh: SSHConfiguration, configuration: SerialConfiguration?, token: UUID) throws {
        try Task.checkCancellation()
        guard process == nil else { throw SerialTransportError(message: AppText.disconnectFirst) }
        supportGeneration = token
        supportReport = nil
        let hosts = try knownHostsURL ?? SSHFiles.directory().appendingPathComponent("known_hosts")
        let args = try ssh.arguments(command: SSHRemoteBridge.command(configuration: configuration), knownHostsURL: hosts, interactive: askPassURL != nil)
        let child = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = executableURL
        child.arguments = args
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        child.qualityOfService = .userInitiated
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SSH_AUTH_SOCK")
        environment.removeValue(forKey: "SERIAL_DEBUG_SSH_PASSWORD_ACCOUNT")
        environment["LC_ALL"] = "C"
        if let askPassURL {
            environment["SSH_ASKPASS"] = askPassURL.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["SERIAL_DEBUG_SSH_ASKPASS"] = "1"
            environment["SERIAL_DEBUG_SSH_CONTEXT"] = ssh.authority
            environment["SERIAL_DEBUG_SSH_THEME"] = UserDefaults.standard.string(forKey: "app.theme")
            let labels = ["trustHost": AppText.sshTrustHost, "authenticate": AppText.sshAuthenticate,
                          "trust": AppText.sshTrust, "confirm": AppText.confirm,
                          "cancel": AppText.cancel, "secret": AppText.sshSecret]
            environment["SERIAL_DEBUG_SSH_LABELS"] = String(data: try JSONEncoder().encode(labels), encoding: .utf8)
            if ssh.authentication == .password {
                environment["SERIAL_DEBUG_SSH_PASSWORD_ACCOUNT"] = ssh.passwordAccount
            }
        }
        child.environment = environment
        let events = try DescriptorReadEvents(descriptors: [
            stdout.fileHandleForReading.fileDescriptor, stderr.fileHandleForReading.fileDescriptor
        ])
        child.terminationHandler = { _ in events.wake() }
        do { try child.run() }
        catch { events.cancel(); throw error }
        readEvents = events
        // Close parent-side copies of the child pipe ends so EOF is observable.
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        for handle in [stdin.fileHandleForWriting, stdout.fileHandleForReading, stderr.fileHandleForReading] {
            let fd = handle.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errors = stderr.fileHandleForReading
        generation = token
        incoming.removeAll(keepingCapacity: true)
        diagnostics.removeAll(keepingCapacity: true)
        failure = nil
        ready = false
        paths = nil
        writing = false
        scanning = configuration == nil
        scanComplete = false
        reader = Task { [weak self] in
            for await _ in events.stream {
                guard !Task.isCancelled, await self?.poll(token: token) == true else { break }
                events.rearm()
            }
        }
    }

    private func awaitReady(token: UUID, scanning: Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while true {
            if let failure { throw failure }
            guard generation == token, !Task.isCancelled else { throw CancellationError() }
            if scanning ? scanComplete : ready { return }
            guard ContinuousClock.now < deadline else { throw SerialTransportError(message: AppText.sshConnectionTimeout) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Counts bytes accepted by the SSH input pipe, not an acknowledgement from the device.
    func write(_ data: Data) async throws -> Int {
        guard ready, process != nil else { throw SerialTransportError(message: AppText.portNotConnected) }
        guard !writing else { throw SerialTransportError(message: AppText.sendInProgress) }
        guard !data.isEmpty, data.count <= 65_536 else { throw PayloadError.tooLarge }
        let token = generation
        writing = true
        defer { if generation == token { writing = false } }
        var offset = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while offset < data.count {
            if let failure { throw SerialTransportError(message: failure.message, bytesWritten: offset) }
            guard generation == token, !Task.isCancelled, let input, let process, process.isRunning else {
                throw SerialTransportError(message: AppText.sendInterrupted, bytesWritten: offset)
            }
            let count = data.withUnsafeBytes {
                Darwin.write(input.fileDescriptor, $0.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if count > 0 { offset += count }
            else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                let error = SerialTransportError(message: AppText.sshDisconnected, bytesWritten: offset)
                fail(error)
                throw error
            }
            guard ContinuousClock.now < deadline else {
                let error = SerialTransportError(message: AppText.sendTimeout, bytesWritten: offset)
                fail(error)
                throw error
            }
            if offset < data.count { try await Task.sleep(for: .milliseconds(10)) }
        }
        return offset
    }

    func close(ifGeneration token: UUID? = nil) {
        if let token, token != generation { return }
        generation = UUID()
        stopProcess()
        continuation?.finish()
        continuation = nil
        ready = false
    }

    private func stopProcess() {
        reader?.cancel()
        reader = nil
        readEvents?.cancel()
        readEvents = nil
        try? input?.close()
        try? output?.close()
        try? errors?.close()
        input = nil; output = nil; errors = nil
        if let child = process, child.isRunning {
            child.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
            }
        }
        process = nil
    }

    private func fail(_ error: SerialTransportError) {
        failure = error
        continuation?.finish(throwing: error)
        continuation = nil
        ready = false
        stopProcess()
    }

    private func poll(token: UUID) -> Bool {
        guard generation == token, let child = process, let output, let errors else { return false }
        do {
            diagnostics.append(try read(errors, limit: 16_384))
            if diagnostics.count > 8192 { diagnostics.removeFirst(diagnostics.count - 8192) }
            let data = try read(output, limit: 262_144)
            incoming.append(data)
            if supportReport == nil {
                if let end = incoming.firstIndex(of: 10) {
                    let line = Data(incoming[..<end])
                    incoming.removeSubrange(...end)
                    guard let text = String(data: line, encoding: .utf8),
                          text.hasPrefix(SSHRemoteBridge.supportPrefix) else {
                        throw SerialTransportError(message: AppText.sshInvalidResponse)
                    }
                    let fields = text.dropFirst(SSHRemoteBridge.supportPrefix.count).split(separator: "\t", omittingEmptySubsequences: false)
                    switch fields.first {
                    case "OK" where fields.count == 1:
                        supportReport = .supported
                    case "MISSING" where fields.count == 2:
                        let tools = fields[1].split(separator: " ").map(String.init)
                        guard !tools.isEmpty, tools.allSatisfy({ ["sh", "stty", "cat", "ls", "mkdir", "rmdir"].contains($0) }) else {
                            throw SerialTransportError(message: AppText.sshInvalidResponse)
                        }
                        supportReport = .missingTools(tools)
                    case "TOOLS" where fields.count == 2 && ["cat", "stty", "ls"].contains(String(fields[1])):
                        supportReport = .unusableTools(String(fields[1]))
                    case "TEMP" where fields.count == 1:
                        supportReport = .temporaryDirectoryUnavailable
                    default:
                        throw SerialTransportError(message: AppText.sshInvalidResponse)
                    }
                    if let detail = supportReport?.detail {
                        throw SerialTransportError(message: detail)
                    }
                }
                guard supportReport != nil || incoming.count <= 8192 else { throw SerialTransportError(message: AppText.sshInvalidResponse) }
                if supportReport == nil {
                    if !child.isRunning { throw remoteFailure() }
                    return true
                }
            }
            if !ready {
                let marker = SSHRemoteBridge.readyMarker
                let prefix = min(incoming.count, marker.count)
                guard incoming.prefix(prefix) == marker.prefix(prefix) else {
                    throw SerialTransportError(message: AppText.sshInvalidResponse)
                }
                if incoming.count >= marker.count {
                    incoming.removeFirst(marker.count)
                    ready = true
                }
            }
            if ready {
                if scanning {
                    while let end = incoming.firstIndex(of: 10) {
                        let line = Data(incoming[..<end])
                        incoming.removeSubrange(...end)
                        guard let path = String(data: line, encoding: .utf8) else {
                            throw SerialTransportError(message: AppText.sshInvalidResponse)
                        }
                        if path == SSHRemoteBridge.scanEnd {
                            scanComplete = true
                            paths = Array(Set(paths ?? [])).sorted()
                            stopProcess()
                            return false
                        }
                        guard path.hasPrefix("/dev/"), !path.contains("\0"), path.utf8.count <= 4096 else {
                            throw SerialTransportError(message: AppText.sshInvalidResponse)
                        }
                        if paths == nil { paths = [] }
                        paths?.append(path)
                        guard (paths?.count ?? 0) <= 2048 else {
                            throw SerialTransportError(message: AppText.sshInvalidResponse)
                        }
                    }
                } else if !incoming.isEmpty {
                    if case .dropped = continuation?.yield(incoming) {
                        throw SerialTransportError(message: AppText.receiveQueueFull)
                    }
                    incoming.removeAll(keepingCapacity: true)
                }
            }
            guard incoming.count <= 8192 else { throw SerialTransportError(message: AppText.sshInvalidResponse) }
            if !child.isRunning {
                throw remoteFailure()
            }
            return true
        } catch {
            fail(error as? SerialTransportError ?? SerialTransportError(message: error.localizedDescription))
            return false
        }
    }

    private func remoteFailure() -> SerialTransportError {
        let detail = String(data: diagnostics, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SerialTransportError(message: detail.isEmpty ? AppText.sshDisconnected : AppText.sshFailure(detail))
    }

    private func read(_ handle: FileHandle, limit: Int) throws -> Data {
        var result = Data()
        let capacity = readBuffer.count
        while result.count < limit {
            let count = Darwin.read(handle.fileDescriptor, &readBuffer, capacity)
            if count > 0 { result.append(contentsOf: readBuffer.prefix(count)) }
            else if count == 0 {
                // EOF remains readable; retire this source to avoid a busy loop.
                readEvents?.remove(handle.fileDescriptor)
                break
            }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK { break }
            else { throw SerialTransportError(message: AppText.sshDisconnected) }
        }
        return result
    }

}
