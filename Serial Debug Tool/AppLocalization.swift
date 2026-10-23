import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: Self { self }

    var title: String {
        switch self {
        case .system: AppText.systemLanguage
        case .simplifiedChinese: AppText.simplifiedChineseName
        case .english: AppText.englishName
        }
    }
}

/// Observable lookups refresh existing views without recreating their session or editor state.
/// Serial actors also resolve messages here, so the shared language value is protected by a lock.
final class AppLocalization: Observable, @unchecked Sendable {
    static let shared = AppLocalization()
    static let preferenceKey = "app.language"

    static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        .module
        #else
        .main
        #endif
    }

    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let baseBundle: Bundle
    private let languageBundles: [AppLanguage: Bundle]
    private var storedLanguage: AppLanguage

    init(defaults: UserDefaults = .standard, bundle: Bundle = AppLocalization.resourceBundle) {
        self.defaults = defaults
        baseBundle = bundle
        storedLanguage = defaults.string(forKey: Self.preferenceKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
        languageBundles = Dictionary(uniqueKeysWithValues: AppLanguage.allCases.compactMap { language in
            guard language != .system,
                  let path = bundle.path(forResource: language.rawValue, ofType: "lproj"),
                  let localizedBundle = Bundle(path: path) else { return nil }
            return (language, localizedBundle)
        })
    }

    var language: AppLanguage {
        registrar.access(self, keyPath: \.language)
        return lock.withLock { storedLanguage }
    }

    var bundle: Bundle { languageBundles[language] ?? baseBundle }

    var locale: Locale {
        let selected = language
        return selected == .system ? .autoupdatingCurrent : Locale(identifier: selected.rawValue)
    }

    @MainActor
    func setLanguage(_ language: AppLanguage) {
        guard language != self.language else { return }
        registrar.withMutation(of: self, keyPath: \.language) {
            lock.withLock { storedLanguage = language }
            defaults.set(language.rawValue, forKey: Self.preferenceKey)
        }
    }
}
