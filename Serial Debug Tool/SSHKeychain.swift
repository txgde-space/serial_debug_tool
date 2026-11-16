import Foundation
import Security
import Darwin

protocol SSHCredentialStorage: Sendable {
    func set(_ password: String, account: String) throws
    func remove(account: String) throws
}

/// Only the application accesses the Keychain. The askpass helper uses a short-lived
/// local socket; passwords never enter arguments, environment variables or files.
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


/// One broker per SSH process. A private directory and random capability restrict
/// access; only the matching askpass invocation receives the saved password.
final class SSHPasswordBroker: @unchecked Sendable {
    static let socketKey = "SERIAL_DEBUG_SSH_PASSWORD_SOCKET"
    static let tokenKey = "SERIAL_DEBUG_SSH_PASSWORD_TOKEN"
    let path: String
    let token = UUID().uuidString
    private let directory: String
    private let source: DispatchSourceRead

    init(password: String) throws {
        guard !password.isEmpty, password.utf8.count <= 65_536,
              !password.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var template = Array((NSTemporaryDirectory() + "ssh.XXXXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw Self.systemError() }
        directory = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        path = directory + "/s"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            rmdir(directory)
            throw Self.systemError()
        }
        do {
            try Self.withAddress(path) { address, size in
                guard Darwin.bind(fd, address, size) == 0 else { throw Self.systemError() }
            }
            guard listen(fd, 4) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                throw Self.systemError()
            }
        } catch {
            Darwin.close(fd)
            unlink(path)
            rmdir(directory)
            throw error
        }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        let expected = Data(token.utf8)
        let response = Data(password.utf8)
        source.setEventHandler {
            // One connection per SSH prompt; do not block the serial transport actor.
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                defer { Darwin.close(client) }
                do { try Self.configure(client) } catch { return }
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { return }
                var request = [UInt8](repeating: 0, count: expected.count)
                let count = recv(client, &request, request.count, MSG_WAITALL)
                guard count == expected.count, Data(request) == expected else { return }
                try? Self.write(response, to: client)
            }
        }
        let socketPath = path, folder = directory
        source.setCancelHandler {
            Darwin.close(fd)
            unlink(socketPath)
            rmdir(folder)
        }
        source.resume()
    }

    deinit { source.cancel() }

    static func password(environment: [String: String]) throws -> String? {
        guard let path = environment[socketKey], let token = environment[tokenKey] else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw systemError() }
        defer { Darwin.close(fd) }
        try configure(fd)
        try withAddress(path) { address, size in
            guard connect(fd, address, size) == 0 else { throw systemError() }
        }
        try write(Data(token.utf8), to: fd)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw systemError()
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 65_536 else { throw CocoaError(.fileReadTooLarge) }
        }
        guard !data.isEmpty, let value = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    private static func configure(_ fd: Int32) throws {
        // Darwin inherits O_NONBLOCK from the listener. Wait for the helper's
        // capability instead of treating a scheduling delay as authentication failure.
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { throw systemError() }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw systemError() }
                offset += count
            }
        }
    }

    private static func withAddress<T>(_ path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private static func systemError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
