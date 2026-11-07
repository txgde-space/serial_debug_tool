import Foundation
import Observation

struct SavedReceiveScript: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var source: String
}

enum ReceiveScriptStoreError: LocalizedError {
    case invalidName
    case duplicateName
    case missing
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidName: AppText.scriptInvalidName
        case .duplicateName: AppText.scriptDuplicateName
        case .missing: AppText.scriptMissing
        case .tooLarge: AppText.scriptOutputTooLarge
        }
    }
}

enum ReceiveScriptExample: CaseIterable {
    case passThrough
    case separatedFields
    case azctTelemetry

    var name: String {
        switch self {
        case .passThrough: AppText.scriptExamplePassThrough
        case .separatedFields: AppText.scriptExampleFields
        case .azctTelemetry: AppText.scriptExampleTelemetry
        }
    }

    var source: String {
        switch self {
        case .passThrough:
            """
            function process(text) {
                // Return the line unchanged. Return null to hide a line.
                return text;
            }
            """
        case .separatedFields:
            """
            function process(text) {
                // Format simple comma-separated fields for easier reading.
                return text.split(",").map(field => field.trim()).join(" | ");
            }
            """
        case .azctTelemetry:
            """
            function process(text) {
                const fields = text.split(",");
                // Keep only complete $AZCT,M telemetry records.
                if (fields[0] !== "$AZCT" || fields[1] !== "M" || fields.length < 6) {
                    return null;
                }
                return "time=" + fields[2]
                    + " | state=" + fields[3]
                    + " | voltage=" + fields[4]
                    + " | current=" + fields[5];
            }
            """
        }
    }
}

/// Only the library is shared. Applying a script copies its source into a window's session.
@MainActor
@Observable
final class ReceiveScriptStore {
    static let shared = ReceiveScriptStore()
    static let sendShared = ReceiveScriptStore(purpose: .send)
    static let preferenceKey = "serial.receiveScripts.v1"
    static let examplesInstalledKey = "serial.receiveScripts.examples.v1"

    let purpose: ScriptPurpose
    private var storageKey: String { purpose == .receive ? Self.preferenceKey : "serial.sendScripts.v1" }
    private var installedKey: String { purpose == .receive ? Self.examplesInstalledKey : "serial.sendScripts.examples.v1" }
    private(set) var scripts: [SavedReceiveScript] = []
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, purpose: ScriptPurpose = .receive) {
        self.defaults = defaults
        self.purpose = purpose
        scripts = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([SavedReceiveScript].self, from: $0) } ?? []
        if !defaults.bool(forKey: installedKey) {
            // Seed once, including upgrades from an existing custom library. Deleted or edited
            // examples stay deleted or edited on later launches.
            let examples = purpose == .receive
                ? ReceiveScriptExample.allCases.map { SavedReceiveScript(name: $0.name, source: $0.source) }
                : SendScriptExample.allCases.map { SavedReceiveScript(name: $0.name, source: $0.source) }
            for example in examples {
                var name = example.name
                var suffix = 2
                while scripts.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    name = example.name + " (\(suffix))"
                    suffix += 1
                }
                scripts.append(SavedReceiveScript(name: name, source: example.source))
            }
            persist()
            defaults.set(true, forKey: installedKey)
        }
    }

    func script(id: UUID?) -> SavedReceiveScript? {
        scripts.first { $0.id == id }
    }

    @discardableResult
    func save(name: String, source: String, replacing id: UUID? = nil) throws -> SavedReceiveScript {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw ReceiveScriptStoreError.invalidName }
        guard source.utf8.count <= purpose.sourceLimit else { throw ReceiveScriptStoreError.tooLarge }
        guard !scripts.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw ReceiveScriptStoreError.duplicateName
        }
        if let id {
            guard let index = scripts.firstIndex(where: { $0.id == id }) else {
                throw ReceiveScriptStoreError.missing
            }
            scripts[index].name = name
            scripts[index].source = source
            persist()
            return scripts[index]
        }
        let script = SavedReceiveScript(name: name, source: source)
        scripts.append(script)
        persist()
        return script
    }

    func saveForApplying(name: String, source: String, replacing id: UUID? = nil) throws -> SavedReceiveScript {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return try save(name: trimmed, source: source, replacing: id)
        }
        if let existing = script(id: id) {
            return try save(name: existing.name, source: source, replacing: id)
        }
        // Unnamed drafts get a unique localized name without overwriting another script.
        var generatedName = AppText.scriptCustom
        var suffix = 2
        while scripts.contains(where: { $0.name.caseInsensitiveCompare(generatedName) == .orderedSame }) {
            generatedName = AppText.scriptCustom + " (\(suffix))"
            suffix += 1
        }
        return try save(name: generatedName, source: source, replacing: id)
    }

    func importScript(_ file: ScriptFile) throws -> SavedReceiveScript {
        let trimmed = file.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = String((trimmed.isEmpty ? AppText.scriptCustom : trimmed).prefix(80))
        var name = base
        var suffix = 2
        while scripts.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            let ending = " (\(suffix))"
            name = String(base.prefix(max(0, 80 - ending.count))) + ending
            suffix += 1
        }
        return try save(name: name, source: file.source)
    }

    func remove(id: UUID) {
        scripts.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(scripts) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
