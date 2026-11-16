import Foundation
import Darwin
import Testing
@testable import SerialDebugToolCore

@Suite("SSH password handoff")
struct SSHPasswordBrokerTests {
    @Test func savedCredentialSupportsRepeatedPromptsWithoutKeychainReads() throws {
        let password = "fixture-密码-🔒"
        let broker = try SSHPasswordBroker(password: password)
        let environment = [SSHPasswordBroker.socketKey: broker.path, SSHPasswordBroker.tokenKey: broker.token]
        for _ in 0..<3 {
            #expect(try SSHPasswordBroker.password(environment: environment) == password)
        }
        #expect(!environment.values.contains(password))
        let directory = URL(fileURLWithPath: broker.path).deletingLastPathComponent()
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func invalidCapabilityCannotReadPasswordAndDoesNotConsumeIt() throws {
        let broker = try SSHPasswordBroker(password: "fixture")
        let wrong = [SSHPasswordBroker.socketKey: broker.path, SSHPasswordBroker.tokenKey: UUID().uuidString]
        #expect(throws: (any Error).self) { try SSHPasswordBroker.password(environment: wrong) }
        let correct = [SSHPasswordBroker.socketKey: broker.path, SSHPasswordBroker.tokenKey: broker.token]
        #expect(try SSHPasswordBroker.password(environment: correct) == "fixture")
        #expect(try SSHPasswordBroker.password(environment: [:]) == nil)
    }

    @Test func clientMaySendCapabilityAfterConnectionIsAccepted() throws {
        let broker = try SSHPasswordBroker(password: "fixture")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(broker.path.utf8CString).map { UInt8(bitPattern: $0) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(connected == 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // Scheduling can let accept/recv run before the helper writes its capability.
        Thread.sleep(forTimeInterval: 0.1)
        let sent = Data(broker.token.utf8).withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        #expect(sent == broker.token.utf8.count)
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(fd, &buffer, buffer.count)
        #expect(count == 7)
        #expect(String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self) == "fixture")
    }

    @Test func endingConnectionRemovesSocket() async throws {
        var broker: SSHPasswordBroker? = try SSHPasswordBroker(password: "fixture")
        let path = try #require(broker?.path)
        broker = nil
        for _ in 0..<100 where FileManager.default.fileExists(atPath: path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path))
    }

    @Test func invalidPasswordNeverCreatesHandoff() {
        for password in ["", "a\nb", "a\rb", "a\0b", String(repeating: "a", count: 65_537)] {
            #expect(throws: (any Error).self) { try SSHPasswordBroker(password: password) }
        }
    }
}
