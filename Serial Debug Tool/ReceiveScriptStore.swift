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

/// Only the library is shared. Applying a script copies its source into a window's session.
@MainActor
@Observable
final class ReceiveScriptStore {
    static let shared = ReceiveScriptStore()
    static let preferenceKey = "serial.receiveScripts.v1"

    private(set) var scripts: [SavedReceiveScript]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        scripts = defaults.data(forKey: Self.preferenceKey)
            .flatMap { try? JSONDecoder().decode([SavedReceiveScript].self, from: $0) } ?? []

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
