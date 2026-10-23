import Foundation
import Darwin
import Testing
@testable import SerialDebugToolCore

private struct CheckError: Error {
    let message: String
}

private final class PseudoTerminal {
    let master: Int32
    let slave: Int32
    let path: String
    private var masterClosed = false

    init() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 256)
        guard openpty(&master, &slave, &name, nil, nil) == 0 else {
            throw CheckError(message: "openpty failed")
        }
        self.master = master
        self.slave = slave
        self.path = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
    }

    deinit {
        if !masterClosed { Darwin.close(master) }
        Darwin.close(slave)
    }

    func disconnectDevice() {
        guard !masterClosed else { return }
        Darwin.close(master)
        masterClosed = true
    }
}

private func readMaster(_ descriptor: Int32, count: Int) async throws -> Data {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    var result = Data()
    var bytes = [UInt8](repeating: 0, count: 8192)
    while result.count < count, ContinuousClock.now < deadline {
        let size = Darwin.read(descriptor, &bytes, bytes.count)
        if size > 0 { result.append(contentsOf: bytes.prefix(size)) }
        else if size < 0, errno != EAGAIN, errno != EWOULDBLOCK {
            throw CheckError(message: "master read failed")
        } else { try await Task.sleep(for: .milliseconds(5)) }
    }
    guard result.count == count else { throw CheckError(message: "master read timed out") }
    return result
}

private func collect(_ stream: AsyncThrowingStream<Data, Error>, count: Int) async throws -> Data {
    try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask {
            var bytes = Data()
            for try await data in stream {
                bytes.append(data)
                if bytes.count >= count { return bytes }
            }
            throw CheckError(message: "stream ended before expected bytes")
        }
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            throw CheckError(message: "receive timed out")
        }
        defer { group.cancelAll() }
        return try await group.next() ?? Data()
    }
}

@MainActor
private struct WindowTestContext {
    let domain = "SerialDebugTool.WindowTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let presets: CommandPresetStore

    init() throws {
        defaults = try #require(UserDefaults(suiteName: domain))
        presets = CommandPresetStore(defaults: defaults)
    }

    func session() -> SerialSession {
        SerialSession(defaults: defaults, presetStore: presets)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: domain)
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    guard condition() else { throw CheckError(message: "session condition timed out") }
}

private func receiveFromDevice(_ text: String, terminal: PseudoTerminal) throws {
    let data = Data(text.utf8)
    let count = data.withUnsafeBytes { Darwin.write(terminal.master, $0.baseAddress, data.count) }
    try #require(count == data.count)
}

@Suite("Multiple serial windows", .serialized)
struct MultiWindowTests {
    @Test @MainActor
    func connectionsDraftsLogsAndCountersStayIndependent() async throws {
        let context = try WindowTestContext()
        defer { context.cleanUp() }
        let deviceA = try PseudoTerminal()
        let deviceB = try PseudoTerminal()
        let first = context.session()
        let second = context.session()
        first.selectedPath = deviceA.path
        second.selectedPath = deviceB.path
        first.input = "ALPHA"
        second.input = "BETA"
        first.ending = .none
        second.ending = .lf
        second.encoding = .ascii
        await first.connect()
        #expect(first.isConnected && !second.isConnected)
        #expect(second.status == AppText.disconnected)
        await second.connect()
        #expect(first.isConnected && second.isConnected)

        #expect(await first.send())
        #expect(first.sentBytes == 5 && second.sentBytes == 0)
        #expect(try await readMaster(deviceA.master, count: 5) == Data("ALPHA".utf8))
        #expect(await second.send())
        #expect(try await readMaster(deviceB.master, count: 5) == Data("BETA\n".utf8))
        try receiveFromDevice("ONLY_A\n", terminal: deviceA)
        try receiveFromDevice("ONLY_B\n", terminal: deviceB)
        try await waitUntil { first.receivedBytes == 7 && second.receivedBytes == 7 }
        #expect(first.logText.contains("ONLY_A") && !first.logText.contains("ONLY_B"))
        #expect(second.logText.contains("ONLY_B") && !second.logText.contains("ONLY_A"))

        let secondLog = second.logText
        first.clearLog()
        first.resetCounters()
        first.input = "Changed only in A"
        first.encoding = .utf16LE
        first.paused = true
        first.autoWrap = false
        first.search = "A only"
        first.errorMessage = "A only"
        #expect(second.logText == secondLog)
        #expect(second.receivedBytes == 7 && second.sentBytes == 5)
        #expect(second.input == "BETA" && second.encoding == .ascii && second.ending == .lf)
        #expect(!second.paused && second.autoWrap && second.search.isEmpty && second.errorMessage == nil)
        await first.disconnect()
        #expect(!first.isConnected && second.isConnected)
        #expect(await second.send())
        #expect(try await readMaster(deviceB.master, count: 5) == Data("BETA\n".utf8))
        await second.disconnect()
    }

