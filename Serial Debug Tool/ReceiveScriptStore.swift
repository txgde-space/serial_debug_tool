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
    static let preferenceKey = "serial.receiveScripts.v1"
    static let examplesInstalledKey = "serial.receiveScripts.examples.v1"

    private(set) var scripts: [SavedReceiveScript]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        scripts = defaults.data(forKey: Self.preferenceKey)
            .flatMap { try? JSONDecoder().decode([SavedReceiveScript].self, from: $0) } ?? []
        if !defaults.bool(forKey: Self.examplesInstalledKey) {
            // Seed once, including upgrades from an existing custom library. Deleted or edited
            // examples stay deleted or edited on later launches.
            for example in ReceiveScriptExample.allCases {
                var name = example.name
                var suffix = 2
                while scripts.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    name = example.name + " (\(suffix))"
                    suffix += 1
                }
                scripts.append(SavedReceiveScript(name: name, source: example.source))
            }
            persist()
            defaults.set(true, forKey: Self.examplesInstalledKey)
        }
    }

    func script(id: UUID?) -> SavedReceiveScript? {
        scripts.first { $0.id == id }
    }

    @discardableResult
    func save(name: String, source: String, replacing id: UUID? = nil) throws -> SavedReceiveScript {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw ReceiveScriptStoreError.invalidName }
        guard source.utf8.count <= 65_536 else { throw ReceiveScriptStoreError.tooLarge }
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

    func remove(id: UUID) {
        scripts.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(scripts) else { return }
        defaults.set(data, forKey: Self.preferenceKey)
    }
}
