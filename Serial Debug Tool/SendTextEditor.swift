import AppKit
import SwiftUI

/// The placeholder and typed text use the same AppKit layout metrics.
struct SendTextEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSend: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let initialFrame = NSRect(x: 0, y: 0, width: 300, height: 85)
        let scrollView = NSScrollView(frame: initialFrame)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let editor = PlaceholderTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.drawsBackground = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textColor = .textColor
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = NSSize(width: max(1, scrollView.contentSize.width - 20), height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.allowsUndo = true
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel(AppText.sendContent)
        scrollView.documentView = editor
        updateEditor(editor)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let editor = scrollView.documentView as? PlaceholderTextView else { return }
        updateEditor(editor)
    }

    private func updateEditor(_ editor: PlaceholderTextView) {
        editor.setAccessibilityLabel(AppText.sendContent)
        if !editor.hasMarkedText(), editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            let count = (text as NSString).length
            editor.setSelectedRange(NSRange(location: min(selection.location, count), length: 0))
        }
        editor.placeholder = placeholder
        editor.onSend = onSend
        editor.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
            text.wrappedValue = editor.string
            editor.needsDisplay = true
        }
    }
}

@MainActor
private final class PlaceholderTextView: NSTextView {
    var placeholder = ""
    var onSend: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let font else { return }

        let storage = NSTextStorage(string: placeholder, attributes: [
            .font: font,
            .foregroundColor: NSColor.placeholderTextColor,
            .paragraphStyle: defaultParagraphStyle ?? NSParagraphStyle.default
        ])
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: textContainer?.containerSize ?? bounds.size)
        container.lineFragmentPadding = textContainer?.lineFragmentPadding ?? 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let glyphs = layout.glyphRange(for: container)
        layout.drawGlyphs(forGlyphRange: glyphs, at: textContainerOrigin)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            onSend?()
        } else {
            super.keyDown(with: event)
        }
    }
}