    @Test @MainActor
    func closingOneWindowLeavesTheOtherReceivingAndRepeating() async throws {
        let context = try WindowTestContext()
        defer { context.cleanUp() }
        let deviceA = try PseudoTerminal()
        let deviceB = try PseudoTerminal()
        let first = context.session()
        let second = context.session()
        first.selectedPath = deviceA.path
        second.selectedPath = deviceB.path
        first.input = "A"
        second.input = "B"
        first.ending = .none
        second.ending = .none
        first.interval = "20"
        second.interval = "20"
        let monitorA = Task { await first.monitor() }
        let monitorB = Task { await second.monitor() }
        defer { monitorA.cancel(); monitorB.cancel() }
        await first.connect()
        await second.connect()
        first.toggleRepeating()
        second.toggleRepeating()
        try await waitUntil { first.sentBytes > 0 && second.sentBytes > 0 }
        monitorA.cancel()
        await monitorA.value
        let closedCount = first.sentBytes
        let activeCount = second.sentBytes
        #expect(!first.isConnected && !first.isRepeating)
        #expect(second.isConnected && second.isRepeating)
        try receiveFromDevice("STILL_B\n", terminal: deviceB)
        try await waitUntil { second.receivedBytes == 8 && second.sentBytes > activeCount }
        #expect(first.sentBytes == closedCount && first.receivedBytes == 0)
        #expect(second.logText.contains("STILL_B"))
        let replacement = SerialTransport()
        _ = try await replacement.open(SerialConfiguration(path: deviceA.path))
        await replacement.close()
        #expect(second.isConnected)
        monitorB.cancel()
        await monitorB.value
    }

    @Test @MainActor
    func duplicatePortFailureDoesNotAffectItsOwner() async throws {
        let context = try WindowTestContext()
        defer { context.cleanUp() }
        let device = try PseudoTerminal()
        let owner = context.session()
        let duplicate = context.session()
        owner.selectedPath = device.path
        duplicate.selectedPath = device.path
        owner.input = "OWNER"
        owner.ending = .none
        await owner.connect()
        await duplicate.connect()
        #expect(owner.isConnected && !duplicate.isConnected)
        #expect(owner.errorMessage == nil && duplicate.errorMessage != nil)
        await duplicate.disconnect()
        #expect(await owner.send())
        #expect(try await readMaster(device.master, count: 5) == Data("OWNER".utf8))
        #expect(duplicate.sentBytes == 0 && duplicate.receivedBytes == 0)
        await owner.disconnect()
    }

    @Test func staleCloseCannotTerminateAReopenedTransport() async throws {
        let device = try PseudoTerminal()
        let transport = SerialTransport()
        let oldID = UUID()
        let newID = UUID()
        _ = try await transport.open(SerialConfiguration(path: device.path), generation: oldID)
        await transport.close(ifGeneration: oldID)
        let reopened = try await transport.open(SerialConfiguration(path: device.path), generation: newID)
        await transport.close(ifGeneration: oldID)
        #expect(try await transport.write(Data("NEW".utf8)) == 3)
        #expect(try await readMaster(device.master, count: 3) == Data("NEW".utf8))
        try receiveFromDevice("REPLY", terminal: device)
        #expect(try await collect(reopened, count: 5) == Data("REPLY".utf8))
        await transport.close(ifGeneration: newID)
    }

