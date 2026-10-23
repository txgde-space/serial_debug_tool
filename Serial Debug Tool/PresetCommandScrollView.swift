import SwiftUI
import AppKit
import QuartzCore

struct PresetCommandScrollView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                content.environment(\.presetViewportHeight, viewport.size.height)
            }
        }
    }
}

extension View {
    func presetScrollAnchor(active: Bool) -> some View {
        modifier(PresetScrollRow(active: active))
    }
}

private struct PresetScrollRow: ViewModifier {
    let active: Bool
    @Environment(\.presetViewportHeight) private var viewportHeight

    func body(content: Content) -> some View {
        content
            // Fill the viewport with the edited row instead of adding a blank screen below it.
            .frame(minHeight: active ? viewportHeight : nil, alignment: .top)
            .background(PresetScrollAnchor(active: active))
    }
}

private struct PresetViewportHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private extension EnvironmentValues {
    var presetViewportHeight: CGFloat {
        get { self[PresetViewportHeightKey.self] }
        set { self[PresetViewportHeightKey.self] = newValue }
    }
}

/// Use the enclosing native clip view after layout, because SwiftUI's scroll proxy
/// can ignore an anchor request while an inline editor is expanding.
private struct PresetScrollAnchor: NSViewRepresentable {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> PresetScrollMarker {
        PresetScrollMarker()
    }

    func updateNSView(_ view: PresetScrollMarker, context: Context) {
        let beginEditing = active && !view.active
        view.active = active
        if beginEditing { view.requestAlignment(animated: !reduceMotion) }
    }

    static func dismantleNSView(_ view: PresetScrollMarker, coordinator: ()) {
        view.active = false
    }
}

private final class PresetScrollMarker: NSView {
    var active = false {
        didSet {
            if !active {
                alignmentPending = false
                alignmentTask?.cancel()
                alignmentTask = nil
            }
        }
    }
    private var alignmentPending = false
    private var animateAlignment = false
    private var alignmentTask: Task<Void, Never>?

    func requestAlignment(animated: Bool) {
        alignmentPending = true
        animateAlignment = animated
        scheduleAlignment()
    }

    override func layout() {
        super.layout()
        alignToTopIfReady()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed && alignmentPending { scheduleAlignment() }
    }

    private func scheduleAlignment() {
        guard active, alignmentPending, alignmentTask == nil else { return }
        alignmentTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            alignmentTask = nil
            alignToTopIfReady()
        }
    }

    private func alignToTopIfReady() {
        guard active, alignmentPending,
              let scroll = enclosingScrollView,
              let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let rect = convert(bounds, to: document)
        let top = document.isFlipped ? rect.minY : rect.maxY - clip.bounds.height
        let maximum = max(0, document.bounds.height - clip.bounds.height)
        // Keep the request pending until AppKit's actual scroll range has caught up.
        guard maximum + 0.5 >= max(0, top) else { return }
        alignmentPending = false
        alignmentTask?.cancel()
        alignmentTask = nil
        let origin = NSPoint(x: clip.bounds.minX, y: min(maximum, max(0, top)))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animateAlignment ? 0.26 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(origin)
        } completionHandler: {
            scroll.reflectScrolledClipView(clip)
        }
    }
}
