import SwiftUI

struct AppUpdateView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.dismissWindow) private var dismissWindow
    private let updater: AppUpdateChecker

    init(updater: AppUpdateChecker? = nil) {
        self.updater = updater ?? .shared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppText.softwareUpdate).font(.title2.bold())
                    Text(AppText.updateCurrentVersion(updater.currentVersion))
                        .foregroundStyle(.secondary)
                }
            }

            switch updater.status {
            case .idle, .checking:
                HStack {
                    ProgressView().controlSize(.small)
                    Text(AppText.updateChecking)
                }
            case .upToDate:
                Label(AppText.updateUpToDate, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .available(let release):
                Label(AppText.updateAvailable(release.tagName), systemImage: "sparkles")
                    .font(.headline)
                if let notes = release.body, !notes.isEmpty {
                    ScrollView {
                        Text(notes)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            case .failed(let message):
                Label(AppText.updateFailed, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Spacer(minLength: 0)
            HStack {
                Button(AppText.checkForUpdates) { Task { await updater.check() } }
                    .disabled(updater.isChecking)
                Spacer()
                Button(AppText.updateClose) { dismissWindow(id: "updates") }
                    .keyboardShortcut(.cancelAction)
                if case .available(let release) = updater.status {
                    Button(AppText.updateDownload) { openURL(release.htmlURL) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else if case .failed = updater.status {
                    Button(AppText.updateReleases) { openURL(ReleaseService.releasesURL) }
                }
            }
        }
        .padding(24)
        .frame(width: 500, height: 390)
        .environment(\.locale, AppLocalization.shared.locale)
        .task {
            if updater.status == .idle { await updater.check() }
        }
    }
}

#Preview("Software Update") {
    @Previewable @State var updater = AppUpdateChecker(currentVersion: "1.2.2", fetch: {
        AppRelease(tagName: "v1.3.0",
                   htmlURL: URL(string: "https://github.com/txgde-space/serial_debug_tool/releases/tag/v1.3.0")!,
                   body: "新增应用内检查更新。\n\nAdded in-app update checks.",
                   draft: false, prerelease: false)
    })
    AppUpdateView(updater: updater)
}