    @Test @MainActor
    func cancelledRepeaterCannotClearItsReplacementState() async throws {
        let context = try WindowTestContext()
        defer { context.cleanUp() }
        let device = try PseudoTerminal()
        let session = context.session()
        session.selectedPath = device.path
        session.input = "PING"
        session.ending = .none
        session.interval = "1000"
        await session.connect()
        session.toggleRepeating()
        try await waitUntil { session.sentBytes == 4 && !session.isSending }
        session.stopRepeating()
        session.toggleRepeating()
        try await waitUntil { session.sentBytes >= 8 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(session.isConnected && session.isRepeating)
        await session.disconnect()
    }

    @Test @MainActor
    func cancelledConnectCannotOverwriteANewerConnection() async throws {
        let context = try WindowTestContext()
        defer { context.cleanUp() }
        let device = try PseudoTerminal()
        let session = context.session()
        session.selectedPath = device.path
        session.input = "NEW"
        session.ending = .none
        for _ in 0..<12 {
            let previous = Task { await session.connect() }
            await Task.yield()
            previous.cancel()
            await session.disconnect()
            await session.connect()
            await previous.value
            #expect(session.isConnected && !session.isConnecting)
            #expect(await session.send())
            #expect(try await readMaster(device.master, count: 3) == Data("NEW".utf8))
            await session.disconnect()
        }
    }

    @Test @MainActor
    func sharedPresetChangesDoNotOverwriteOtherWindowsOrDrafts() throws {
        let context = try WindowTestContext()
        defer { context.cleanUp() }
        let first = context.session()
        let second = context.session()
        first.input = "COMMAND_A"
        second.input = "COMMAND_B"
        first.savePreset(name: "A")
        #expect(second.presets.map(\.name) == ["A"])
        second.savePreset(name: "B")
        #expect(first.presets.map(\.name) == ["A", "B"])
        var edited = try #require(first.presets.first)
        edited.text = "EDITED_A"
        #expect(first.updatePreset(edited))
        #expect(second.presets.first?.text == "EDITED_A")
        second.deletePreset(id: edited.id)
        #expect(first.presets.map(\.name) == ["B"])
        #expect(first.input == "COMMAND_A" && second.input == "COMMAND_B")
        #expect(CommandPresetStore(defaults: context.defaults).presets == second.presets)
        #expect(!first.updatePreset(edited))
    }

    @Test @MainActor
    func closingAnUnchangedWindowPreservesTheLatestSavedDevice() async throws {
        let context = try WindowTestContext()
        defer { context.cleanUp() }
        let deviceA = try PseudoTerminal()
        let deviceB = try PseudoTerminal()
        context.defaults.set(deviceA.path, forKey: "serial.path")
        context.defaults.set("115200", forKey: "serial.baud")
        let untouched = context.session()
        let active = context.session()
        active.selectedPath = deviceB.path
        active.baudRate = "230400"
        await active.connect()
        let monitor = Task { await untouched.monitor() }
        monitor.cancel()
        await monitor.value
        #expect(context.defaults.string(forKey: "serial.path") == deviceB.path)
        #expect(context.defaults.string(forKey: "serial.baud") == "230400")
        #expect(untouched.selectedPath == deviceA.path && active.isConnected)
        await active.disconnect()
    }
}

@Suite("Preset repeat sending", .serialized)
struct PresetRepeatTests {
    @Test @MainActor
    func repeatCapturesPresetBytesWithoutChangingCommandDraft() async throws {
        let context = try WindowTestContext()
        defer { context.cleanUp() }
        let device = try PseudoTerminal()
        let session = context.session()
        let preset = CommandPreset(name: "HEX", text: "AA 11 FF", isHex: true, ending: .lf, encoding: .ascii)
        context.presets.append(preset)
        session.selectedPath = device.path
        session.interval = "40"
        session.input = ""
        session.sendHex = false
        session.ending = .crlf
        session.encoding = .utf16LE
        await session.connect()
        session.togglePresetRepeating(preset)
        let expected = Data([0xAA, 0x11, 0xFF, 10])
        #expect(try await readMaster(device.master, count: 4) == expected)
        var edited = preset
        edited.text = "00"
        edited.ending = .none
        #expect(session.updatePreset(edited))
        session.input = "Unsent draft"
        session.interval = "3600000"
        #expect(try await readMaster(device.master, count: 8) == expected + expected)
        #expect(session.repeatingPresetID == preset.id && session.isRepeating)
        #expect(session.input == "Unsent draft" && !session.sendHex)
        #expect(session.ending == .crlf && session.encoding == .utf16LE)
        session.togglePresetRepeating(edited)
        #expect(!session.isRepeating && session.repeatingPresetID == nil)
        try await waitUntil { !session.isSending }
        let stoppedBytes = session.sentBytes
        try await Task.sleep(for: .milliseconds(90))
        #expect(session.sentBytes == stoppedBytes)
        await session.disconnect()
    }

