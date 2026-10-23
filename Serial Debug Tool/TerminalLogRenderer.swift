import Foundation

/// A UTF-16 patch for NSTextStorage. A view that misses a revision uses the full text instead.
struct TerminalTextUpdate: Equatable {
    var revision = 0
    var removedPrefixUTF16 = 0
    var removedSuffixUTF16 = 0
    var insertedPrefix = ""
    var appendedText = ""
}

struct LogDisplayOptions: Equatable {
    var hex = false
    var timestamps = true
    var showReceived = true
    var showSent = true
    var showSystem = true
    var search = ""
}

/// Formats each retained entry once and produces prefix-trim / suffix-append updates.
struct TerminalLogRenderer {
    private struct Line {
        let id: UUID
        let content: String
        let display: String
        let utf16Count: Int
    }

    private var rows = TerminalTextRows()
    private var cache: [UUID: Line] = [:]
    private var visibleLines: [Line] = []
    private var header = ""
    private var previousOptions: LogDisplayOptions?
    private var invalidated = false
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private(set) var text = ""
    private(set) var update = TerminalTextUpdate()
    var cachedEntryCount: Int { cache.count }

    mutating func invalidate() {
        invalidated = true
    }

    mutating func clear() {
        let oldLength = text.utf16.count
        rows = TerminalTextRows()
        cache.removeAll(keepingCapacity: true)
        visibleLines.removeAll(keepingCapacity: true)
        header = ""
        previousOptions = nil
        invalidated = false
        text = ""
        update = TerminalTextUpdate(revision: update.revision + 1, removedPrefixUTF16: oldLength)
    }

    mutating func render(
        entries: [LogEntry],
        discardedEntries: Int,
        options: LogDisplayOptions,
        appendedEntries: [LogEntry]? = nil,
        removedEntryIDs: [UUID] = []
    ) {
        let displayEntries: [LogEntry]
        if options.hex {
            // Binary display needs only the original reads, not a second set of text rows.
            rows = TerminalTextRows()
            displayEntries = entries
        } else {
            let rebuildRows = invalidated || previousOptions == nil || previousOptions?.hex == true
            if rebuildRows { rows = TerminalTextRows() }
            let changedRows = rows.update(
                entries: entries,
                appendedEntries: rebuildRows ? nil : appendedEntries,
                removedEntryIDs: removedEntryIDs
            )
            for id in changedRows { cache.removeValue(forKey: id) }
            displayEntries = rows.entries
        }
        let fullRefresh = invalidated || previousOptions != options
        if invalidated || previousOptions?.hex != options.hex || previousOptions?.timestamps != options.timestamps {
            cache.removeAll(keepingCapacity: true)
        }
        var next: [Line] = []
        next.reserveCapacity(displayEntries.count)
        let incoming: [LogEntry]
        if options.hex, !fullRefresh, let appendedEntries {
            let removedIDs = Set(removedEntryIDs)
            for id in removedIDs { cache.removeValue(forKey: id) }
            let dropped = visibleLines.prefix { removedIDs.contains($0.id) }.count
            next.append(contentsOf: visibleLines.dropFirst(dropped))
            incoming = appendedEntries.filter { !removedIDs.contains($0.id) }
        } else {
            // Rebuild only after display settings change or after paused display resumes.
            let retainedIDs = Set(displayEntries.map(\.id))
            for id in cache.keys.filter({ !retainedIDs.contains($0) }) {
                cache.removeValue(forKey: id)
            }
            incoming = displayEntries
        }
        for entry in incoming {
            if entry.direction == .received && !options.showReceived { continue }
            if entry.direction == .sent && !options.showSent { continue }
            if entry.direction == .system && !options.showSystem { continue }
            let line: Line
            if let cached = cache[entry.id] {
                line = cached
            } else {
                let content = entry.direction == .system ? entry.text : options.hex ? PayloadCodec.hex(entry.data) : entry.text
                let time = options.timestamps ? "[\(formatter.string(from: entry.date))] " : ""
                let display = "\(time)\(entry.direction.rawValue)  \(content)"
                line = Line(id: entry.id, content: content, display: display, utf16Count: display.utf16.count)
                cache[entry.id] = line
            }
            if options.search.isEmpty || line.content.localizedCaseInsensitiveContains(options.search) {
                next.append(line)
            }
        }
        let nextHeader = discardedEntries > 0
            ? AppText.discardedRecords(discardedEntries) + "\n"
            : ""

        let dropped = next.first.flatMap { first in visibleLines.firstIndex { $0.id == first.id } } ?? visibleLines.count
        let retained = visibleLines.dropFirst(dropped)
        var kept = 0
        if !fullRefresh {
            while kept < min(retained.count, next.count),
                  retained[retained.startIndex + kept].id == next[kept].id,
                  retained[retained.startIndex + kept].display == next[kept].display {
                kept += 1
            }
        }

        let removedBodyLength = visibleLines.prefix(dropped).reduce(0) { $0 + $1.utf16Count }
            + (dropped < visibleLines.count ? dropped : max(0, dropped - 1))
        let replaceHeader = dropped > 0 || header != nextHeader || fullRefresh
        let removedPrefix = replaceHeader ? header.utf16.count + removedBodyLength : 0
        let insertedPrefix = replaceHeader ? nextHeader : ""
        let removedTail = retained.dropFirst(kept)
        var removedSuffix = removedTail.reduce(0) { $0 + $1.utf16Count }
            + (kept > 0 ? removedTail.count : max(0, removedTail.count - 1))
        let tail = next.dropFirst(kept).map(\.display).joined(separator: "\n")
        var appended = (kept > 0 && next.count > kept ? "\n" : "") + tail
        if !fullRefresh, removedTail.count == 1, kept < next.count,
           retained[retained.startIndex + kept].id == next[kept].id {
            let previousTail = (kept > 0 ? "\n" : "") + retained[retained.startIndex + kept].display
            if appended.hasPrefix(previousTail) {
                removedSuffix = 0
                appended = String(appended.dropFirst(previousTail.count))
            }
        }

        if removedPrefix > 0 || removedSuffix > 0 || !insertedPrefix.isEmpty || !appended.isEmpty {
            // Only the unfinished line changes when another read continues the same message.
            let start = text.utf16.index(text.utf16.startIndex, offsetBy: removedPrefix)
            let end = text.utf16.index(text.utf16.endIndex, offsetBy: -removedSuffix)
            let nextText = insertedPrefix + text[start..<end] + appended
            if nextText != text {
                update = TerminalTextUpdate(
                    revision: update.revision + 1,
                    removedPrefixUTF16: removedPrefix,
                    removedSuffixUTF16: removedSuffix,
                    insertedPrefix: insertedPrefix,
                    appendedText: appended
                )
                text = nextText
            }
        }
        visibleLines = next
        header = nextHeader
        previousOptions = options
        invalidated = false
    }
}


