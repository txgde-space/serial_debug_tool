import Foundation
import Testing
@testable import SerialDebugToolCore

@Suite("Saved receive scripts")
@MainActor
struct ReceiveScriptStoreTests {
    @Test func saveRenameCopyAndDeletePersistWithStableIdentity() throws {
        let domain = "SerialDebugTool.ScriptStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = ReceiveScriptStore(defaults: defaults)
        let examples = store.scripts
        let original = try store.save(name: "  Separator  ", source: "function process(t) { return t; }")
        #expect(original.name == "Separator")
        let renamed = try store.save(name: "Telemetry", source: "function process(t) { return t.toUpperCase(); }", replacing: original.id)
        #expect(renamed.id == original.id)
        #expect(store.scripts.count == examples.count + 1)
        let copy = try store.save(name: "Telemetry Copy", source: renamed.source)
        #expect(copy.id != renamed.id)
        let restored = ReceiveScriptStore(defaults: defaults)
        #expect(restored.scripts == examples + [renamed, copy])
        restored.remove(id: renamed.id)
        #expect(ReceiveScriptStore(defaults: defaults).scripts == examples + [copy])
        #expect(throws: ReceiveScriptStoreError.self) {
            try restored.save(name: "Deleted", source: "", replacing: renamed.id)
        }
        #expect(restored.scripts == examples + [copy])
    }

    @Test func invalidNamesAndDuplicateNamesDoNotOverwriteSavedScripts() throws {
        let domain = "SerialDebugTool.ScriptStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = ReceiveScriptStore(defaults: defaults)
        let examples = store.scripts
        let original = try store.save(name: "Decode", source: "original")
        for name in ["", "   ", "decode", String(repeating: "x", count: 81)] {
            #expect(throws: ReceiveScriptStoreError.self) { try store.save(name: name, source: "replacement") }
        }
        #expect(throws: ReceiveScriptStoreError.self) {
            try store.save(name: "Large", source: String(repeating: "x", count: 65_537))
        }
        #expect(ReceiveScriptStore(defaults: defaults).scripts == examples + [original])
    }

    @Test func libraryEditsDoNotChangeScriptsAlreadyAppliedToWindows() throws {
        let domain = "SerialDebugTool.ScriptStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = ReceiveScriptStore(defaults: defaults)
        let presets = CommandPresetStore(defaults: defaults)
        let first = SerialSession(defaults: defaults, presetStore: presets)
        let second = SerialSession(defaults: defaults, presetStore: presets)
        let saved = try store.save(name: "One", source: "function process(t) { return 'one'; }")
        first.configurePreprocessing(source: saved.source, enabled: false, scriptID: saved.id)
        second.configurePreprocessing(source: "function process(t) { return 'two'; }", enabled: false)
        try store.save(name: "Changed", source: "function process(t) { return 'changed'; }", replacing: saved.id)
        store.remove(id: saved.id)
        #expect(first.scriptSource == saved.source && first.activeScriptID == saved.id)
        #expect(second.scriptSource.contains("two") && second.activeScriptID == nil)
        #expect(!first.preprocessingEnabled && !second.preprocessingEnabled)
    }

    @Test func examplesInstallOnceAndPreserveUserEditsAndDeletions() throws {
        let domain = "SerialDebugTool.ScriptStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = ReceiveScriptStore(defaults: defaults)
        #expect(store.scripts.count == 3)
        let first = try #require(store.scripts.first)
        let last = try #require(store.scripts.last)
        try store.save(name: "My edited example", source: "function process(t) { return 'edited'; }", replacing: first.id)
        store.remove(id: last.id)
        let restored = ReceiveScriptStore(defaults: defaults)
        #expect(restored.scripts == store.scripts)
        #expect(restored.scripts.count == 2)
    }

    @Test func existingLibraryKeepsCustomScriptsAndNamesWhenExamplesAreAdded() throws {
        let domain = "SerialDebugTool.ScriptStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let custom = SavedReceiveScript(name: ReceiveScriptExample.passThrough.name, source: "custom code")
        defaults.set(try JSONEncoder().encode([custom]), forKey: ReceiveScriptStore.preferenceKey)
        let store = ReceiveScriptStore(defaults: defaults)
        #expect(store.scripts.count == 4)
        #expect(store.scripts.first == custom)
        #expect(Set(store.scripts.map(\.name)).count == 4)
        #expect(ReceiveScriptStore(defaults: defaults).scripts == store.scripts)
    }
}
