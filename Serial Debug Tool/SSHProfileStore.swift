import Foundation
import Observation

struct SSHProfile: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int
    var username: String
    var authentication: SSHAuthentication
    var identityFile: String?
    var keyName: String
    var device: String
    var baudRate: Int
    var dataBits: Int
    var stopBits: Int
    var parity: SerialParity
    var flowControl: SerialFlowControl

    var passwordAccount: String { id.uuidString + "|" + username + "@" + host + ":" + String(port) }

    func matches(_ configuration: SSHConfiguration) -> Bool {
        host == configuration.host && port == configuration.port &&
        username == configuration.username && authentication == configuration.authentication
    }

    func configuration() throws -> SSHConfiguration {
        let identity: URL?
        if let identityFile {
            guard identityFile.hasPrefix("identity-"), !identityFile.contains("/"), !identityFile.contains("..") else {
                throw SerialTransportError(message: AppText.sshInvalidKey)
            }
            identity = try SSHFiles.directory().appendingPathComponent(identityFile)
        } else { identity = nil }
        return SSHConfiguration(host: host, port: port, username: username,
                                authentication: authentication, identityURL: identity)
    }
}

/// Shared library, with each window retaining its own editable connection settings.
@MainActor
@Observable
final class SSHProfileStore {
    static let shared = SSHProfileStore()
    static let preferenceKey = "ssh.profiles.v1"
    private(set) var profiles: [SSHProfile]
    private(set) var isMutating = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: any SSHCredentialStorage

    init(defaults: UserDefaults = .standard, credentials: any SSHCredentialStorage = SSHKeychain()) {
        self.defaults = defaults
        self.credentials = credentials
        profiles = defaults.data(forKey: Self.preferenceKey)
            .flatMap { try? JSONDecoder().decode([SSHProfile].self, from: $0) } ?? []
    }

    func save(_ profile: SSHProfile, password: String) async throws {
        guard !isMutating else { throw SerialTransportError(message: AppText.sshSessionBusy) }
        try profile.configuration().validate()
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...4_000_000).contains(profile.baudRate), (5...8).contains(profile.dataBits),
              (1...2).contains(profile.stopBits),
              !password.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else {
            throw SerialTransportError(message: AppText.sshInvalidConfiguration)
        }
        isMutating = true
        defer { isMutating = false }
        let old = profiles.first { $0.id == profile.id }
        var next = profiles
        if let index = next.firstIndex(where: { $0.id == profile.id }) { next[index] = profile }
        else { next.append(profile) }
        let data = try JSONEncoder().encode(next)
        let credentials = credentials
        try await Task.detached {
            let savesPassword = profile.authentication == .password && !password.isEmpty
            if savesPassword { try credentials.set(password, account: profile.passwordAccount) }
            do {
                if let old, old.passwordAccount != profile.passwordAccount || profile.authentication != .password {
                    try credentials.remove(account: old.passwordAccount)
                }
            } catch {
                if savesPassword, old?.passwordAccount != profile.passwordAccount {
                    try? credentials.remove(account: profile.passwordAccount)
                }
                throw error
            }
        }.value
        defaults.set(data, forKey: Self.preferenceKey)
        profiles = next
    }

    func remove(id: UUID) async throws {
        guard !isMutating else { throw SerialTransportError(message: AppText.sshSessionBusy) }
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        isMutating = true
        defer { isMutating = false }
        let next = profiles.filter { $0.id != id }
        let data = try JSONEncoder().encode(next)
        let credentials = credentials
        try await Task.detached { try credentials.remove(account: profile.passwordAccount) }.value
        defaults.set(data, forKey: Self.preferenceKey)
        profiles = next
    }

    func forgetPassword(id: UUID) async throws {
        guard !isMutating else { throw SerialTransportError(message: AppText.sshSessionBusy) }
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        isMutating = true
        defer { isMutating = false }
        let credentials = credentials
        try await Task.detached { try credentials.remove(account: profile.passwordAccount) }.value
    }
}
