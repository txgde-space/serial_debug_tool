import Foundation
import Testing
@testable import SerialDebugToolCore

private final class ProfileCredentials: SSHCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var fails = false
    func set(_ password: String, account: String) throws {
        try lock.withLock {
            if fails { throw CocoaError(.fileWriteNoPermission) }
            values[account] = password
        }
    }
    func remove(account: String) throws {
        try lock.withLock {
            if fails { throw CocoaError(.fileWriteNoPermission) }
            values.removeValue(forKey: account)
        }
    }
    func value(_ account: String) -> String? { lock.withLock { values[account] } }
    func fail() { lock.withLock { fails = true } }
}

@Suite("SSH saved sessions")
@MainActor
struct SSHProfileTests {
    private func profile() -> SSHProfile {
        SSHProfile(name: "Lab", host: "host.example", port: 2222, username: "operator",
                   authentication: .password, keyName: "", device: "/dev/ttyUSB0",
                   baudRate: 9600, dataBits: 7, stopBits: 2, parity: .even, flowControl: .software)
    }

    @Test func libraryPersistsWithoutPasswordsAndCanForgetCredentials() async throws {
        let domain = "SSHProfileTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let credentials = ProfileCredentials()
        let store = SSHProfileStore(defaults: defaults, credentials: credentials)
        var saved = profile()
        try await store.save(saved, password: "test-secret-🔒")
        #expect(credentials.value(saved.passwordAccount) == "test-secret-🔒")
        let data = try #require(defaults.data(forKey: SSHProfileStore.preferenceKey))
        #expect(!String(decoding: data, as: UTF8.self).contains("test-secret"))
        #expect(SSHProfileStore(defaults: defaults, credentials: credentials).profiles == [saved])
        saved.name = "Renamed"
        try await store.save(saved, password: "")
        #expect(credentials.value(saved.passwordAccount) == "test-secret-🔒")
        try await store.forgetPassword(id: saved.id)
        #expect(credentials.value(saved.passwordAccount) == nil)
        #expect(store.profiles == [saved])
        try await store.save(saved, password: "replacement")
        try await store.remove(id: saved.id)
        #expect(store.profiles.isEmpty)
        #expect(credentials.value(saved.passwordAccount) == nil)
    }

    @Test func changingEndpointDoesNotTransferAPasswordAndFailuresKeepMetadata() async throws {
        let domain = "SSHProfileTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let credentials = ProfileCredentials()
        let store = SSHProfileStore(defaults: defaults, credentials: credentials)
        let original = profile()
        try await store.save(original, password: "old-secret")
        var changed = original
        changed.host = "different.example"
        #expect(!original.matches(try changed.configuration()))
        try await store.save(changed, password: "")
        #expect(credentials.value(original.passwordAccount) == nil)
        #expect(credentials.value(changed.passwordAccount) == nil)
        credentials.fail()
        await #expect(throws: (any Error).self) { try await store.save(original, password: "new-secret") }
        #expect(store.profiles == [changed])
        await #expect(throws: (any Error).self) { try await store.remove(id: changed.id) }
        #expect(store.profiles == [changed])
    }

    @Test func selectionRestoresSerialSettingsWithoutSharingWindowState() async throws {
        let domain = "SSHProfileTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = SSHProfileStore(defaults: defaults, credentials: ProfileCredentials())
        let saved = profile()
        try await store.save(saved, password: "fixture")
        let first = SerialSession(defaults: defaults, sshProfileStore: store)
        let second = SerialSession(defaults: defaults, sshProfileStore: store)
        first.selectSSHProfile(saved.id)
        second.selectSSHProfile(saved.id)
        #expect(first.sshHost == saved.host && first.sshPort == "2222")
        #expect(first.sshUsername == saved.username && first.remotePath == saved.device)
        #expect(first.baudRate == "9600" && first.dataBits == 7 && first.stopBits == 2)
        #expect(first.parity == .even && first.flowControl == .software)
        first.sshHost = "another.example"
        #expect(second.sshHost == saved.host)
        #expect(store.profiles == [saved])
        first.newSSHProfile()
        #expect(first.selectedSSHProfile == nil && first.sshHost.isEmpty)
        #expect(second.selectedSSHProfile == saved)
        try await store.remove(id: saved.id)
        #expect(second.selectedSSHProfile == nil)
        #expect(second.sshHost == saved.host)
    }

    @Test func savedPasswordIsNotUsedForHostTrustOTPOrPrivateKeyPrompts() {
        #expect(SSHKeychain.isPasswordPrompt("operator@host's password: ", kind: nil))
        #expect(SSHKeychain.isPasswordPrompt("Password:", kind: nil))
        #expect(!SSHKeychain.isPasswordPrompt("One-time password:", kind: nil))
        #expect(!SSHKeychain.isPasswordPrompt("Verification code:", kind: nil))
        #expect(!SSHKeychain.isPasswordPrompt("Enter passphrase for key:", kind: nil))
        #expect(!SSHKeychain.isPasswordPrompt("Password:", kind: "confirm"))
        #expect(!SSHKeychain.isPasswordPrompt("Password:", kind: "none"))
    }

