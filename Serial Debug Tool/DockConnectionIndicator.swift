import AppKit

/// Combines connection state across all serial windows for the single app Dock icon.
@MainActor
final class DockConnectionIndicator {
    static let shared = DockConnectionIndicator()

    private var connectedWindows: Set<UUID> = []

    var isConnected: Bool {
        !connectedWindows.isEmpty
    }

    func setConnected(_ connected: Bool, for windowID: UUID) {
        let wasConnected = isConnected
        if connected {
            connectedWindows.insert(windowID)
        } else {
            connectedWindows.remove(windowID)
        }
        guard isConnected != wasConnected else { return }

        let application = NSApplication.shared
        let tile = application.dockTile
        if isConnected {
            tile.contentView = ConnectedDockIconView(icon: application.applicationIconImage, size: tile.size)
        } else {
            // Restore the system-rendered icon as soon as the last connection closes.
            tile.contentView = nil
        }
        tile.display()
    }
}

@MainActor
private final class ConnectedDockIconView: NSView {
    private let icon: NSImage?

    init(icon: NSImage?, size: NSSize) {
        self.icon = icon
        super.init(frame: NSRect(origin: .zero, size: size))
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        icon?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)

        let length = min(bounds.width, bounds.height)
        let diameter = length * 0.18
        let inset = length * 0.08
        let dot = NSBezierPath(ovalIn: NSRect(
            x: bounds.maxX - inset - diameter,
            y: bounds.minY + inset,
            width: diameter,
            height: diameter
        ))
        NSColor.systemGreen.setFill()
        dot.fill()
        // A light outline separates the dot from the app icon and either Dock appearance.
        NSColor.white.setStroke()
        dot.lineWidth = length * 0.025
        dot.stroke()
    }
}
