import Foundation
import Testing
@testable import SerialDebugToolCore

private struct TextMirror {
    private(set) var text = ""
    private var revision = 0

    mutating func apply(_ update: TerminalTextUpdate) {
        guard revision != update.revision else { return }
        #expect(update.revision == revision + 1)
        let storage = NSMutableString(string: text)
        #expect(update.removedPrefixUTF16 <= storage.length)
        #expect(update.removedPrefixUTF16 + update.removedSuffixUTF16 <= storage.length)
        storage.deleteCharacters(in: NSRange(location: storage.length - update.removedSuffixUTF16, length: update.removedSuffixUTF16))
        storage.replaceCharacters(in: NSRange(location: 0, length: update.removedPrefixUTF16), with: update.insertedPrefix)
        storage.append(update.appendedText)
        text = storage as String
        revision = update.revision
    }
}

private func referenceLog(_ entries: [LogEntry], discarded: Int, options: LogDisplayOptions) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    var records: [(date: Date, direction: LogDirection, text: String)] = []
    if options.hex {
        records = entries.map { ($0.date, $0.direction, $0.direction == .system ? $0.text : PayloadCodec.hex($0.data)) }
    } else {
        var current: Int?
        var lastWasCR = false
        for entry in entries {
            if entry.direction != .received { current = nil; lastWasCR = false }
            for scalar in entry.text.unicodeScalars {
                if scalar == "\n", lastWasCR { lastWasCR = false; continue }
                lastWasCR = scalar == "\r"
                if current == nil {
                    records.append((entry.date, entry.direction, ""))
                    current = records.count - 1
                }
                if scalar == "\n" || scalar == "\r" {
                    current = nil
                } else if let index = current {
                    records[index].text.unicodeScalars.append(scalar)
                }
            }
            if entry.direction != .received { current = nil; lastWasCR = false }
        }
    }
    var lines: [String] = []
    if discarded > 0 {
        lines.append(AppText.discardedRecords(discarded))
    }
    for record in records {
        if record.direction == .received && !options.showReceived { continue }
        if record.direction == .sent && !options.showSent { continue }
        if record.direction == .system && !options.showSystem { continue }
        guard options.search.isEmpty || record.text.localizedCaseInsensitiveContains(options.search) else { continue }
        let time = options.timestamps ? "[\(formatter.string(from: record.date))] " : ""
        lines.append("\(time)\(record.direction.rawValue)  \(record.text)")
    }
    if lines.count == 1, discarded > 0 { return lines.joined(separator: "\n") + "\n" }

    return lines.joined(separator: "\n")
}

@Suite("Incremental terminal output")
struct LogRenderingTests {
    @Test func rollingUTF16PatchesMatchFullOutputAndRemainBounded() {
        var renderer = TerminalLogRenderer()
        var mirror = TextMirror()
        var entries: [LogEntry] = []
        var discarded = 0
        for index in 0..<160 {
            let previousIDs = Set(entries.map(\.id))
            let content = index.isMultiple(of: 3) ? "中文🙂 \(index)\n" : "DATA \(index)"
            entries.append(LogEntry(
                date: Date(timeIntervalSince1970: Double(index)),
                direction: index.isMultiple(of: 4) ? .sent : .received,
                data: Data(content.utf8),
                text: content
            ))
            if entries.count > 12 {
                entries.removeFirst(3)
                discarded += 3
            }
            let options = LogDisplayOptions(
                hex: (index / 20).isMultiple(of: 2),
                timestamps: (index / 15).isMultiple(of: 2),
                showSent: (index / 12).isMultiple(of: 2),
                search: (index / 10).isMultiple(of: 2) ? "" : "DATA"
            )
            let retainedIDs = Set(entries.map(\.id))
            renderer.render(
                entries: entries,
                discardedEntries: discarded,
                options: options,
                appendedEntries: entries.filter { !previousIDs.contains($0.id) },
                removedEntryIDs: Array(previousIDs.subtracting(retainedIDs))
            )
            mirror.apply(renderer.update)
            #expect(mirror.text == renderer.text)
            #expect(renderer.text == referenceLog(entries, discarded: discarded, options: options))
            #expect(renderer.cachedEntryCount <= entries.count)
        }
        renderer.clear()
        mirror.apply(renderer.update)
        #expect(mirror.text.isEmpty)
        #expect(renderer.cachedEntryCount == 0)
    }

