import SwiftUI
import AppKit

/// Observe high-frequency log and counter changes inside their own views.
@MainActor
struct TerminalOutputView: View {
    let session: SerialSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TerminalTextView(text: session.logText, update: session.logUpdate, autoScroll: session.autoScroll, wrapLines: session.autoWrap)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if session.paused {
                Label(AppText.displayPaused, systemImage: "pause.circle.fill")
                    .font(.caption)
                    .padding(9)
                    .background(.regularMaterial, in: Capsule())
                    .padding(14)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: session.paused)
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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let view = NSTextView(frame: scroll.bounds)
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
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = view.maxSize
        view.textContainer?.widthTracksTextView = false
        scroll.documentView = view
        configureWrapping(view, in: scroll)
        context.coordinator.wrapLines = wrapLines
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
        view.setAccessibilityLabel(AppText.outputLog)
        let coordinator = context.coordinator
        let changed = coordinator.revision != update.revision
        let wrappingChanged = coordinator.wrapLines != wrapLines
        let scrollToEnd = autoScroll && (changed || wrappingChanged || !coordinator.autoScroll)
        coordinator.autoScroll = autoScroll
        guard changed || wrappingChanged || scrollToEnd else { return }

        let visible = scroll.contentView.bounds.origin
        let selection = view.selectedRange()
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
            if let revision = coordinator.revision, revision + 1 == update.revision,
               update.removedPrefixUTF16 + update.removedSuffixUTF16 <= storage.length {
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

        if scrollToEnd {
            view.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        } else if changed || wrappingChanged {
            scroll.contentView.scroll(to: NSPoint(x: wrapLines ? 0 : visible.x, y: visible.y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func configureWrapping(_ view: NSTextView, in scroll: NSScrollView) {
        scroll.hasHorizontalScroller = !wrapLines
        view.isHorizontallyResizable = !wrapLines
        view.textContainer?.widthTracksTextView = false
        view.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(view.frame.height, scroll.contentSize.height)))
        let width = wrapLines
            ? max(1, scroll.contentSize.width - view.textContainerInset.width * 2)
            : CGFloat.greatestFiniteMagnitude
        view.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = wrapLines
    }

    final class Coordinator {
        var wrapLines: Bool?
        var revision: Int?
        var autoScroll = false
    }
}