    @Test func restoredHostKeepsCredentialAssociationAcrossRefreshes() async throws {
        let domain = "SSHProfileTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = SSHProfileStore(defaults: defaults, credentials: ProfileCredentials())
        let saved = profile()
        try await store.save(saved, password: "fixture")
        defaults.set(saved.host, forKey: "ssh.host")
        defaults.set(String(saved.port), forKey: "ssh.port")
        defaults.set(saved.username, forKey: "ssh.username")
        // Older versions persisted only the address, losing the credential association.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("ssh-fixture")
        let source = """
        #!/bin/sh
        [ -n "$SERIAL_DEBUG_SSH_PASSWORD_SOCKET" ] || exit 9
        [ -n "$SERIAL_DEBUG_SSH_PASSWORD_TOKEN" ] || exit 10
        [ -z "$SERIAL_DEBUG_SSH_PASSWORD_ACCOUNT" ] || exit 11
        printf 'SERIAL_DEBUG_SUPPORT\\tOK\\nSERIAL_DEBUG_READY\\n/dev/ttyUSB0\\nSERIAL_DEBUG_END\\n'
        """
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let scanner = SSHSerialTransport(executableURL: executable, askPassURL: executable,
            knownHostsURL: directory.appendingPathComponent("known_hosts"),
            passwordLookup: { account in
                guard account == saved.passwordAccount else { throw CocoaError(.fileReadNoSuchFile) }
                return "fixture"
            })
        let session = SerialSession(defaults: defaults, sshScanner: scanner, sshProfileStore: store)
        session.connectionMode = .ssh
        #expect(session.selectedSSHProfile?.id == saved.id)
        for _ in 0..<2 {
            await session.refreshPorts()
            #expect(session.errorMessage == nil)
            #expect(session.remotePorts.map(\.path) == ["/dev/ttyUSB0"])
        }
        #expect(defaults.string(forKey: "ssh.profileID") == saved.id.uuidString)
        let restored = SerialSession(defaults: defaults, sshProfileStore: store)
        #expect(restored.selectedSSHProfile?.id == saved.id)
        defaults.set("another.example", forKey: "ssh.host")
        #expect(SerialSession(defaults: defaults, sshProfileStore: store).selectedSSHProfile == nil)
    }

    @Test func restoringDoesNotGuessBetweenMultipleAccountsOrOverrideManualChoice() async throws {
        let domain = "SSHProfileTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = SSHProfileStore(defaults: defaults, credentials: ProfileCredentials())
        let first = profile()
        var second = first
        second.id = UUID()
        try await store.save(first, password: "first")
        try await store.save(second, password: "second")
        defaults.set(first.host, forKey: "ssh.host")
        defaults.set(String(first.port), forKey: "ssh.port")
        defaults.set(first.username, forKey: "ssh.username")
        #expect(SerialSession(defaults: defaults, sshProfileStore: store).selectedSSHProfile == nil)
        defaults.set(second.id.uuidString, forKey: "ssh.profileID")
        #expect(SerialSession(defaults: defaults, sshProfileStore: store).selectedSSHProfile?.id == second.id)
        defaults.set("", forKey: "ssh.profileID")
        #expect(SerialSession(defaults: defaults, sshProfileStore: store).selectedSSHProfile == nil)
    }

    @Test func keyboardInteractivePasswordPromptsReuseSavedCredentials() {
        // OpenSSH prefixes keyboard-interactive prompts with (user@host).
        #expect(SSHKeychain.isPasswordPrompt("(operator@host.example) Password: ", kind: nil))
        #expect(SSHKeychain.isPasswordPrompt("(operator@192.0.2.1) password:", kind: nil))
        #expect(SSHKeychain.isPasswordPrompt("(operator@2001:db8::1) Password:", kind: nil))
        #expect(!SSHKeychain.isPasswordPrompt("(operator@host.example) One-time password:", kind: nil))
        #expect(!SSHKeychain.isPasswordPrompt("(operator@host.example) Verification code:", kind: nil))
        #expect(!SSHKeychain.isPasswordPrompt("(operator@host.example) New password:", kind: nil))
        #expect(!SSHKeychain.isPasswordPrompt("(operator@host.example) Enter passphrase for key:", kind: nil))
        #expect(!SSHKeychain.isPasswordPrompt("(operator@host.example) Password:", kind: "confirm"))
        #expect(!SSHKeychain.isPasswordPrompt("(operator@host.example) Password:", kind: "none"))
    }

    @Test func keychainRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["SERIAL_KEYCHAIN_CHECK"] == "1" else { return }
        let keychain = SSHKeychain(service: "SerialDebugTool.Tests.\(UUID())")
        let account = UUID().uuidString
        defer { try? keychain.remove(account: account) }
        #expect(try keychain.password(account: account) == nil)
        try keychain.set("fixture-only-🔒", account: account)
        #expect(try keychain.password(account: account) == "fixture-only-🔒")
        try keychain.set("replacement", account: account)
        #expect(try keychain.password(account: account) == "replacement")
        try keychain.remove(account: account)
        #expect(try keychain.password(account: account) == nil)
    }
}
