import Foundation
import Darwin
import Testing
@testable import SerialDebugToolCore

private struct SSHCheckError: Error { let message: String }

private final class SSHPTY {
    let master: Int32
    let slave: Int32
    let path: String
    init() throws {
        var master: Int32 = -1, slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 256)
        guard openpty(&master, &slave, &name, nil, nil) == 0 else { throw SSHCheckError(message: "openpty") }
        self.master = master; self.slave = slave
        path = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
    }
    deinit { Darwin.close(master); Darwin.close(slave) }
}

private func sshReadMaster(_ fd: Int32, count: Int) async throws -> Data {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
    while data.count < count, ContinuousClock.now < deadline {
        let n = Darwin.read(fd, &buffer, buffer.count)
        if n > 0 { data.append(contentsOf: buffer.prefix(n)) }
        else { try await Task.sleep(for: .milliseconds(5)) }
    }
    guard data.count == count else { throw SSHCheckError(message: "PTY read expected \(count), received \(data.count): \(data as NSData)") }
    return data
}

private func sshCollect(_ stream: AsyncThrowingStream<Data, Error>, count: Int) async throws -> Data {
    try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask {
            var result = Data()
            for try await chunk in stream {
                result.append(chunk)
                if result.count >= count { return result }
            }
            throw SSHCheckError(message: "Premature EOF")
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw SSHCheckError(message: "Receive timeout")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

private final class SSHFixture {
    let directory: URL
    let executable: URL
    let hosts: URL
    init(script: String? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SerialSSH-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("ssh-fixture")
        hosts = directory.appendingPathComponent("known_hosts")
        // Expose only the POSIX tools used by the remote command: no Python in PATH.
        let tools = directory.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        for tool in ["sh", "stty", "cat", "ls", "mkdir", "rmdir"] {
            try FileManager.default.createSymbolicLink(at: tools.appendingPathComponent(tool),
                                                       withDestinationURL: URL(fileURLWithPath: "/bin/" + tool))
        }
        let source = script ?? """
        #!/bin/sh
        for arg do command=$arg; done
        PATH='\(tools.path)'; export PATH
        exec /bin/sh -c "$command"
        """
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func transport() -> SSHSerialTransport {
        SSHSerialTransport(executableURL: executable, askPassURL: nil, knownHostsURL: hosts)
    }
    func replaceTool(_ name: String, source: String) throws {
        let url = directory.appendingPathComponent("tools/" + name)
        try FileManager.default.removeItem(at: url)
        try Data(source.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    var configuration: SSHConfiguration {
        SSHConfiguration(host: "localhost", username: "fixture", authentication: .privateKey,
                         identityURL: directory.appendingPathComponent("identity"))
    }
}

@Suite("SSH remote serial")
struct SSHTransportTests {
    @Test func endpointValidationAndArgumentsDoNotPermitShellOrOptionInjection() throws {
        for host in ["-oProxyCommand=bad", "host;touch /tmp/test", "host\nother", "user@host", "host/path", ""] {
            #expect(throws: SerialTransportError.self) {
                try SSHConfiguration(host: host, username: "user").validate()
            }
        }
        for user in ["-root", "user;id", "user\nroot", ""] {
            #expect(throws: SerialTransportError.self) {
                try SSHConfiguration(host: "localhost", username: user).validate()
            }
        }
        #expect(throws: SerialTransportError.self) {
            try SSHConfiguration(host: "localhost", port: 0, username: "user").validate()
        }
        let configuration = SSHConfiguration(host: "::1", port: 2222, username: "user")
        let arguments = try configuration.arguments(command: "fixed-command", knownHostsURL: URL(fileURLWithPath: "/tmp/hosts with spaces"), interactive: true)
        #expect(arguments.contains("-T"))
        #expect(arguments.contains("StrictHostKeyChecking=ask"))
        #expect(arguments.contains("UserKnownHostsFile=\"/tmp/hosts with spaces\""))
        #expect(arguments.suffix(3) == ["--", "::1", "fixed-command"])
        #expect(configuration.authority == "user@[::1]:2222")
    }

    @Test(arguments: ["stty", "cat"])
    func missingRemoteToolsAreReportedWithoutOpeningTheSerialDevice(tool: String) async throws {
        let fixture = try SSHFixture(), terminal = try SSHPTY()
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("tools/" + tool))
        var before = termios()
        #expect(tcgetattr(terminal.slave, &before) == 0)
        let transport = fixture.transport()
        await #expect(throws: SerialTransportError.self) {
            try await transport.open(fixture.configuration, configuration: SerialConfiguration(path: terminal.path), generation: UUID())
        }
        #expect(await transport.supportReport == .missingTools([tool]))
        var after = termios()
        #expect(tcgetattr(terminal.slave, &after) == 0)
        #expect(after.c_lflag == before.c_lflag)
        #expect(cfgetispeed(&after) == cfgetispeed(&before))
    }

    @Test func unusableToolsAndUnwritableLockDirectoriesAreReported() async throws {
        let brokenCat = try SSHFixture()
        try brokenCat.replaceTool("cat", source: "#!/bin/sh\nprintf 'broken'\n")
        let first = brokenCat.transport()
        await #expect(throws: SerialTransportError.self) { try await first.scan(brokenCat.configuration, generation: UUID()) }
        #expect(await first.supportReport == .unusableTools("cat"))

        let brokenStty = try SSHFixture()
        try brokenStty.replaceTool("stty", source: "#!/bin/sh\nexit 0\n")
        let invalidTerminalTool = brokenStty.transport()
        await #expect(throws: SerialTransportError.self) { try await invalidTerminalTool.scan(brokenStty.configuration, generation: UUID()) }
        #expect(await invalidTerminalTool.supportReport == .unusableTools("stty"))

        let noLock = try SSHFixture()
        try noLock.replaceTool("mkdir", source: "#!/bin/sh\nexit 1\n")
        let second = noLock.transport()
        await #expect(throws: SerialTransportError.self) { try await second.scan(noLock.configuration, generation: UUID()) }
        #expect(await second.supportReport == .temporaryDirectoryUnavailable)
    }

    @MainActor
    @Test func supportCheckNeedsNoDeviceAndResultsStayLocalToTheirHostAndWindow() async throws {
        let fixture = try SSHFixture(), missing = try SSHFixture()
        try FileManager.default.removeItem(at: missing.directory.appendingPathComponent("tools/stty"))
        let domain = "SerialSSH.SupportTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let first = SerialSession(defaults: defaults, sshScanner: fixture.transport())
        let second = SerialSession(defaults: defaults, sshScanner: missing.transport())
        for session in [first, second] {
            session.connectionMode = .ssh
            session.sshHost = "localhost"
            session.sshUsername = "fixture"
        }
        await first.refreshPorts()
        #expect(first.sshSupportStatus == .checked(.supported))
        #expect(!first.isConnected && first.sentBytes == 0 && first.receivedBytes == 0)
        #expect(second.sshSupportStatus == .unchecked)
        await second.refreshPorts()
        #expect(second.sshSupportStatus == .checked(.missingTools(["stty"])))
        #expect(first.sshSupportStatus == .checked(.supported))
        first.sshHost = "other-host"
        #expect(first.sshSupportStatus == .unchecked)
        #expect(first.remotePorts.isEmpty)
        first.sshPort = "invalid"
        await first.refreshPorts()
        guard case .failed = first.sshSupportStatus else {
            Issue.record("Invalid settings must not reuse a previous successful report")
            return
        }
        #expect(second.sshSupportStatus == .checked(.missingTools(["stty"])))
    }

    @MainActor
    @Test func authenticationFailureIsNotMisreportedAsAnUnsupportedPlatform() async throws {
        let fixture = try SSHFixture(script: "#!/bin/sh\nprintf 'Permission denied (publickey).\\n' >&2\nexit 255\n")
        let session = SerialSession(sshScanner: fixture.transport())
        session.connectionMode = .ssh
        session.sshHost = "localhost"
        session.sshUsername = "fixture"
        await session.refreshPorts()
        guard case .failed(let detail) = session.sshSupportStatus else {
            Issue.record("Expected a failed SSH check, got \(session.sshSupportStatus)")
            return
        }
        #expect(detail.contains("Permission denied"))
    }

    @MainActor
    @Test func deviceFailurePreservesTheSuccessfulHostCheck() async throws {
        let fixture = try SSHFixture()
        let session = SerialSession(sshTransport: fixture.transport())
        session.connectionMode = .ssh
        session.sshHost = "localhost"
        session.sshUsername = "fixture"
        session.remotePath = "/dev/serial-debug-tool-nonexistent"
        await session.connect()
        #expect(!session.isConnected)
        #expect(session.sshSupportStatus == .checked(.supported))
        #expect(session.sshDeviceError?.contains("Not a serial character device") == true)
        session.remotePath = "/dev/ttyUSB1"
        #expect(session.sshDeviceError == nil)
    }

    @MainActor
    @Test func cancellingACheckClearsTheCheckingState() async throws {
        let fixture = try SSHFixture(script: "#!/bin/sh\nexec /bin/sleep 120\n")
        let session = SerialSession(sshScanner: fixture.transport())
        session.connectionMode = .ssh
        session.sshHost = "localhost"
        session.sshUsername = "fixture"
        let task = Task { await session.refreshPorts() }
        while !session.isScanning { await Task.yield() }
        #expect(session.sshSupportStatus == .checking)
        await session.disconnect()
        await task.value
        #expect(session.sshSupportStatus == .unchecked)
        #expect(!session.isScanning)
    }

    @Test func bridgeRoundTripsBinaryWithoutTerminalEchoOrLineConversion() async throws {
        let fixture = try SSHFixture(), terminal = try SSHPTY()
        let transport = fixture.transport()
        let token = UUID()
        let stream = try await transport.open(fixture.configuration, configuration: SerialConfiguration(path: terminal.path), generation: token)
        let payload = Data((0...255).map(UInt8.init))
        #expect(try await transport.write(payload) == payload.count)
        #expect(try await sshReadMaster(terminal.master, count: payload.count) == payload)
        let received = Data([0, 255, 13, 10, 3, 27, 128, 42])
        #expect(received.withUnsafeBytes { Darwin.write(terminal.master, $0.baseAddress, received.count) } == received.count)
        #expect(try await sshCollect(stream, count: received.count) == received)
        await transport.close(ifGeneration: token)
        // A closed bridge must release the cooperative lock and restore the terminal.
        let reopened = Darwin.open(terminal.path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        #expect(reopened >= 0)
        if reopened >= 0 { Darwin.close(reopened) }
    }

    @Test func disconnectRestoresSettingsAndAllowsTheSamePortToReconnect() async throws {
        let fixture = try SSHFixture(), terminal = try SSHPTY()
        var before = termios()
        #expect(tcgetattr(terminal.slave, &before) == 0)
        let transport = fixture.transport()
        let stream = try await transport.open(fixture.configuration, configuration: SerialConfiguration(path: terminal.path), generation: UUID())
        var active = termios()
        #expect(tcgetattr(terminal.slave, &active) == 0)
        #expect(active.c_lflag & tcflag_t(ICANON | ECHO) == 0)
        #expect(active.c_oflag & tcflag_t(OPOST) == 0)
        #expect(cfgetispeed(&active) == 115200)
        await transport.close()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var restored = termios()
        repeat {
            _ = tcgetattr(terminal.slave, &restored)
            if restored.c_lflag & ~tcflag_t(PENDIN) == before.c_lflag & ~tcflag_t(PENDIN) { break }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        // macOS stty marks reprocessed input with the transient kernel flag PENDIN.
        #expect(restored.c_lflag & ~tcflag_t(PENDIN) == before.c_lflag & ~tcflag_t(PENDIN))
        #expect(restored.c_iflag == before.c_iflag)
        #expect(restored.c_oflag == before.c_oflag)
        #expect(cfgetispeed(&restored) == cfgetispeed(&before))
        let replacement = fixture.transport()
        let next = try await replacement.open(fixture.configuration, configuration: SerialConfiguration(path: terminal.path), generation: UUID())
        #expect(try await replacement.write(Data([0, 255, 13, 10])) == 4)
        #expect(try await sshReadMaster(terminal.master, count: 4) == Data([0, 255, 13, 10]))
        await replacement.close()
        _ = (stream, next)
    }

    @Test func shellQuotedDevicePathsCannotExecuteCommands() async throws {
        let fixture = try SSHFixture()
        let marker = fixture.directory.appendingPathComponent("injected")
        let path = "/dev/not-a-device'; /usr/bin/touch \(marker.path); #"
        await #expect(throws: SerialTransportError.self) {
            try await fixture.transport().open(fixture.configuration, configuration: SerialConfiguration(path: path), generation: UUID())
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func remoteErrorsAndDuplicateBridgeOwnershipDoNotReportConnected() async throws {
        let fixture = try SSHFixture(), terminal = try SSHPTY()
        let first = fixture.transport(), second = fixture.transport()
        let stream = try await first.open(fixture.configuration, configuration: SerialConfiguration(path: terminal.path), generation: UUID())
        await #expect(throws: SerialTransportError.self) {
            try await second.open(fixture.configuration, configuration: SerialConfiguration(path: terminal.path), generation: UUID())
        }
        await first.close()
        _ = stream
        await #expect(throws: SerialTransportError.self) {
            try await second.open(fixture.configuration, configuration: SerialConfiguration(path: "/not/a/device"), generation: UUID())
        }
    }

    @Test func scanListsOnlyDevicePathsAndConnectionCanBeCancelled() async throws {
        let fixture = try SSHFixture()
        let ports = try await fixture.transport().scan(fixture.configuration, generation: UUID())
        #expect(ports.allSatisfy { $0.path.hasPrefix("/dev/") })
        let slow = try SSHFixture(script: "#!/bin/sh\nexec /bin/sleep 120\n")
        let transport = slow.transport(), token = UUID()
        let opening = Task { try await transport.open(slow.configuration, configuration: SerialConfiguration(path: "/dev/ttyUSB0"), generation: token) }
        try await Task.sleep(for: .milliseconds(100))
        await transport.close(ifGeneration: token)
        await #expect(throws: CancellationError.self) { try await opening.value }
    }

    @MainActor
    @Test func remoteSessionsKeepConnectionsCountersAndPortIdentityIndependent() async throws {
        let fixture = try SSHFixture(), firstPTY = try SSHPTY(), secondPTY = try SSHPTY()
        let domain = "SerialSSH.SessionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let first = SerialSession(defaults: defaults, sshTransport: fixture.transport(), sshScanner: fixture.transport())
        let second = SerialSession(defaults: defaults, sshTransport: fixture.transport(), sshScanner: fixture.transport())
        for (session, path) in [(first, firstPTY.path), (second, secondPTY.path)] {
            session.connectionMode = .ssh
            session.sshHost = "localhost"
            session.sshUsername = "fixture"
            session.remotePath = path
            await session.connect()
            #expect(session.isConnected)
            #expect(session.errorMessage == nil)
            #expect(session.status.contains("fixture@localhost:22"))
        }
        #expect(await first.send(text: "ONE", lineEnding: LineEnding.none))
        #expect(try await sshReadMaster(firstPTY.master, count: 3) == Data("ONE".utf8))
        #expect(first.sentBytes == 3 && second.sentBytes == 0)
        await first.disconnect()
        #expect(!first.isConnected && second.isConnected)
        #expect(await second.send(text: "TWO", lineEnding: LineEnding.none))
        #expect(try await sshReadMaster(secondPTY.master, count: 3) == Data("TWO".utf8))
        await second.disconnect()
        // The local device selection is independent from the remote device path.
        #expect(defaults.string(forKey: "serial.path") == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SERIAL_SSH_TEST_PORT"] != nil))
    func realSSHConnectionRoundTripsThroughAnIsolatedLoopbackServer() async throws {
        let environment = ProcessInfo.processInfo.environment
        let portText = try #require(environment["SERIAL_SSH_TEST_PORT"])
        let port = try #require(Int(portText))
        let key = URL(fileURLWithPath: try #require(environment["SERIAL_SSH_TEST_KEY"]))
        let hosts = URL(fileURLWithPath: try #require(environment["SERIAL_SSH_TEST_HOSTS"]))
        let terminal = try SSHPTY()
        let transport = SSHSerialTransport(askPassURL: nil, knownHostsURL: hosts)
        let configuration = SSHConfiguration(host: "127.0.0.1", port: port, username: NSUserName(), authentication: .privateKey, identityURL: key)
        let stream = try await transport.open(configuration, configuration: SerialConfiguration(path: terminal.path), generation: UUID())
        let payload = Data((0...255).reversed().map(UInt8.init))
        #expect(try await transport.write(payload) == payload.count)
        #expect(try await sshReadMaster(terminal.master, count: payload.count) == payload)
        let response = Data("SSH RX\r\n".utf8)
        _ = response.withUnsafeBytes { Darwin.write(terminal.master, $0.baseAddress, response.count) }
        #expect(try await sshCollect(stream, count: response.count) == response)
        await transport.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SERIAL_SSH_TEST_ASKPASS"] != nil))
    func realSSHRequestsHostTrustAndEncryptedKeyPassphraseAndRejectsChangedHostKeys() async throws {
        let environment = ProcessInfo.processInfo.environment
        let portText = try #require(environment["SERIAL_SSH_TEST_PORT"])
        let port = try #require(Int(portText))
        let key = URL(fileURLWithPath: try #require(environment["SERIAL_SSH_TEST_ENCRYPTED_KEY"]))
        let askpass = URL(fileURLWithPath: try #require(environment["SERIAL_SSH_TEST_ASKPASS"]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SerialSSH-Trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hosts = directory.appendingPathComponent("known hosts")
        let configuration = SSHConfiguration(host: "127.0.0.1", port: port, username: NSUserName(), authentication: .privateKey, identityURL: key)
        let transport = SSHSerialTransport(askPassURL: askpass, knownHostsURL: hosts)
        _ = try await transport.scan(configuration, generation: UUID())
        #expect(FileManager.default.fileExists(atPath: hosts.path))
        let current = try String(contentsOf: hosts, encoding: .utf8)
        #expect(current.contains("[127.0.0.1]:\(port)"))
        // A different valid ED25519 key for this endpoint must be refused, even if askpass says yes.
        let clientPublic = try String(contentsOf: key.deletingLastPathComponent().appendingPathComponent("client.pub"), encoding: .utf8)
        let components = clientPublic.split(separator: " ")
        try "[127.0.0.1]:\(port) \(components[0]) \(components[1])\n".write(to: hosts, atomically: true, encoding: .utf8)
        await #expect(throws: SerialTransportError.self) {
            try await transport.scan(configuration, generation: UUID())
        }
    }
}
