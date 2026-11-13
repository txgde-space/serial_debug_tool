import SwiftUI
import AppKit

/// Observe high-frequency log and counter changes inside their own views.
@MainActor
struct TerminalOutputView: View {
    let session: SerialSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAtLatest = true
    @State private var scrollToLatestRequest = 0

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TerminalTextView(
                text: session.logText,
                update: session.logUpdate,
                autoScroll: session.autoScroll,
                wrapLines: session.autoWrap,
                scrollToLatestRequest: scrollToLatestRequest,
                isAtLatest: $isAtLatest
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .trailing, spacing: 8) {
                if session.paused {
                    Label(AppText.displayPaused, systemImage: "pause.circle.fill")
                        .font(.caption)
                        .padding(9)
                        .background(.regularMaterial, in: Capsule())
                }
                if !isAtLatest {
                    Button {
                        session.autoScroll = true
                        scrollToLatestRequest += 1
                    } label: {
                        Label(AppText.scrollToLatestLog, systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.bordered)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("scrollToLatestLog")
                    .transition(.opacity)
                }
            }
            .padding(14)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: session.paused)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isAtLatest)
    }
}

@MainActor
struct TrafficCountersView: View {
    let session: SerialSession

    var body: some View {
        HStack(spacing: 12) {
            counter("RX", count: session.receivedBytes, color: .green)
            counter("TX", count: session.sentBytes, color: .blue)
            Button(AppText.resetCounters) { session.resetCounters() }.buttonStyle(.borderless)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func counter(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Text(title).fontWeight(.semibold).foregroundStyle(color)
            Text("\(count.formatted()) B").monospacedDigit()
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(title == "RX" ? AppText.received : AppText.sent)
        .accessibilityValue(AppText.byteCount(count))
    }
}

@MainActor
private struct TerminalTextView: NSViewRepresentable {
    let text: String
    let update: TerminalTextUpdate
    let autoScroll: Bool
    let wrapLines: Bool
    let scrollToLatestRequest: Int
    @Binding var isAtLatest: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        makeScrollView(coordinator: context.coordinator)
    }

    fileprivate func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        // Use TextKit 1 explicitly for the character-based viewport anchors below.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(
            width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude
        ))
        layout.addTextContainer(container)
        let view = NSTextView(frame: scroll.bounds, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.setAccessibilityLabel(AppText.outputLog)
        view.isRichText = false
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .textColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = true
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = view.maxSize
        view.textContainer?.widthTracksTextView = false
        scroll.documentView = view
        configureWrapping(view, in: scroll)
        coordinator.wrapLines = wrapLines
        coordinator.attach(to: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        apply(to: scroll, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    fileprivate func apply(to scroll: NSScrollView, coordinator: Coordinator) {
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
        view.setAccessibilityLabel(AppText.outputLog)
        coordinator.onPositionChange = { [binding = $isAtLatest] in binding.wrappedValue = $0 }
        // Empty output is authoritative even if a cached native view missed a format update.
        let changed = coordinator.revision != update.revision || (text.isEmpty && storage.length > 0)
        let wrappingChanged = coordinator.wrapLines != wrapLines
        let requestedLatest = coordinator.scrollToLatestRequest != scrollToLatestRequest
        let enabledAutoScroll = autoScroll && !coordinator.autoScroll
        let scrollToEnd = requestedLatest || enabledAutoScroll || (autoScroll && coordinator.isFollowing)
        coordinator.autoScroll = autoScroll
        coordinator.scrollToLatestRequest = scrollToLatestRequest
        guard changed || wrappingChanged || requestedLatest || enabledAutoScroll else { return }

        // Text storage and layout can also move the clip view. Only user scrolling should
        // suspend following, so ignore bounds notifications throughout this transaction.
        coordinator.isUpdating = true
        defer {
            coordinator.isUpdating = false
            coordinator.reportPosition(in: scroll)
        }
        coordinator.updateDocumentFrame(in: scroll)
        let visible = scroll.contentView.bounds.origin
        let selection = view.selectedRange()
        // Clear the entire storage rather than deleting a prefix sized for the previous format.
        let incremental = changed && !text.isEmpty && coordinator.revision.map { $0 + 1 == update.revision } == true
            && update.removedPrefixUTF16 + update.removedSuffixUTF16 <= storage.length
        var anchor = scrollToEnd ? nil : ViewportAnchor(view: view, visibleY: visible.y)
        // Following can skip off-screen layout. Reading history needs exact line positions
        // so trimming older paragraphs cannot shift the visual anchor.
        view.layoutManager?.allowsNonContiguousLayout = scrollToEnd
        if changed, var saved = anchor {
            if incremental {
                let retainedLength = storage.length - update.removedPrefixUTF16 - update.removedSuffixUTF16
                saved.character = max(0, min(saved.character - update.removedPrefixUTF16, retainedLength))
                    + update.insertedPrefix.utf16.count
            } else {
                saved.relocate(from: storage.string, to: text)
            }
            anchor = saved
        }
        if wrappingChanged {
            configureWrapping(view, in: scroll)
            coordinator.wrapLines = wrapLines
        }
        var adjustedSelection = selection
        if changed {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.textColor
            ]
            storage.beginEditing()
            if incremental {
                if update.removedSuffixUTF16 > 0 {
                    storage.deleteCharacters(in: NSRange(
                        location: storage.length - update.removedSuffixUTF16,
                        length: update.removedSuffixUTF16
                    ))
                }
                if update.removedPrefixUTF16 > 0 || !update.insertedPrefix.isEmpty {
                    storage.replaceCharacters(
                        in: NSRange(location: 0, length: update.removedPrefixUTF16),
                        with: NSAttributedString(string: update.insertedPrefix, attributes: attributes)
                    )
                }
                if !update.appendedText.isEmpty {
                    storage.append(NSAttributedString(string: update.appendedText, attributes: attributes))
                }
                let inserted = update.insertedPrefix.utf16.count
                let start = max(0, selection.location - update.removedPrefixUTF16) + inserted
                let end = max(0, NSMaxRange(selection) - update.removedPrefixUTF16) + inserted
                adjustedSelection = NSRange(location: start, length: max(0, end - start))
            } else {
                // SwiftUI can coalesce updates, or recreate the view when switching panels/windows.
                storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            }
            storage.endEditing()
            coordinator.revision = update.revision
            let start = min(adjustedSelection.location, storage.length)
            let length = min(adjustedSelection.length, storage.length - start)
            view.setSelectedRange(NSRange(location: start, length: length))
        }

        // AppKit lays out the visible range on demand; forcing the entire container here
        // stalls scrolling whenever the rolling buffer removes old lines.
        if scrollToEnd {
            coordinator.isFollowing = true
            coordinator.scrollToLatest(in: scroll)
        } else {
            let y = anchor?.restoredY(in: view) ?? visible.y
            scroll.contentView.scroll(to: NSPoint(x: wrapLines ? 0 : visible.x, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if storage.length == 0 {
            coordinator.isFollowing = true
        }
    }

    private func configureWrapping(_ view: NSTextView, in scroll: NSScrollView) {
        scroll.hasHorizontalScroller = !wrapLines
        view.isHorizontallyResizable = !wrapLines
        view.textContainer?.widthTracksTextView = false
        view.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        view.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(view.frame.height, scroll.contentSize.height)))
        view.setFrameOrigin(.zero)
        let width = wrapLines
            ? max(1, scroll.contentSize.width - view.textContainerInset.width * 2)
            : CGFloat.greatestFiniteMagnitude
        view.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = wrapLines
    }

    /// Pin a visual line, including the partial line offset, rather than a document y coordinate.
    @MainActor
    private struct ViewportAnchor {
        var character: Int
        let offsetY: CGFloat

        init?(view: NSTextView, visibleY: CGFloat) {
            guard let layout = view.layoutManager, let container = view.textContainer,
                  view.textStorage?.length ?? 0 > 0 else { return nil }
            let point = NSPoint(x: 0, y: max(0, visibleY - view.textContainerOrigin.y))
            layout.ensureLayout(forBoundingRect: NSRect(origin: point, size: view.visibleRect.size), in: container)
            let glyph = layout.glyphIndex(for: point, in: container)
            guard glyph < layout.numberOfGlyphs else { return nil }
            var lineRange = NSRange()
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
            character = layout.characterIndexForGlyph(at: lineRange.location)
            offsetY = visibleY - (rect.minY + view.textContainerOrigin.y)
        }

        mutating func relocate(from oldText: String, to newText: String) {
            // A coalesced revision has no complete incremental patch. Match a small piece of
            // the visible text instead; this path scans only the existing bounded log buffer.
            let old = oldText as NSString
            let start = min(character, old.length)
            let range = old.rangeOfComposedCharacterSequences(
                for: NSRange(location: start, length: min(128, old.length - start))
            )
            guard range.length > 0 else { character = 0; return }
            let match = (newText as NSString).range(of: old.substring(with: range))
            character = match.location == NSNotFound ? 0 : match.location + start - range.location
        }

        func restoredY(in view: NSTextView) -> CGFloat? {
            guard let layout = view.layoutManager, let storage = view.textStorage,
                  storage.length > 0 else { return nil }
            let position = min(character, storage.length - 1)
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: position, length: 1))
            layout.ensureLayout(forCharacterRange: paragraph)
            let glyph = layout.glyphIndexForCharacter(at: position)
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return max(0, rect.minY + view.textContainerOrigin.y + offsetY)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var wrapLines: Bool?
        var revision: Int?
        var autoScroll = false
        var scrollToLatestRequest = 0
        var isFollowing = true
        var isUpdating = false
        var onPositionChange: ((Bool) -> Void)?
        private var lastPosition: Bool?
        private var viewportSize = NSSize.zero
        private var positionTask: Task<Void, Never>?

        func attach(to scroll: NSScrollView) {
            viewportSize = scroll.contentView.bounds.size
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(viewportChanged(_:)),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView
            )
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            positionTask?.cancel()
            onPositionChange = nil
        }

        @objc private func viewportChanged(_ notification: Notification) {
            guard !isUpdating, let clip = notification.object as? NSClipView,
                  let scroll = clip.enclosingScrollView else { return }
            let resized = viewportSize != clip.bounds.size
            viewportSize = clip.bounds.size
            if resized {
                isUpdating = true
                updateDocumentFrame(in: scroll)
                isUpdating = false
            }
            if resized, autoScroll, isFollowing {
                // Resizing a following window is not a request to read history.
                isUpdating = true
                scrollToLatest(in: scroll)
                isUpdating = false
            } else {
                isFollowing = isAtBottom(in: scroll)
                if !isFollowing, let view = scroll.documentView as? NSTextView {
                    // Resolve exact positions before the user starts reading a historical line.
                    view.layoutManager?.allowsNonContiguousLayout = false
                }
            }
            reportPosition(in: scroll)
        }

        func updateDocumentFrame(in scroll: NSScrollView) {
            guard let view = scroll.documentView as? NSTextView else { return }
            let height = scroll.contentSize.height
            if view.minSize.height != height {
                view.minSize = NSSize(width: 0, height: height)
            }
            if view.frame.height < height {
                view.setFrameSize(NSSize(width: view.frame.width, height: height))
            }
            // AppKit may center a short document before its first layout pass.
            // A terminal always starts at the top, with bounds matching scroll coordinates.
            if view.frame.origin != .zero { view.setFrameOrigin(.zero) }
        }

        func scrollToLatest(in scroll: NSScrollView) {
            guard let view = scroll.documentView as? NSTextView else { return }
            let x = scroll.contentView.bounds.minX
            view.scrollRangeToVisible(NSRange(location: view.textStorage?.length ?? 0, length: 0))
            // The insertion point may be visible before the bottom text inset is visible.
            // Align the actual document bottom and retain horizontal position in HEX/no-wrap.
            scroll.contentView.scroll(to: NSPoint(
                x: x,
                y: max(0, view.bounds.maxY - scroll.contentView.bounds.height)
            ))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func reportPosition(in scroll: NSScrollView) {
            viewportSize = scroll.contentView.bounds.size
            let latest = isAtBottom(in: scroll)
            guard latest != lastPosition else { return }
            lastPosition = latest
            positionTask?.cancel()
            // Publishing after the AppKit update avoids changing SwiftUI state during rendering.
            positionTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled else { return }
                self?.onPositionChange?(latest)
            }
        }

        private func isAtBottom(in scroll: NSScrollView) -> Bool {
            guard let document = scroll.documentView else { return true }
            return document.bounds.maxY - scroll.contentView.bounds.maxY <= 2
        }
    }
}
