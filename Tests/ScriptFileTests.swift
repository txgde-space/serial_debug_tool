import Foundation
import Testing
@testable import SerialDebugToolCore

@Suite("Local JavaScript files")
@MainActor
struct ScriptFileTests {
    @Test func unicodeScriptRoundTripsWithAndWithoutUTF8BOM() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "// 中文🙂\r\nfunction generate(input) { return input || '你好'; }\r\n"
        let url = directory.appendingPathComponent("流程.js")
        for bom in [false, true] {
            var data = bom ? Data([0xEF, 0xBB, 0xBF]) : Data()
            data.append(Data(source.utf8))
            try data.write(to: url)
            let imported = try ScriptFile.read(from: url, sourceLimit: 60_000)
            #expect(imported.name == "流程")
            #expect(imported.source == source)
        }
    }

    @Test func oversizedAndInvalidEncodingFilesAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("script.js")
        for count in [60_001, 1_000_000] {
            try Data(repeating: 65, count: count).write(to: url)
            #expect(throws: ScriptFileError.self) { try ScriptFile.read(from: url, sourceLimit: 60_000) }
        }
        #expect(throws: ScriptFileError.self) { try ScriptFile.decode(Data([0xFF, 0xFE, 0x41]), sourceLimit: 100) }
        var exactLimit = Data([0xEF, 0xBB, 0xBF])
        exactLimit.append(Data(repeating: 65, count: 60_000))
        #expect(try ScriptFile.decode(exactLimit, sourceLimit: 60_000).utf8.count == 60_000)
    }

    @Test func importsCreateUniqueLibraryEntriesWithoutChangingActiveScripts() throws {
        let domain = "SerialDebugTool.ScriptFileTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = SerialSession(defaults: defaults, presetStore: CommandPresetStore(defaults: defaults))
        let originalReceive = session.scriptSource
        let originalSend = session.sendScriptSource
        for purpose in [ScriptPurpose.receive, .send] {
            let store = ReceiveScriptStore(defaults: defaults, purpose: purpose)
            let count = store.scripts.count
            let original = try store.save(name: "Shared", source: "original")
            // Importing stores source without executing it or applying it to a session.
            let imported = try store.importScript(ScriptFile(name: "Shared", source: "throw new Error('not executed');"))
            let second = try store.importScript(ScriptFile(name: "Shared", source: "second"))
            #expect(Set([original.name, imported.name, second.name]).count == 3)
            #expect(Set([original.id, imported.id, second.id]).count == 3)
            #expect(store.script(id: original.id)?.source == "original")
            let restored = ReceiveScriptStore(defaults: defaults, purpose: purpose)
            #expect(restored.scripts.count == count + 3)
            #expect(restored.script(id: imported.id)?.source == imported.source)
        }
        #expect(session.scriptSource == originalReceive)
        #expect(session.sendScriptSource == originalSend)
        #expect(!session.preprocessingEnabled && !session.sendScriptEnabled)
    }

    @Test func filenameHandlingAndLongDuplicateNamesStayValid() throws {
        #expect(ScriptFile.exportFilename(name: " Test ") == "Test.js")
        #expect(ScriptFile.exportFilename(name: "test.JS") == "test.JS")
        #expect(ScriptFile.exportFilename(name: "a/b:c") == "a-b-c.js")
        let domain = "SerialDebugTool.ScriptFileTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = ReceiveScriptStore(defaults: defaults, purpose: .send)
        let file = ScriptFile(name: String(repeating: "中", count: 100), source: "function generate() { return null; }")
        let first = try store.importScript(file)
        let second = try store.importScript(file)
        #expect(first.name.count == 80 && second.name.count == 80)
        #expect(first.name != second.name)
    }
}
