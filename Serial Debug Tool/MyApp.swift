import SwiftUI

@main
@MainActor
struct MyApp: App {
    init() {
        let savedTheme = UserDefaults.standard.string(forKey: "app.theme") ?? AppTheme.system.rawValue
        (AppTheme(rawValue: savedTheme) ?? .system).applyAppearance()
    }

    var body: some Scene {
        WindowGroup(AppText.appName, id: "serial") {
            ContentView()
                .environment(\.locale, AppLocalization.shared.locale)
        }
        .defaultSize(width: 1120, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            SerialWindowCommands()
        }

        Settings {
            AppSettingsView()
        }
    }
}

private struct SerialWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(AppText.newSerialWindow) { openWindow(id: "serial") }
                .keyboardShortcut("n", modifiers: .command)
        }
    }
}
