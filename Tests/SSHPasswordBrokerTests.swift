import Foundation
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