    @Test @MainActor
    func timersStayWindowLocalAndSharedDeletionStopsBeforeNextSend() async throws {
        let context = try WindowTestContext()
        defer { context.cleanUp() }
        let deviceA = try PseudoTerminal()
        let deviceB = try PseudoTerminal()
        let first = context.session()
        let second = context.session()
        let preset = CommandPreset(name: "Status", text: "PING", isHex: false, ending: .none, encoding: .utf8)
        let other = CommandPreset(name: "Other", text: "OTHER", isHex: false, ending: .none, encoding: .utf8)
        context.presets.append(preset)
        context.presets.append(other)
        first.selectedPath = deviceA.path
        second.selectedPath = deviceB.path
        first.interval = "60"
        second.interval = "20"
        second.input = "B"
        second.ending = .none
        await first.connect()
        await second.connect()
        first.togglePresetRepeating(preset)
        second.toggleRepeating()
        #expect(try await readMaster(deviceA.master, count: 4) == Data("PING".utf8))
        first.togglePresetRepeating(other)
        #expect(first.repeatingPresetID == preset.id)
        second.deletePreset(id: preset.id)
        try await waitUntil { !first.isRepeating }
        #expect(first.sentBytes == 4 && first.repeatingPresetID == nil)
        #expect(second.isRepeating && second.repeatingPresetID == nil)
        first.togglePresetRepeating(other)
        #expect(try await readMaster(deviceA.master, count: 5) == Data("OTHER".utf8))
        first.deletePreset(id: other.id)
        #expect(!first.isRepeating)
        let secondBytes = second.sentBytes
        await first.disconnect()
        try await waitUntil { second.sentBytes > secondBytes }
        #expect(second.isConnected && second.isRepeating)
        await second.disconnect()
        #expect(!second.isRepeating && second.repeatingPresetID == nil)
    }

    @Test @MainActor
    func invalidIntervalAndInvalidPayloadDoNotLeaveAnActivePresetTimer() async throws {
        let context = try WindowTestContext()
        defer { context.cleanUp() }
        let device = try PseudoTerminal()
        let session = context.session()
        let preset = CommandPreset(name: "Bad HEX", text: "GG", isHex: true, ending: .none, encoding: .utf8)
        context.presets.append(preset)
        session.selectedPath = device.path
        await session.connect()
        for interval in ["9", "3600001", "invalid"] {
            session.interval = interval
            session.togglePresetRepeating(preset)
            #expect(!session.isRepeating && session.repeatingPresetID == nil)
            #expect(session.errorMessage != nil && session.sentBytes == 0)
            session.errorMessage = nil
        }
        session.interval = "20"
        session.togglePresetRepeating(preset)
        try await waitUntil { !session.isRepeating }
        #expect(session.repeatingPresetID == nil && session.errorMessage != nil && session.sentBytes == 0)
        await session.disconnect()
    }
}

@Suite("Payload encoding")
struct PayloadTests {
    @Test func hexAndLineEndingsAreExact() throws {
        let result = try PayloadCodec.encode("00 aA\n11 13 FF", hex: true, encoding: .utf8, ending: .crlf)
        #expect(result == Data([0, 0xAA, 0x11, 0x13, 0xFF, 13, 10]))
        #expect(PayloadCodec.hex(result) == "00 AA 11 13 FF 0D 0A")
    }

    @Test(arguments: ["A", "AA GG", "0xFF", "ＡＡ", "😀😀", ""])
    func malformedPayloadIsRejected(_ value: String) {
        #expect(throws: (any Error).self) {
            try PayloadCodec.encode(value, hex: true, encoding: .utf8, ending: .none)
        }
    }

