import Foundation
import Observation

/// The preset library is shared; connection settings and unsaved editor drafts remain window-local.
@MainActor
@Observable
final class CommandPresetStore {
    static let shared = CommandPresetStore()
    static let preferenceKey = "serial.presets.v1"

    private(set) var presets: [CommandPreset]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        presets = defaults.data(forKey: Self.preferenceKey)
            .flatMap { try? JSONDecoder().decode([CommandPreset].self, from: $0) } ?? []
    }

    func append(_ preset: CommandPreset) {
        presets.append(preset)
        save()
    }

    @discardableResult
    func update(_ preset: CommandPreset) -> Bool {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return false }
        presets[index] = preset
        save()
        return true
    }

    func remove(id: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets.remove(at: index)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: Self.preferenceKey)
    }
}
