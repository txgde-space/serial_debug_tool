import Foundation
import Testing
@testable import SerialDebugToolCore

private func rx(_ text: String, date: Date = .distantPast) -> LogEntry {
    LogEntry(date: date, direction: .received, data: Data(text.utf8), text: text)
}

private let scriptWorkerPath = ProcessInfo.processInfo.environment["SERIAL_SCRIPT_WORKER"]

@Suite("RX line preprocessing")
struct ReceiveLineTests {
    @Test func fragmentsCRLFSplitAndBlankLinesPreserveBoundaries() throws {
        var lines = ReceiveLineAssembler()
        #expect(try lines.append(rx("$AZCT,P,ID")).isEmpty)
        let first = try lines.append(rx("LE\r"))
        #expect(first.map(\.text) == ["$AZCT,P,IDLE"])
        #expect(first.first?.date == .distantPast)
        #expect(try lines.append(rx("\n\nnext\nlast")).map(\.text) == ["", "next"])
        #expect(try lines.append(rx(" part\r\n")).map(\.text) == ["last part"])
    }

    @Test func oversizedUnterminatedLineFails() throws {
        var lines = ReceiveLineAssembler()
        #expect(throws: ReceiveScriptFailure.self) {
            try lines.append(rx(String(repeating: "x", count: 65_537)))
        }
    }
}

// Set SERIAL_SCRIPT_WORKER to the built helper to exercise the real process and wire format.
@Suite("JavaScript worker integration", .enabled(if: scriptWorkerPath != nil))
struct ReceiveScriptTests {
    private func engine() throws -> ReceiveScriptEngine {
        ReceiveScriptEngine(executableURL: URL(fileURLWithPath: try #require(scriptWorkerPath)))
    }

    @Test func stateFilteringAndWindowsStayIndependent() async throws {
        let first = try engine()
        let second = try engine()
        defer { first.reset(); second.reset() }
        let source = "let n = 0; function process(text) { return text === 'skip' ? null : (++n) + ':' + text; }"
        let token = UUID()
        #expect(try await first.transform([rx("par")], source: source, generation: token).isEmpty)
        let result = try await first.transform([rx("t\r"), rx("\nskip\nsecond\n")], source: source, generation: token)
        #expect(result.map(\.text) == ["1:part\n", "2:second\n"])
        let other = try await second.transform([rx("new\n")], source: source, generation: UUID())
        #expect(other.map(\.text) == ["1:new\n"])
        let reset = try await first.transform([rx("reset\n")], source: source, generation: UUID())
        #expect(reset.map(\.text) == ["1:reset\n"])
    }

    @Test func previewKeepsUnicodeAndDoesNotAddABlankLine() async throws {
        let worker = try engine()
        defer { worker.reset() }
        let result = try await worker.preview(source: "function process(text) { return text.replace(/,/g, ' | '); }", text: "中文,😀\r\n")
        #expect(result == "中文 | 😀\n")
    }

    @Test func badScriptsFailAndCanBeReplaced() async throws {
        let worker = try engine()
        defer { worker.reset() }
        for source in ["function process( {", "const process = 3;", "function process(t) { return 42; }", "function process(t) { throw new Error('example'); }"] {
            do {
                _ = try await worker.transform([rx("line\n")], source: source, generation: UUID())
                Issue.record("Invalid script unexpectedly succeeded")
            } catch { #expect(error is ReceiveScriptFailure) }
        }
        let result = try await worker.transform([rx("ok\n")], source: ReceiveScriptWorker.defaultSource, generation: UUID())
        #expect(result.map(\.text) == ["ok\n"])
    }

    @Test(arguments: ["function process(t) { while (true) {} }", "while (true) {}"])
    func infiniteLoopTimesOutAndWorkerRecovers(source: String) async throws {
        let worker = try engine()
        defer { worker.reset() }
        let started = ContinuousClock.now
        do {
            _ = try await worker.transform([rx("x\n")], source: source, generation: UUID())
            Issue.record("An infinite loop unexpectedly succeeded")
        } catch {
            #expect(error is ReceiveScriptFailure)
        }
        #expect(started.duration(to: .now) < .seconds(4))
        let result = try await worker.transform([rx("recovered\n")], source: ReceiveScriptWorker.defaultSource, generation: UUID())
        #expect(result.map(\.text) == ["recovered\n"])
    }
}
