import Foundation
import Security

protocol SSHCredentialStorage: Sendable {
    func set(_ password: String, account: String) throws
    func remove(account: String) throws
}

/// The sandbox-inheriting helper reads this item when OpenSSH launches SSH_ASKPASS.
/// Only the account identifier is passed to the child; secrets never enter argv or environment.
struct SSHKeychain: SSHCredentialStorage {
    var service = "SerialDebugTool.SSH.Password"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func password(account: String) throws -> String? {
        var attributes = query(account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    func set(_ password: String, account: String) throws {
        let attributes = query(account)
        let value = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(attributes as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var addition = attributes
            addition[kSecValueData as String] = Data(password.utf8)
            addition[kSecAttrLabel as String] = "Serial Debug Tool SSH"
            try check(SecItemAdd(addition as CFDictionary, nil))
        } else { try check(status) }
    }

    func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func isPasswordPrompt(_ prompt: String, kind: String?) -> Bool {
        guard kind != "confirm", kind != "none" else { return false }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text == "password:" || text.hasSuffix("'s password:") { return true }
        // OpenSSH adds (user@host) to keyboard-interactive prompts. Match only
        // the login password, not OTP, password-change or private-key prompts.
        return text.range(
            of: #"^\([a-z0-9._-]+@[a-z0-9._:\[\]-]+\) password:$"#,
            options: .regularExpression
        ) != nil
    }
}