    @Test func unfinishedReceiveContinuesAndHiddenDataDoesNotRefreshView() {
        var renderer = TerminalLogRenderer()
        var options = LogDisplayOptions(timestamps: false, showSent: false)
        var entries = [LogEntry(date: .now, direction: .received, data: Data([65]), text: "A")]
        renderer.render(entries: entries, discardedEntries: 0, options: options)
        entries.append(LogEntry(date: .now, direction: .received, data: Data([66]), text: "B"))
        renderer.render(entries: entries, discardedEntries: 0, options: options)
        #expect(renderer.update.removedPrefixUTF16 == 0)
        #expect(renderer.update.insertedPrefix.isEmpty)
        #expect(renderer.text == "RX  AB")
        #expect(renderer.update.removedSuffixUTF16 == 0)
        #expect(renderer.update.appendedText == "B")
        let revision = renderer.update.revision
        entries.append(LogEntry(date: .now, direction: .sent, data: Data([67]), text: "C"))
        renderer.render(entries: entries, discardedEntries: 0, options: options)
        #expect(renderer.update.revision == revision)
        options.showSent = true
        renderer.render(entries: entries, discardedEntries: 0, options: options)
        #expect(renderer.text == "RX  AB\nTX  C")
    }

    @Test func changedEncodingAndFilteringRefreshCachedEntries() {
        var renderer = TerminalLogRenderer()
        var mirror = TextMirror()
        var entries = [LogEntry(date: .now, direction: .received, data: Data([65]), text: "old")]
        let options = LogDisplayOptions(timestamps: false)
        renderer.render(entries: entries, discardedEntries: 0, options: options)
        mirror.apply(renderer.update)
        entries[0].text = "中文🙂"
        renderer.invalidate()
        renderer.render(entries: entries, discardedEntries: 0, options: options)
        mirror.apply(renderer.update)
        #expect(mirror.text == "RX  中文🙂")
        let filtered = LogDisplayOptions(timestamps: false, search: "missing")
        renderer.render(entries: entries, discardedEntries: 0, options: filtered)
        mirror.apply(renderer.update)
        #expect(mirror.text.isEmpty)
        renderer.render(entries: [], discardedEntries: 1, options: options)
        mirror.apply(renderer.update)
        #expect(mirror.text == referenceLog([], discarded: 1, options: options))
    }

    @Test func hexadecimalFormattingCoversEveryByteAndEmptyData() {
        let bytes = Data((0...255).map { UInt8($0) })
        let expected = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        #expect(PayloadCodec.hex(bytes) == expected)
        #expect(PayloadCodec.hex(Data()).isEmpty)
    }
}

@Suite("Serial text line boundaries")
struct TextLineBoundaryTests {
    private func entry(_ text: String, direction: LogDirection = .received, date: Date = .now) -> LogEntry {
        LogEntry(date: date, direction: direction, data: Data(text.utf8), text: text)
    }

    @Test func reportedThreeReadMessageIsOneLiveLine() {
        let chunks = [
            "$AZCT,P,IDLE,35.86V,43.04mA,5.16V,114.40mA,LaunB:0B,LFM_21_27KHZ,ACQUSaveO",
            "N,LAUNSaveOFF,HexShowOFF,ACKoff,ID:2,Vol:200,Velocity:1500,IPV",
            "4_not_find,28.03GB,20261022_122939*hh\r\n"
        ]
        var entries: [LogEntry] = []
        var renderer = TerminalLogRenderer()
        var mirror = TextMirror()
        for chunk in chunks {
            let next = entry(chunk)
            entries.append(next)
            renderer.render(entries: entries, discardedEntries: 0, options: LogDisplayOptions(timestamps: false), appendedEntries: [next])
            mirror.apply(renderer.update)
            #expect(mirror.text == "RX  " + entries.map(\.text).joined().replacingOccurrences(of: "\r\n", with: ""))
        }
        #expect(renderer.text.components(separatedBy: "RX  ").count == 2)
        #expect(!renderer.text.contains("\n"))
    }

    @Test func everyUTF8SplitAndCRLFBoundaryPreservesRows() {
        let message = "中文🙂ABC\r\n第二行\n第三行\r最后一行"
        let data = Data(message.utf8)
        for boundary in 0...data.count {
            var decoder = StreamingTextDecoder(encoding: .utf8)
            var entries: [LogEntry] = []
            var renderer = TerminalLogRenderer()
            var mirror = TextMirror()
            for chunk in [Data(data.prefix(boundary)), Data(data.dropFirst(boundary))] {
                let next = LogEntry(date: .now, direction: .received, data: chunk, text: decoder.decode(chunk))
                entries.append(next)
                renderer.render(entries: entries, discardedEntries: 0, options: LogDisplayOptions(timestamps: false), appendedEntries: [next])
                mirror.apply(renderer.update)
            }
            #expect(mirror.text == "RX  中文🙂ABC\nRX  第二行\nRX  第三行\nRX  最后一行", "boundary: \(boundary)")
        }
    }