    @Test func textPreservesUnicodeAndRejectsLossyASCII() throws {
        let text = "中文🙂"
        #expect(try PayloadCodec.encode(text, hex: false, encoding: .utf8, ending: .lf) == Data((text + "\n").utf8))
        #expect(throws: (any Error).self) {
            try PayloadCodec.encode(text, hex: false, encoding: .ascii, ending: .none)
        }
        #expect(throws: (any Error).self) {
            try PayloadCodec.encode(String(repeating: "A", count: 65_536), hex: false, encoding: .utf8, ending: .crlf)
        }
    }

    @Test(arguments: [TextEncoding.utf8, .gb18030, .big5, .utf16LE, .shiftJIS])
    func everyReadBoundaryPreservesMultibyteCharacters(_ encoding: TextEncoding) throws {
        let text = encoding == .shiftJIS ? "通信ABC\r\n" : encoding == .utf16LE || encoding == .utf8 ? "中文🙂ABC\r\n" : "中文ABC\r\n"
        let data = try #require(text.data(using: encoding.foundationEncoding))
        for boundary in 0...data.count {
            var decoder = StreamingTextDecoder(encoding: encoding)
            let result = decoder.decode(Data(data.prefix(boundary))) + decoder.decode(Data(data.dropFirst(boundary)))
            #expect(result == text, "Encoding: \(encoding), boundary: \(boundary)")
        }
    }
}

