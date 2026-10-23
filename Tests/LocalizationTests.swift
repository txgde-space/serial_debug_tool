import Foundation
import Observation
import Testing
@testable import SerialDebugToolCore

@Suite("Localization and saved preset compatibility")
struct LocalizationTests {
    @MainActor
    @Test func languageDefaultsToSystemAndRestoresTheSavedSelection() throws {
        let domain = "SerialDebugTool.LanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let localization = AppLocalization(defaults: defaults)
        #expect(localization.language == .system)
        localization.setLanguage(.english)
        #expect(AppLocalization(defaults: defaults).language == .english)
        localization.setLanguage(.system)
        #expect(localization.bundle.bundleURL == AppLocalization.resourceBundle.bundleURL)
        defaults.set("unsupported-language", forKey: AppLocalization.preferenceKey)
        #expect(AppLocalization(defaults: defaults).language == .system)
    }

    @MainActor
    @Test func languageOverridesResolveTextWithoutChangingTheSystemPreference() throws {
        let domain = "SerialDebugTool.LanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let originalLanguages = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String]
        let localization = AppLocalization(defaults: defaults)
        for (language, expected) in [(AppLanguage.english, "Disconnected"), (.simplifiedChinese, "未连接")] {
            localization.setLanguage(language)
            let text = String(localized: "status.disconnected", defaultValue: "Disconnected", bundle: localization.bundle, locale: localization.locale)
            #expect(text == expected)
        }
        #expect(UserDefaults.standard.array(forKey: "AppleLanguages") as? [String] == originalLanguages)
    }

    @MainActor
    @Test func changingLanguageInvalidatesObservedLookups() async throws {
        let domain = "SerialDebugTool.LanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let localization = AppLocalization(defaults: defaults)
        await confirmation("Existing views are notified when language changes") { changed in
            withObservationTracking {
                _ = localization.bundle
                _ = localization.locale
            } onChange: {
                changed()
            }
            localization.setLanguage(.english)
        }
    }

    private func languageBundle(_ language: String) throws -> Bundle {
        let path = try #require(AppLocalization.resourceBundle.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    private func strings(_ language: String) throws -> [String: String] {
        let bundle = try languageBundle(language)
        let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings"))
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(plist as? [String: String])
    }

    @Test func resourceKeysAndFormatArgumentsMatch() throws {
        let english = try strings("en")
        let chinese = try strings("zh-Hans")
        #expect(Set(english.keys) == Set(chinese.keys))
        let arguments = try NSRegularExpression(pattern: #"%\d+\$(?:lld|d|@)"#)
        func placeholders(_ text: String) -> [String] {
            arguments.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { (text as NSString).substring(with: $0.range) }.sorted()
        }
        for (key, value) in english {
            let translation = try #require(chinese[key])
            #expect(!value.isEmpty && !translation.isEmpty, "Missing text: \(key)")
            #expect(placeholders(value) == placeholders(translation), "Argument mismatch: \(key)")
        }
    }

    @Test(arguments: ["en", "zh-Hans"])
    func dynamicMessagesKeepTheirArguments(_ language: String) throws {
        let bundle = try languageBundle(language)
        let locale = Locale(identifier: language)
        let path = "/dev/cu.test"
        let configuration = "115200 · 8N1"
        let flowControl = "RTS/CTS"
        let connected = String(localized: "log.connected", defaultValue: "Connected to \(path) · \(configuration) · Flow control: \(flowControl)", bundle: bundle, locale: locale)
        #expect(connected == (language == "en"
            ? "Connected to /dev/cu.test · 115200 · 8N1 · Flow control: RTS/CTS"
            : "已连接 /dev/cu.test · 115200 · 8N1 · 流控 RTS/CTS"))
        let name = "测试 % @ 🙂"
        let deletion = String(localized: "preset.delete", defaultValue: "Delete preset “\(name)”", bundle: bundle, locale: locale)
        #expect(deletion == (language == "en" ? "Delete preset “测试 % @ 🙂”" : "删除预设“测试 % @ 🙂”"))
    }

    @Test func englishCountsUseSingularAndPlural() throws {
        let bundle = try languageBundle("en")
        let locale = Locale(identifier: "en")
        for count in [0, 1, 2] {
            let presets = String(localized: "preset.count", defaultValue: "\(count) presets", bundle: bundle, locale: locale)
            let bytes = String(localized: "counter.bytes", defaultValue: "\(count) bytes", bundle: bundle, locale: locale)
            #expect(presets == "\(count) \(count == 1 ? "preset" : "presets")")
            #expect(bytes == "\(count) \(count == 1 ? "byte" : "bytes")")
        }
    }

    @Test func existingPresetDataKeepsItsOriginalValues() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"用户预设","text":"AT+STATUS","isHex":false,"ending":"无","encoding":"UTF-8"}"#.utf8)
        let preset = try JSONDecoder().decode(CommandPreset.self, from: data)
        #expect(preset.name == "用户预设")
        #expect(preset.ending == .none)
        #expect(preset.encoding == .utf8)
        #expect(try PayloadCodec.encode(preset.text, hex: preset.isHex, encoding: preset.encoding, ending: preset.ending) == Data("AT+STATUS".utf8))
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preset)) as? [String: Any])
        #expect(saved["ending"] as? String == "无")
    }
}