    @Test func compactSpacingRetainsDeliberateBlankLineAndSeparatesTX() {
        let entries = [entry("one\r\n"), entry("two\r"), entry("\n\r\nthree\n"), entry("command\r\n", direction: .sent), entry("reply\n")]
        var renderer = TerminalLogRenderer()
        renderer.render(entries: entries, discardedEntries: 0, options: LogDisplayOptions(timestamps: false))
        #expect(renderer.text == "RX  one\nRX  two\nRX  \nRX  three\nTX  command\nRX  reply")
    }

    @Test func timestampComesFromFirstFragmentAndSearchMatchesWholeMessage() {
        let firstDate = Date(timeIntervalSince1970: 100)
        let entries = [entry("ACQUSaveO", date: firstDate), entry("N\r\n", date: firstDate.addingTimeInterval(0.04))]
        var renderer = TerminalLogRenderer()
        renderer.render(entries: entries, discardedEntries: 0, options: LogDisplayOptions(search: "ACQUSaveON"))
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        #expect(renderer.text == "[\(formatter.string(from: firstDate))] RX  ACQUSaveON")
        renderer.render(entries: entries, discardedEntries: 0, options: LogDisplayOptions(hex: true, timestamps: false))
        #expect(renderer.text == entries.map { "RX  " + PayloadCodec.hex($0.data) }.joined(separator: "\n"))
    }

    @Test func trimmingOpenLineAndChangingSearchProducesValidUTF16Patches() {
        var entries: [LogEntry] = []
        var renderer = TerminalLogRenderer()
        var mirror = TextMirror()
        for index in 0..<200 {
            let next = entry(index.isMultiple(of: 3) ? "🙂" : "中文")
            entries.append(next)
            let removed = entries.count > 8 ? [entries.removeFirst().id] : []
            let options = LogDisplayOptions(timestamps: false, search: index.isMultiple(of: 5) ? "中文🙂" : "")
            renderer.render(entries: entries, discardedEntries: max(0, index - 7), options: options, appendedEntries: [next], removedEntryIDs: removed)
            mirror.apply(renderer.update)
            #expect(mirror.text == referenceLog(entries, discarded: max(0, index - 7), options: options))
            #expect(renderer.cachedEntryCount <= 1)
        }
        renderer.clear()
        mirror.apply(renderer.update)
        #expect(mirror.text.isEmpty)
    }
}


@Suite("Log category visibility")
struct LogVisibilityTests {
    @Test func eachCategoryCanBeHiddenAndRestoredWithoutLosingData() {
        let entries = [
            LogEntry(date: .now, direction: .received, data: Data("reply\n".utf8), text: "reply\n"),
            LogEntry(date: .now, direction: .sent, data: Data("command\r\n".utf8), text: "command\r\n"),
            LogEntry(date: .now, direction: .system, data: Data(), text: "connected")
        ]
        for hex in [false, true] {
            var renderer = TerminalLogRenderer()
            var mirror = TextMirror()
            for received in [false, true] {
                for sent in [false, true] {
                    for system in [false, true] {
                        let options = LogDisplayOptions(hex: hex, timestamps: false, showReceived: received, showSent: sent, showSystem: system)
                        renderer.render(entries: entries, discardedEntries: 0, options: options, appendedEntries: [])
                        mirror.apply(renderer.update)
                        #expect(mirror.text == referenceLog(entries, discarded: 0, options: options))
                    }
                }
            }
        }
    }

    @Test func hiddenReceiveContinuesAssemblingWhileNewDataArrives() {
        var renderer = TerminalLogRenderer()
        var mirror = TextMirror()
        var entries: [LogEntry] = []
        for fragment in ["$AZCT,ACQUSaveO", "N\r\n"] {
            let entry = LogEntry(date: .now, direction: .received, data: Data(fragment.utf8), text: fragment)
            entries.append(entry)
            renderer.render(entries: entries, discardedEntries: 0, options: LogDisplayOptions(timestamps: false, showReceived: false), appendedEntries: [entry])
            mirror.apply(renderer.update)
            #expect(mirror.text.isEmpty)
        }
        renderer.render(entries: entries, discardedEntries: 0, options: LogDisplayOptions(timestamps: false), appendedEntries: [])
        mirror.apply(renderer.update)
        #expect(mirror.text == "RX  $AZCT,ACQUSaveON")
    }
}