@Suite("Virtual serial integration", .serialized)
struct SerialIntegrationTests {
    @Test func binaryWriteAndFragmentedReceive() async throws {
        let terminal = try PseudoTerminal()
        let transport = SerialTransport()
        let stream = try await transport.open(SerialConfiguration(path: terminal.path))
        let payload = Data([0, 1, 10, 13, 0x11, 0x13, 0x80, 0xFF])
        let written = try await transport.write(payload)
        #expect(written == payload.count)
        #expect(try await readMaster(terminal.master, count: payload.count) == payload)
        // Device-to-app input arrives in separate OS reads, including split UTF-8.
        let incoming = Data("中文🙂\r\n".utf8)
        for byte in incoming {
            var value = byte
            #expect(Darwin.write(terminal.master, &value, 1) == 1)
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(try await collect(stream, count: incoming.count) == incoming)
        await transport.close()
    }

    @Test func exclusiveAccessAndReopen() async throws {
        let terminal = try PseudoTerminal()
        let first = SerialTransport()
        let second = SerialTransport()
        let stream = try await first.open(SerialConfiguration(path: terminal.path))
        do {
            _ = try await second.open(SerialConfiguration(path: terminal.path))
            Issue.record("The same serial port was opened twice")
        } catch {
            #expect(error is SerialTransportError)
        }
        await first.close()
        for try await _ in stream {}
        let reopened = try await first.open(SerialConfiguration(path: terminal.path))
        var byte: UInt8 = 0x5A
        #expect(Darwin.write(terminal.master, &byte, 1) == 1)
        #expect(try await collect(reopened, count: 1) == Data([0x5A]))
        await first.close()
    }

    @Test func invalidPathFailsWithoutOpeningAnything() async {
        let transport = SerialTransport()
        do {
            _ = try await transport.open(SerialConfiguration(path: "/not/a/device"))
            Issue.record("Invalid device path accepted")
        } catch {
            #expect(error is SerialTransportError)
        }
    }

    @Test func removedDeviceEndsStreamWithError() async throws {
        let terminal = try PseudoTerminal()
        let transport = SerialTransport()
        let stream = try await transport.open(SerialConfiguration(path: terminal.path))
        terminal.disconnectDevice()
        do {
            _ = try await collect(stream, count: 1)
            Issue.record("Disconnected device unexpectedly delivered data")
        } catch {
            #expect(error is SerialTransportError)
        }
        await transport.close()
    }

    @Test @MainActor
    func sessionCountsBytesAndStopsRepeatingOnDisconnect() async throws {
        let terminal = try PseudoTerminal()
        let session = SerialSession()
        session.selectedPath = terminal.path
        session.input = "AA 11 13 FF"
        session.sendHex = true
        session.ending = .crlf
        await session.connect()
        #expect(session.isConnected)
        #expect(await session.send())
        #expect(session.sentBytes == 6)
        #expect(try await readMaster(terminal.master, count: 6) == Data([0xAA, 0x11, 0x13, 0xFF, 13, 10]))
        let reply = Data("回复中文🙂\r\n".utf8)
        let incomingCount = reply.withUnsafeBytes { Darwin.write(terminal.master, $0.baseAddress, reply.count) }
        #expect(incomingCount == reply.count)
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.exportText().contains(PayloadCodec.hex(reply)))
        #expect(session.receivedBytes == reply.count)
        session.interval = "20"
        session.toggleRepeating()
        try await Task.sleep(for: .milliseconds(65))
        #expect(session.isRepeating)
        await session.disconnect()
        #expect(!session.isRepeating)
        #expect(!session.isConnected)
        let finalCount = session.sentBytes
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.sentBytes == finalCount)
    }

    @Test @MainActor
    func closingWindowMonitorReleasesExclusivePortAndStopsSending() async throws {
        let terminal = try PseudoTerminal()
        let session = SerialSession()
        session.selectedPath = terminal.path
        session.input = "PING"
        session.ending = .none
        session.interval = "20"
        let monitor = Task { await session.monitor() }
        await session.connect()
        #expect(session.isConnected)
        session.toggleRepeating()
        try await Task.sleep(for: .milliseconds(30))
        #expect(session.isRepeating)
        // Closing the SwiftUI window cancels this same .task lifecycle.
        monitor.cancel()
        await monitor.value
        #expect(!session.isConnected)
        #expect(!session.isRepeating)
        let sentAfterClose = session.sentBytes
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.sentBytes == sentAfterClose)
        let replacement = SerialTransport()
        _ = try await replacement.open(SerialConfiguration(path: terminal.path))
        await replacement.close()
    }

    @Test @MainActor
    func fragmentedTelemetryRemainsOneLiveRowAcrossFlushes() async throws {
        let terminal = try PseudoTerminal()
        let session = SerialSession()
        session.selectedPath = terminal.path
        session.timestamps = false
        await session.connect()
        defer { Task { await session.disconnect() } }
        #expect(session.isConnected)
        session.clearLog()
        let chunks = ["$AZCT,P,ACQUSaveO", "N,Velocity:1500,IPV", "4_not_find*hh\r", "\nNEXT\r\n"]
        var received = ""
        for chunk in chunks {
            let data = Data(chunk.utf8)
            #expect(data.withUnsafeBytes { Darwin.write(terminal.master, $0.baseAddress, data.count) } == data.count)
            received += chunk
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while session.receivedBytes < received.utf8.count, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(session.receivedBytes == received.utf8.count)
            // Each fragment has reached a separate UI batch before the next device write.
            #expect(session.logText == (chunk == chunks.last ? "RX  $AZCT,P,ACQUSaveON,Velocity:1500,IPV4_not_find*hh\nRX  NEXT" : "RX  " + received.replacingOccurrences(of: "\r", with: "")))
        }
        session.receiveHex = true
        let displayedHex = session.logText.components(separatedBy: "\n").map { String($0.dropFirst(4)) }.joined(separator: " ")
        #expect(displayedHex == PayloadCodec.hex(Data(received.utf8)))
        #expect(session.exportText().contains("0D 0A"))
        await session.disconnect()
    }

    @Test @MainActor
    func sustainedReceiveRemainsBoundedWhilePausedAndClearPreservesCounters() async throws {
        let terminal = try PseudoTerminal()
        let session = SerialSession()
        session.selectedPath = terminal.path
        let monitor = Task { await session.monitor() }
        defer { monitor.cancel() }
        await session.connect()
        #expect(session.isConnected)
        session.clearLog()
        session.paused = true

        let payload = Data(repeating: 0x41, count: 1_048_576)
        var offset = 0
        // Hosted macOS runners can drain a PTY much more slowly than a local Mac.
        // Keep a generous safety timeout: this checks exact bytes and bounded storage, not throughput.
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while offset < payload.count, ContinuousClock.now < deadline {
            let written = payload.withUnsafeBytes {
                Darwin.write(terminal.master, $0.baseAddress?.advanced(by: offset), payload.count - offset)
            }
            if written > 0 {
                offset += written
            } else {
                #expect(errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        #expect(offset == payload.count)
        let receiveDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while session.receivedBytes < payload.count, ContinuousClock.now < receiveDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.receivedBytes == payload.count)
        #expect(session.logText.isEmpty)
        #expect(session.discardedEntries > 0)
        session.paused = false
        #expect(session.logText.contains("RX"))
        #expect(session.logText.utf8.count < 512_000)

        var byte: UInt8 = 0x42
        #expect(Darwin.write(terminal.master, &byte, 1) == 1)
        try await Task.sleep(for: .milliseconds(25))
        session.clearLog()
        // Completion is asynchronous; a hosted runner may need more than 100 ms to deliver this byte.
        try await waitUntil { session.receivedBytes == payload.count + 1 }
        #expect(session.receivedBytes == payload.count + 1)
        #expect(session.isConnected)
        await session.disconnect()
    }
}
