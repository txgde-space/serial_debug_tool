import Foundation

enum ReceiveScriptFailure: Error, Sendable, Codable, LocalizedError {
    case invalidFunction
    case invalidResult
    case lineTooLong
    case outputTooLarge
    case backlog
    case timeout
    case exception(String)
    case worker(String)

    var errorDescription: String? {
        switch self {
        case .invalidFunction: AppText.scriptInvalidFunction
        case .invalidResult: AppText.scriptInvalidResult
        case .lineTooLong: AppText.scriptLineTooLong
        case .outputTooLarge: AppText.scriptOutputTooLarge
        case .backlog: AppText.scriptBacklog
        case .timeout: AppText.scriptTimeout
        case .exception(let message), .worker(let message): message
        }
    }
}

struct ReceiveScriptRequest: Codable {
    var source: String?
    var lines: [String] = []
}

struct ReceiveScriptReply: Codable {
    var outputs: [String?] = []
    var failure: ReceiveScriptFailure?
}

enum ReceiveScriptWorker {
    static var executableURL: URL? { Bundle.main.url(forAuxiliaryExecutable: "ReceiveScriptWorker") }
    static let defaultSource = """
    function process(text) {
        return text;
    }
    """
}

/// Owns one persistent interpreter process. Used only on a dedicated serial queue.
final class ReceiveScriptProcess {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?

    deinit { stop() }

    func stop() {
        try? input?.close()
        try? output?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        output = nil
    }

    func start(source: String, executableURL: URL? = ReceiveScriptWorker.executableURL) throws {
        stop()
        guard let executableURL else { throw ReceiveScriptFailure.worker(AppText.scriptWorkerUnavailable) }
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = executableURL
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        child.qualityOfService = .utility
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        _ = try request(ReceiveScriptRequest(source: source))
    }

    func request(_ request: ReceiveScriptRequest) throws -> [String?] {
        guard let process, let input, let output, process.isRunning else {
            throw ReceiveScriptFailure.worker(AppText.scriptWorkerUnavailable)
        }
        // The deadline includes pipe I/O, script initialization, and all lines in this batch.
        // Terminating the child unblocks the reader even if JavaScript never returns.
        let deadline = DispatchWorkItem { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: deadline)
        defer { deadline.cancel() }
        do {
            var data = try JSONEncoder().encode(request)
            data.append(10)
            try input.write(contentsOf: data)
            var response = Data()
            while response.last != 10 {
                // availableData returns a pipe fragment immediately; read(upToCount:) may
                // wait for its full requested length and stall a persistent worker.
                let chunk = output.availableData
                guard !chunk.isEmpty else { throw ReceiveScriptFailure.timeout }
                response.append(chunk)
                guard response.count <= 262_144 else { throw ReceiveScriptFailure.outputTooLarge }
            }
            let reply = try JSONDecoder().decode(ReceiveScriptReply.self, from: response)
            if let failure = reply.failure { throw failure }
            guard reply.outputs.count == request.lines.count else {
                throw ReceiveScriptFailure.invalidResult
            }
            return reply.outputs
        } catch {
            stop()
            throw error
        }
    }
}

/// A bounded line assembler independent of device-read boundaries and TX/SYS messages.
struct ReceiveLineAssembler {
    private var text = ""
    private var date: Date?
    private var byteCount = 0
    private var swallowLF = false

    mutating func append(_ entry: LogEntry) throws -> [LogEntry] {
        var lines: [LogEntry] = []
        for scalar in entry.text.unicodeScalars {
            if swallowLF {
                swallowLF = false
                if scalar == "\n" { continue }
            }
            if scalar == "\r" || scalar == "\n" {
                lines.append(LogEntry(date: date ?? entry.date, direction: .received, data: Data(), text: text))
                text = ""
                date = nil
                byteCount = 0
                swallowLF = scalar == "\r"
            } else {
                if date == nil { date = entry.date }
                text.unicodeScalars.append(scalar)
                byteCount += scalar.utf8.count
                guard byteCount <= 65_536 else { throw ReceiveScriptFailure.lineTooLong }
            }
        }
        return lines
    }
}

/// All interpreter and framing state stays on this queue, independently for each window.
final class ReceiveScriptEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "serial.receive-script", qos: .utility)
    private let worker = ReceiveScriptProcess()
    private var assembler = ReceiveLineAssembler()
    private var generation: UUID?
    private let executableURL: URL?

    init(executableURL: URL? = ReceiveScriptWorker.executableURL) {
        self.executableURL = executableURL
    }

    func reset() {
        queue.async { [self] in
            worker.stop()
            assembler = ReceiveLineAssembler()
            generation = nil
        }
    }

    func transform(_ entries: [LogEntry], source: String, generation token: UUID) async throws -> [LogEntry] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    if generation != token {
                        assembler = ReceiveLineAssembler()
                        try worker.start(source: source, executableURL: executableURL)
                        generation = token
                    }
                    var framed: [LogEntry] = []
                    for entry in entries {
                        if entry.direction == .received {
                            framed.append(contentsOf: try assembler.append(entry))
                        } else {
                            framed.append(entry)
                        }
                    }
                    let lines = framed.filter { $0.direction == .received }.map(\.text)
                    let outputs = lines.isEmpty ? [] : try worker.request(ReceiveScriptRequest(lines: lines))
                    var next = 0
                    var result: [LogEntry] = []
                    for var entry in framed {
                        if entry.direction == .received {
                            defer { next += 1 }
                            guard let output = outputs[next], !output.isEmpty else { continue }
                            entry.text = output + "\n"
                        }
                        result.append(entry)
                    }
                    continuation.resume(returning: result)
                } catch {
                    worker.stop()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func preview(source: String, text: String) async throws -> String {
        // A preview always uses a fresh VM and never changes a live connection's script state.
        let terminated = text.hasSuffix("\n") || text.hasSuffix("\r") ? text : text + "\n"
        let entries = [LogEntry(date: Date(), direction: .received, data: Data(), text: terminated)]
        let result = try await transform(entries, source: source, generation: UUID())
        reset()
        return result.map(\.text).joined()
    }
}
