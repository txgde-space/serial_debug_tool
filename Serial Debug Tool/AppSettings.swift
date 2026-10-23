import SwiftUI
import AppKit

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: AppText.systemTheme
        case .light: AppText.lightTheme
        case .dark: AppText.darkTheme
        }
    }

    var symbol: String {
        switch self {
        case .system: "desktopcomputer"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }

    @MainActor
    func applyAppearance() {
        switch self {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct AppSettingsView: View {
    @AppStorage("app.theme") private var theme: AppTheme = .system

    var body: some View {
        let selectedTheme = theme

        Form {
            Section {
                HStack(spacing: 12) {
                    ForEach(AppTheme.allCases) { option in
                        ThemeOptionButton(option: option, isSelected: selectedTheme == option) {
                            theme = option
                        }
                    }
                }
            } header: {
                Label(AppText.appearance, systemImage: "paintpalette")
            } footer: {
                Text(AppText.themeHelp)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker(AppText.language, selection: Binding(
                    get: { AppLocalization.shared.language },
                    set: { AppLocalization.shared.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                Text(AppText.languageHelp)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .environment(\.locale, AppLocalization.shared.locale)
        .frame(width: 480, height: 350)
        .onChange(of: theme) { _, theme in
            theme.applyAppearance()
        }
    }
}

private struct ThemeOptionButton: View {
    let option: AppTheme
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 10) {
                Image(systemName: option.symbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(option.title)
                    .font(.callout.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                isSelected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityValue(isSelected ? AppText.selected : AppText.notSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview("偏好设置 · 白天") {
    AppSettingsView()
        .environment(\.colorScheme, .light)
}

#Preview("偏好设置 · 黑夜") {
    AppSettingsView()
        .environment(\.colorScheme, .dark)
}
