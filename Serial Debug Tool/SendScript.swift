import Foundation

enum SendScriptExample: CaseIterable {
    case text, sequence, checksum

    var name: String {
        switch self {
        case .text: AppText.sendExampleText
        case .sequence: AppText.sendExampleSequence
        case .checksum: AppText.sendExampleChecksum
        }
    }

    var source: String {
        Self.usageNotes + "\n\n" + body
    }

    static var defaultSource: String { Self.text.source }

    private static let usageNotes = """
    // 输入框可以留空；以下示例会使用默认值。
    // 「定时发送」按定时发送间隔反复调用 generate(input)，无需写无限循环。
    // 状态在本轮定时发送中保留；停止后重新启动会重置。
    // Input may be empty; these examples use a default value.
    // Repeat calls generate(input) at the panel interval; do not write an infinite loop.
    // State persists for the current repeat run and resets when stopped and restarted.
    """

    /// Upgrade saved examples without replacing their code, names, or user comments.
    static func addingUsageNotesIfNeeded(to source: String) -> String {
        guard !source.hasPrefix(usageNotes) else { return source }
        let code = executableLines(in: source)
        guard allCases.contains(where: { executableLines(in: $0.body) == code }) else { return source }
        let updated = source.replacingOccurrences(
            of: "按界面间隔反复调用 generate(input)",
            with: "按定时发送间隔反复调用 generate(input)"
        )
        return updated.hasPrefix(usageNotes) ? updated : usageNotes + "\n\n" + updated
    }

    private static func executableLines(in source: String) -> [String] {
        source.components(separatedBy: .newlines).filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return !line.isEmpty && !line.hasPrefix("//")
        }
    }

    private var body: String {
        switch self {
        case .text:
            """
            function generate(input) {
                // 留空时发送 HELLO / Send HELLO when input is empty.
                return input || "HELLO";
            }
            """
        case .sequence:
            """
            let sequence = 0;
            function generate(input) {
                // 每次调用递增一次，留空时使用 PING / Increment once per call; default: PING.
                sequence += 1;
                return (input || "PING") + "," + sequence;
            }
            """
        case .checksum:
            """
            function generate(input) {
                // 字节数组原样发送，不追加行尾 / Send exact bytes, without a line ending.
                // 留空时使用 1，也可以输入 0–255 的整数 / Default: 1; accepts integers 0–255.
                const value = Number(input || 1);
                if (!Number.isInteger(value) || value < 0 || value > 255) {
                    throw new Error("Enter an integer from 0 to 255.");
                }
                const frame = [0xAA, 0x01, value];
                frame.push(frame.reduce((sum, byte) => (sum + byte) & 0xFF, 0));
                return frame;
            }
            """
        }
    }
}

/// Runs in a separate interpreter from receive processing and every other window.
/// The adapter reuses the bounded worker protocol; no serial handle is exposed to scripts.
final class SendScriptEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "serial.send-script", qos: .utility)
    private let worker = ReceiveScriptProcess()
    private let executableURL: URL?
    private var generation: UUID?

    init(executableURL: URL? = ReceiveScriptWorker.executableURL) {
        self.executableURL = executableURL
    }

    func reset() {
        queue.async { [self] in
            worker.stop()
            generation = nil
        }
    }

    func validate(source: String) async throws {
        _ = try await execute(source: source, input: nil, generation: UUID())
        reset()
    }

    func generate(source: String, input: String, generation: UUID) async throws -> SendScriptPayload? {
        try await execute(source: source, input: input, generation: generation)
    }

    func preview(source: String, input: String) async throws -> String {
        defer { reset() }
        guard let payload = try await generate(source: source, input: input, generation: UUID()) else { return "" }
        switch payload {
        case .text(let text): return text
        case .bytes(let data): return PayloadCodec.hex(data)
        }
    }

    private func execute(source: String, input: String?, generation token: UUID) async throws -> SendScriptPayload? {
        // Leave room for the adapter inside the worker's 64 KB source limit.
        guard source.utf8.count <= 60_000, (input?.utf8.count ?? 0) <= 65_536 else {
            throw ReceiveScriptFailure.outputTooLarge
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    if generation != token {
                        try worker.start(source: Self.adapt(source), executableURL: executableURL)
                        generation = token
                    }
                    guard let input else {
                        continuation.resume(returning: nil)
                        return
                    }
                    guard let output = try worker.request(ReceiveScriptRequest(lines: [input])).first ?? nil else {
                        continuation.resume(returning: nil)
                        return
                    }
                    if output.hasPrefix("T") {
                        continuation.resume(returning: .text(String(output.dropFirst())))
                    } else if output.hasPrefix("B") {
                        let bytes = try PayloadCodec.encode(String(output.dropFirst()), hex: true, encoding: .utf8, ending: .none)
                        continuation.resume(returning: .bytes(bytes))
                    } else {
                        throw ReceiveScriptFailure.invalidResult
                    }
                } catch {
                    worker.stop()
                    generation = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func adapt(_ source: String) -> String {
        let functionError = String(data: (try? JSONEncoder().encode(AppText.sendScriptInvalidFunction)) ?? Data(), encoding: .utf8) ?? "\"generate(input)\""
        let resultError = String(data: (try? JSONEncoder().encode(AppText.sendScriptInvalidResult)) ?? Data(), encoding: .utf8) ?? "\"Invalid result\""
        return source + """

        ;(() => {
            if (typeof generate !== "function") throw new Error(\(functionError));
            const makePayload = generate;
            globalThis.process = function(input) {
                const value = makePayload(input);
                if (value === null) return null;
                if (typeof value === "string") return value.length ? "T" + value : null;
                if (Array.isArray(value) || value instanceof Uint8Array) {
                    if (value.length > 16384) throw new Error(\(resultError));
                    if (!value.length) return null;
                    let hex = "";
                    for (const byte of value) {
                        if (typeof byte !== "number" || !Number.isInteger(byte) || byte < 0 || byte > 255) {
                            throw new Error(\(resultError));
                        }
                        hex += byte.toString(16).padStart(2, "0");
                    }
                    return "B" + hex;
                }
                throw new Error(\(resultError));
            };
        })();
        """
    }
}

enum SendScriptPayload: Equatable, Sendable {
    case text(String)
    case bytes(Data)

    func data(encoding: TextEncoding, ending: LineEnding) throws -> Data {
        switch self {
        case .text(let text): try PayloadCodec.encode(text, hex: false, encoding: encoding, ending: ending)
        case .bytes(let data): data
        }
    }
}

enum ScriptPurpose {
    case receive, send

    var title: String { self == .receive ? AppText.scriptTitle : AppText.sendScriptTitle }
    var enableTitle: String { self == .receive ? AppText.scriptEnable : AppText.sendScriptEnable }
    var defaultSource: String { self == .receive ? ReceiveScriptWorker.defaultSource : SendScriptExample.defaultSource }
    var sourceLimit: Int { self == .receive ? 65_536 : 60_000 }
}
