import Foundation
import Darwin
import Testing
@testable import SerialDebugToolCore

@Suite("Performance workloads")
struct PerformanceTests {
    @Test func descriptorEventsStayIdleAndResumeAcrossSeparateBursts() async throws {
        let pipe = Pipe()
        let input = pipe.fileHandleForReading
        let output = pipe.fileHandleForWriting
        let fd = input.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let events = try DescriptorReadEvents(descriptors: [fd])
        let received = ReadEventResult()
        let consumer = Task {
            for await _ in events.stream {
                var bytes = [UInt8](repeating: 0, count: 1024)
                let count = Darwin.read(fd, &bytes, bytes.count)
                await received.record(count > 0 ? Data(bytes.prefix(count)) : Data())
                if count == 0 { events.remove(fd) }
                else { events.rearm() }
            }
        }
        defer {
            consumer.cancel()
            events.cancel()
            try? input.close()
            try? output.close()
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(await received.wakeups == 0)
        for index in 0..<3 {
            try output.write(contentsOf: Data(repeating: UInt8(index), count: 256))
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await received.data.count < (index + 1) * 256, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await received.data.count == (index + 1) * 256)
        }
        #expect(await received.data == Data((0..<3).flatMap { Array(repeating: UInt8($0), count: 256) }))
        try output.close()
        try await Task.sleep(for: .milliseconds(80))
        let countAfterEOF = await received.wakeups
        try await Task.sleep(for: .milliseconds(80))
        #expect(await received.wakeups == countAfterEOF)
        events.cancel()
        await consumer.value
    }

    // Opt-in timing keeps machine load out of correctness assertions.
    @Test func rollingFilteredLogBenchmark() throws {
        guard ProcessInfo.processInfo.environment["SERIAL_PERFORMANCE_CHECK"] == "1" else { return }
        let batches = (0..<2_000).map { batch in
            (0..<4).map { offset in
                let text = "$GNGGA,中文🙂,\(batch * 4 + offset),quality=1,altitude=123.45\r\n"
                return LogEntry(date: Date(timeIntervalSince1970: Double(batch)), direction: .received,
                                data: Data(text.utf8), text: text)
            }
        }
        var renderer = TerminalLogRenderer()
        var entries: [LogEntry] = []
        var discarded = 0
        let options = LogDisplayOptions(search: "quality=1")
        let elapsed = ContinuousClock().measure {
            for batch in batches {
                entries.append(contentsOf: batch)
                let removed = entries.count > 1_500 ? Array(entries.prefix(300).map(\.id)) : []
                entries.removeFirst(removed.count)
                discarded += removed.count
                renderer.render(entries: entries, discardedEntries: discarded, options: options,
                                appendedEntries: batch, removedEntryIDs: removed)
            }
        }
        #expect(renderer.text.contains("7999,quality=1"))
        print("PERFORMANCE rolling filtered log (8000 lines): \(elapsed)")
    }
}

private actor ReadEventResult {
    var wakeups = 0
    var data = Data()
    func record(_ bytes: Data) {
        wakeups += 1
        data.append(bytes)
    }
}