/// Text rows follow device CR/LF delimiters, independently of serial read boundaries.
/// Retain the source fragments so trimming the byte buffer also trims an unfinished row.
private struct TerminalTextRows {
    private struct Fragment {
        let sourceID: UUID
        let date: Date
        let text: String
    }

    private struct Row {
        var entry: LogEntry
        var fragments: [Fragment]
    }

    private var rows: [Row] = []
    private var sourceIDs: Set<UUID> = []
    private var openRowID: UUID?
    private var swallowLF = false

    var entries: [LogEntry] { rows.map(\.entry) }

    mutating func update(
        entries: [LogEntry],
        appendedEntries: [LogEntry]?,
        removedEntryIDs: [UUID]
    ) -> Set<UUID> {
        let removed: Set<UUID>
        let incoming: [LogEntry]
        if let appendedEntries {
            // The session already supplies the delta, including entries evicted in this batch.
            removed = Set(removedEntryIDs)
            incoming = removed.isEmpty ? appendedEntries : appendedEntries.filter { !removed.contains($0.id) }
        } else {
            let retainedIDs = Set(entries.map(\.id))
            removed = sourceIDs.subtracting(retainedIDs)
            incoming = entries.filter { !sourceIDs.contains($0.id) }
        }

        var changed: Set<UUID> = []
        if !removed.isEmpty {
            var dropped = 0
            while dropped < rows.count, rows[dropped].fragments.allSatisfy({ removed.contains($0.sourceID) }) {
                dropped += 1
            }
            if dropped > 0 { rows.removeFirst(dropped) }
            if !rows.isEmpty {
                let oldCount = rows[0].fragments.count
                rows[0].fragments.removeAll { removed.contains($0.sourceID) }
                if oldCount != rows[0].fragments.count, let first = rows[0].fragments.first {
                    let wasOpen = openRowID == rows[0].entry.id
                    rows[0].entry = LogEntry(
                        date: first.date,
                        direction: rows[0].entry.direction,
                        data: Data(),
                        text: rows[0].fragments.map(\.text).joined()
                    )
                    if wasOpen { openRowID = rows[0].entry.id }
                }
            }
            if openRowID != rows.last?.entry.id { openRowID = nil }
            sourceIDs.subtract(removed)
        }
        for entry in incoming {
            sourceIDs.insert(entry.id)
            if entry.direction != .received {
                openRowID = nil
                swallowLF = false
            }
            // A decoder can hold an incomplete multibyte character between reads.
            guard !entry.text.isEmpty else { continue }
            var text = entry.text
            if entry.direction == .received {
                if swallowLF, text.unicodeScalars.first == "\n" { text.removeFirst() }
                swallowLF = entry.text.unicodeScalars.last == "\r"
            }
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let pieces = normalized.components(separatedBy: "\n")
            for (index, piece) in pieces.enumerated() {
                // A trailing terminator closes the row; it does not create a blank log record.
                if index == pieces.count - 1 && piece.isEmpty { break }
                let fragment = Fragment(sourceID: entry.id, date: entry.date, text: piece)
                if entry.direction == .received, openRowID == rows.last?.entry.id, !rows.isEmpty {
                    let last = rows.count - 1
                    rows[last].entry.text += piece
                    rows[last].fragments.append(fragment)
                    changed.insert(rows[last].entry.id)
                } else {
                    rows.append(Row(
                        entry: LogEntry(date: entry.date, direction: entry.direction, data: Data(), text: piece),
                        fragments: [fragment]
                    ))
                }
                if entry.direction == .received {
                    openRowID = index < pieces.count - 1 ? nil : rows.last?.entry.id
                }
            }
        }
        return changed
    }
}
