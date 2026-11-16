import SwiftUI
import UniformTypeIdentifiers

struct SSHConnectionControls: View {
    @Bindable var session: SerialSession
    @State private var importingKey = false
    @State private var savingProfile = false
    @State private var deletingProfile = false
    @State private var forgettingPassword = false
    @State private var profileName = ""
    @State private var password = ""
    @State private var profileError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppText.sshHost).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    hostPicker
                    Button {
                        prepareProfileEditor()
                        savingProfile = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .help(AppText.sshManageHosts)
                    .accessibilityLabel(AppText.sshManageHosts)
                    .accessibilityIdentifier("manageSSHHosts")
                }
            }
            HStack(alignment: .top, spacing: 10) {
                field(AppText.sshUsername, text: $session.sshUsername)
                field(AppText.sshPort, text: $session.sshPort).frame(width: 70)
            }
            Picker(AppText.sshAuthentication, selection: $session.sshAuthentication) {
                ForEach(SSHAuthentication.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            if session.sshAuthentication == .privateKey {
                Button {
                    importingKey = true
                } label: {
                    Label(session.sshKeyName.isEmpty ? AppText.sshChooseKey : session.sshKeyName,
                          systemImage: "key")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help(AppText.sshChooseKey)
            }
            Button {
                Task { await session.refreshPorts() }
            } label: {
                Text(AppText.sshTestConnection)
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("testSSHConnection")
            supportStatus
        }
        .disabled(session.isSavingSSHProfile)
        .sheet(isPresented: $savingProfile, onDismiss: { password = ""; profileError = nil }) {
            profileEditor
        }
        .fileImporter(isPresented: $importingKey, allowedContentTypes: [.item]) { result in
            do { try session.importSSHIdentity(from: result.get()) }
            catch { session.errorMessage = error.localizedDescription }
        }
    }

    private var hostPicker: some View {
        HStack(spacing: 0) {
            TextField(AppText.sshHost, text: $session.sshHost)
                .textFieldStyle(.plain)
                .padding(.leading, 6)
                .accessibilityIdentifier("sshHostAddress")
            Menu {
                Button(AppText.sshManualSession) {
                    session.newSSHProfile()
                }
                if !session.sshProfiles.isEmpty {
                    Divider()
                    ForEach(session.sshProfiles) { profile in
                        Button {
                            session.selectSSHProfile(profile.id)
                        } label: {
                            if session.selectedSSHProfile?.id == profile.id {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(profile.name)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(AppText.sshSessions)
            .accessibilityIdentifier("sshSessionPicker")
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(.secondary.opacity(0.2), lineWidth: 0.5)
        }
    }

    private var profileOptions: some View {
        Picker(AppText.sshSessions, selection: Binding(
            get: { session.selectedSSHProfile?.id },
            set: { id in
                if let id {
                    session.selectSSHProfile(id)
                } else {
                    session.newSSHProfile()
                    prepareProfileEditor()
                }
            }
        )) {
            Text(AppText.sshManualSession).tag(nil as UUID?)
            ForEach(session.sshProfiles) { profile in
                Text(profile.name).tag(Optional(profile.id))
            }
        }
    }

    private func prepareProfileEditor() {
        profileName = session.selectedSSHProfile?.name ?? session.sshHost
        password = ""
        profileError = nil
    }

    private var profileEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppText.sshManageHosts).font(.headline)
            HStack {
                profileOptions
                    .pickerStyle(.menu)
                Button {
                    session.newSSHProfile()
                    prepareProfileEditor()
                } label: {
                    Image(systemName: "plus")
                }
                .help(AppText.sshNewSession)
                .accessibilityLabel(AppText.sshNewSession)
                Menu {
                    Button(AppText.sshForgetPassword) { forgettingPassword = true }
                        .disabled(session.selectedSSHProfile?.authentication != .password)
                    Button(AppText.delete, role: .destructive) { deletingProfile = true }
                        .disabled(session.selectedSSHProfile == nil)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .fixedSize()
                .accessibilityLabel(AppText.sshManageHosts)
            }
            field(AppText.sshHost, text: $session.sshHost)
            HStack {
                field(AppText.sshUsername, text: $session.sshUsername)
                field(AppText.sshPort, text: $session.sshPort).frame(width: 70)
            }
            TextField(AppText.sshSessionName, text: $profileName)
                .textFieldStyle(.roundedBorder)
            if session.sshAuthentication == .password {
                VStack(alignment: .leading, spacing: 5) {
                    Text(AppText.sshPassword)
                    SecureField(session.selectedSSHProfile == nil ? AppText.sshPassword : AppText.sshSavedPasswordPlaceholder,
                                text: $password)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("sshSessionPassword")
                }
            }
            if let profileError { Text(profileError).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if session.isSavingSSHProfile { ProgressView().controlSize(.small) }
                Spacer()
                Button(AppText.cancel) { savingProfile = false }
                    .keyboardShortcut(.cancelAction)
                Button(AppText.save) {
                    Task {
                        do {
                            try await session.saveSSHProfile(name: profileName, password: password, asNew: false)
                            password = ""
                            savingProfile = false
                        } catch { profileError = error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || session.sshHost.isEmpty || session.sshUsername.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .disabled(session.isSavingSSHProfile)
        .interactiveDismissDisabled(session.isSavingSSHProfile)
        .onChange(of: session.selectedSSHProfile?.id) { prepareProfileEditor() }
        .alert(AppText.sshDeleteSession, isPresented: $deletingProfile) {
            Button(AppText.delete, role: .destructive) {
                Task {
                    do { try await session.deleteSSHProfile() }
                    catch { session.errorMessage = error.localizedDescription }
                }
            }
            Button(AppText.cancel, role: .cancel) {}
        } message: { Text(AppText.sshDeleteSessionDetail) }
        .alert(AppText.sshForgetPassword, isPresented: $forgettingPassword) {
            Button(AppText.delete, role: .destructive) {
                Task {
                    do { try await session.forgetSSHPassword() }
                    catch { session.errorMessage = error.localizedDescription }
                }
            }
            Button(AppText.cancel, role: .cancel) {}
        } message: { Text(AppText.sshForgetPasswordDetail) }
    }

    private var supportColor: Color {
        switch session.sshSupportStatus {
        case .checked(let report): report.isSupported ? .green : .red
        case .failed: .orange
        default: .secondary
        }
    }

    private var supportStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if session.sshSupportStatus == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: supportSymbol)
                }
                Text(session.isConnected ? AppText.sshSerialVerified : session.sshSupportStatus.title)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(supportColor)
            .help(AppText.sshSupportScope)
            if let detail = session.sshSupportStatus.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let error = session.sshDeviceError {
                Label(AppText.sshDeviceCheckFailed, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Text(error)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sshSerialSupport")
    }

    private var supportSymbol: String {
        switch session.sshSupportStatus {
        case .checked(let report): report.isSupported ? "checkmark.circle.fill" : "xmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "questionmark.circle"
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }
}
