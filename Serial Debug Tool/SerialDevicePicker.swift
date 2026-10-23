import AppKit
import SwiftUI

/// Update the native menu and selection together as devices appear or disappear.
/// A manual path never becomes a SwiftUI Picker value without a matching tag.
struct SerialDevicePicker: NSViewRepresentable {
    var ports: [SerialPort]
    @Binding var path: String

    func makeCoordinator() -> Coordinator {
        Coordinator(path: $path)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        button.controlSize = .regular
        button.bezelStyle = .rounded
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectDevice(_:))
        button.setAccessibilityLabel(AppText.serialDevice)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.cell?.lineBreakMode = .byTruncatingMiddle
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.path = $path
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityLabel(AppText.serialDevice)
        let paths = ports.map(\.path)
        if button.numberOfItems == 0 || context.coordinator.paths != paths || button.lastItem?.title != AppText.manualPath {
            let menu = NSMenu()
            for port in ports {
                let item = NSMenuItem(title: port.name, action: nil, keyEquivalent: "")
                item.representedObject = port.path
                menu.addItem(item)
            }
            if !ports.isEmpty { menu.addItem(.separator()) }
            let manual = NSMenuItem(title: AppText.manualPath, action: nil, keyEquivalent: "")
            manual.representedObject = ""
            menu.addItem(manual)
            button.menu = menu
            context.coordinator.paths = paths
        }
        let selected = button.itemArray.first { ($0.representedObject as? String) == path }
            ?? button.itemArray.last
        button.select(selected)
    }

    @MainActor
    final class Coordinator: NSObject {
        var path: Binding<String>
        var paths: [String] = []

        init(path: Binding<String>) {
            self.path = path
        }

        @objc func selectDevice(_ sender: NSPopUpButton) {
            guard let value = sender.selectedItem?.representedObject as? String else { return }
            path.wrappedValue = value
        }
    }
}
