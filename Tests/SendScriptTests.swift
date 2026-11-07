import Foundation
import Testing
@testable import SerialDebugToolCore

private let sendWorkerPath = ProcessInfo.processInfo.environment["SERIAL_SCRIPT_WORKER"]

@Suite("Send script library")
@MainActor
struct SendScriptLibraryTests {
    @Test func librariesPersistIndependentlyAndKeepTheirExamples() throws {
        let domain = "SerialDebugTool.SendLibraryTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let receive = ReceiveScriptStore(defaults: defaults)
        let send = ReceiveScriptStore(defaults: defaults, purpose: .send)
        let receiveScripts = receive.scripts
        #expect(send.scripts.count == 3)
        #expect(send.scripts.allSatisfy { $0.source.contains("function generate(input)") })
        let saved = try send.saveForApplying(name: "", source: "function generate(input) { return [0, 255]; }")
        send.remove(id: try #require(send.scripts.first).id)
        let restored = ReceiveScriptStore(defaults: defaults, purpose: .send)
        #expect(restored.scripts == send.scripts)
        #expect(restored.script(id: saved.id) == saved)
        #expect(ReceiveScriptStore(defaults: defaults).scripts == receiveScripts)
    }
}

@Suite("Programmable send worker", .enabled(if: sendWorkerPath != nil))
struct SendScriptTests {
    private func engine() throws -> SendScriptEngine {
        SendScriptEngine(executableURL: URL(fileURLWithPath: try #require(sendWorkerPath)))
    }

    @Test func textAndBinaryResultsHaveExactEncodingAndLineEndings() async throws {
        let engine = try engine()
        defer { engine.reset() }
        let text = try #require(await engine.generate(source: SendScriptExample.defaultSource, input: "中文😀", generation: UUID()))
        #expect(try text.data(encoding: .utf8, ending: .crlf) == Data("中文😀\r\n".utf8))
        let bytes = try #require(await engine.generate(source: "function generate() { return new Uint8Array([0, 128, 255]); }", input: "", generation: UUID()))
        #expect(try bytes.data(encoding: .ascii, ending: .crlf) == Data([0, 128, 255]))
        let checksum = try await engine.preview(source: SendScriptExample.checksum.source, input: "2")
        #expect(checksum == "AA 01 02 AD")
    }

    @Test func countersAreWindowLocalAndPreviewDoesNotChangeLiveState() async throws {
        let first = try engine()
        let second = try engine()
        let preview = try engine()
        defer { first.reset(); second.reset(); preview.reset() }
        let source = SendScriptExample.sequence.source
        let token = UUID()
        #expect(try await first.generate(source: source, input: "P", generation: token) == .text("P,1"))
        #expect(try await preview.preview(source: source, input: "P") == "P,1")
        #expect(try await second.generate(source: source, input: "P", generation: UUID()) == .text("P,1"))
        #expect(try await first.generate(source: source, input: "P", generation: token) == .text("P,2"))
    }

    @Test func nullSkipsAndInvalidResultsDoNotProducePackets() async throws {
        let engine = try engine()
        defer { engine.reset() }
        #expect(try await engine.generate(source: "function generate() { return null; }", input: "", generation: UUID()) == nil)
        for value in ["true", "42", "[256]", "[-1]", "[1.5]", "[true]", "new Array(16385).fill(0)"] {
            do {
                _ = try await engine.generate(source: "function generate() { return \(value); }", input: "", generation: UUID())
                Issue.record("Invalid result was accepted: \(value)")
            } catch { #expect(error is ReceiveScriptFailure) }
        }
    }

    @Test func validationAndTimeoutRecoveryUseTheIsolatedWorker() async throws {
        let engine = try engine()
        defer { engine.reset() }
        do {
            try await engine.validate(source: "function process(t) { return t; }")
            Issue.record("Missing generate function was accepted")
        } catch { #expect(error is ReceiveScriptFailure) }
        do {
            _ = try await engine.generate(source: "function generate() { while (true) {} }", input: "", generation: UUID())
            Issue.record("Infinite loop was accepted")
        } catch { #expect(error is ReceiveScriptFailure) }
        #expect(try await engine.generate(source: SendScriptExample.defaultSource, input: "OK", generation: UUID()) == .text("OK"))
    }
}
