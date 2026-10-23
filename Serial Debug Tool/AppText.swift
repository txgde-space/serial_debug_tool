import Foundation

/// All app-owned user-facing text. Keep protocol identifiers and persisted enum values unchanged.
enum AppText {
    static let appName = "Serial Debug Tool"
    static let hexPlaceholder = "AA 01 02 FF"
    static let devicePathPlaceholder = "/dev/cu.usbserial…"

    static let simplifiedChineseName = "简体中文"
    static let englishName = "English"

    static var bundle: Bundle { AppLocalization.shared.bundle }
    static var locale: Locale { AppLocalization.shared.locale }

    static var language: String {
        String(localized: "settings.language", defaultValue: "Language", bundle: bundle, locale: locale)
    }

    static var systemLanguage: String {
        String(localized: "settings.language.system", defaultValue: "Follow System", bundle: bundle, locale: locale)
    }

    static var languageHelp: String {
        String(localized: "settings.language.help", defaultValue: "Changes apply immediately to all windows and are saved automatically.", bundle: bundle, locale: locale)
    }

    static var displayOptions: String {
        String(localized: "receive.displayOptions", defaultValue: "Display Options", bundle: bundle, locale: locale)
    }

    static var exportLog: String {
        String(localized: "toolbar.export", defaultValue: "Export Log", bundle: bundle, locale: locale)
    }

    static var exportLogHelp: String {
        String(localized: "toolbar.export.help", defaultValue: "Export raw HEX logs from the current buffer", bundle: bundle, locale: locale)
    }

    static var clear: String {
        String(localized: "action.clear", defaultValue: "Clear", bundle: bundle, locale: locale)
    }

    static var clearLogHelp: String {
        String(localized: "toolbar.clear.help", defaultValue: "Clear the display buffer (⌘K)", bundle: bundle, locale: locale)
    }

    static var settings: String {
        String(localized: "action.settings", defaultValue: "Settings", bundle: bundle, locale: locale)
    }

    static var settingsHelp: String {
        String(localized: "toolbar.settings.help", defaultValue: "Settings (⌘,)", bundle: bundle, locale: locale)
    }

    static var operationIncomplete: String {
        String(localized: "error.title", defaultValue: "Operation Incomplete", bundle: bundle, locale: locale)
    }

    static var ok: String {
        String(localized: "action.ok", defaultValue: "OK", bundle: bundle, locale: locale)
    }

    static var confirm: String {
        String(localized: "action.confirm", defaultValue: "OK", bundle: bundle, locale: locale)
    }

    static var cancel: String {
        String(localized: "action.cancel", defaultValue: "Cancel", bundle: bundle, locale: locale)
    }

    static var save: String {
        String(localized: "action.save", defaultValue: "Save", bundle: bundle, locale: locale)
    }

    static var edit: String {
        String(localized: "action.edit", defaultValue: "Edit", bundle: bundle, locale: locale)
    }

    static var delete: String {
        String(localized: "action.delete", defaultValue: "Delete", bundle: bundle, locale: locale)
    }

    static var sendOnce: String {
        String(localized: "preset.sendOnce", defaultValue: "Send Once", bundle: bundle, locale: locale)
    }

    static var send: String {
        String(localized: "action.send", defaultValue: "Send", bundle: bundle, locale: locale)
    }

    static var customBaudRate: String {
        String(localized: "serial.customBaud", defaultValue: "Custom Baud Rate", bundle: bundle, locale: locale)
    }

    static var baudExample: String {
        String(localized: "serial.baudExample", defaultValue: "e.g. 250000", bundle: bundle, locale: locale)
    }

    static var invalidIntegerBaud: String {
        String(localized: "error.integerBaud", defaultValue: "Enter an integer baud rate from 1 to 4,000,000.", bundle: bundle, locale: locale)
    }

    static var baudSupportHelp: String {
        String(localized: "serial.baudSupport", defaultValue: "Supported baud rates depend on the serial device and driver.", bundle: bundle, locale: locale)
    }

    static var savePreset: String {
        String(localized: "preset.saveTitle", defaultValue: "Save Command Preset", bundle: bundle, locale: locale)
    }

    static var presetName: String {
        String(localized: "preset.name", defaultValue: "Preset Name", bundle: bundle, locale: locale)
    }

    static var savePresetHelp: String {
        String(localized: "preset.saveHelp", defaultValue: "Save the current content, encoding, HEX mode, and line ending.", bundle: bundle, locale: locale)
    }

    static var connectionSettings: String {
        String(localized: "serial.settings", defaultValue: "Connection Settings", bundle: bundle, locale: locale)
    }

    static var device: String {
        String(localized: "serial.device", defaultValue: "Device", bundle: bundle, locale: locale)
    }

    static var rescanPorts: String {
        String(localized: "serial.rescan", defaultValue: "Rescan Serial Ports", bundle: bundle, locale: locale)
    }

    static var devicePath: String {
        String(localized: "serial.path", defaultValue: "Serial Device Path", bundle: bundle, locale: locale)
    }

    static var devicePathHelp: String {
        String(localized: "serial.path.help", defaultValue: "You can also enter a device path directly", bundle: bundle, locale: locale)
    }

    static var noDevices: String {
        String(localized: "serial.noDevices", defaultValue: "No devices found. Connect a USB serial adapter and rescan.", bundle: bundle, locale: locale)
    }

    static var baudRate: String {
        String(localized: "serial.baud", defaultValue: "Baud Rate", bundle: bundle, locale: locale)
    }

    static var custom: String {
        String(localized: "serial.custom", defaultValue: "Custom…", bundle: bundle, locale: locale)
    }

    static var dataBits: String {
        String(localized: "serial.dataBits", defaultValue: "Data Bits", bundle: bundle, locale: locale)
    }

    static var stopBits: String {
        String(localized: "serial.stopBits", defaultValue: "Stop Bits", bundle: bundle, locale: locale)
    }

    static var parity: String {
        String(localized: "serial.parity", defaultValue: "Parity", bundle: bundle, locale: locale)
    }

    static var flowControl: String {
        String(localized: "serial.flowControl", defaultValue: "Flow Control", bundle: bundle, locale: locale)
    }

    static var none: String {
        String(localized: "option.none", defaultValue: "None", bundle: bundle, locale: locale)
    }

    static var evenParity: String {
        String(localized: "serial.parity.even", defaultValue: "Even", bundle: bundle, locale: locale)
    }

    static var oddParity: String {
        String(localized: "serial.parity.odd", defaultValue: "Odd", bundle: bundle, locale: locale)
    }

    static var disconnect: String {
        String(localized: "serial.disconnect", defaultValue: "Disconnect", bundle: bundle, locale: locale)
    }

    static var connecting: String {
        String(localized: "serial.connecting", defaultValue: "Connecting", bundle: bundle, locale: locale)
    }

    static var connect: String {
        String(localized: "serial.connect", defaultValue: "Connect", bundle: bundle, locale: locale)
    }

    static var filterBuffer: String {
        String(localized: "log.filter", defaultValue: "Filter Current Buffer", bundle: bundle, locale: locale)
    }

    static var clearFilter: String {
        String(localized: "log.clearFilter", defaultValue: "Clear Filter", bundle: bundle, locale: locale)
    }

    static var autoWrap: String {
        String(localized: "log.autoWrap", defaultValue: "Wrap Lines", bundle: bundle, locale: locale)
    }

    static var autoWrapHelp: String {
        String(localized: "log.autoWrap.help", defaultValue: "Wrap lines to the window width without changing received data", bundle: bundle, locale: locale)
    }

    static var autoScroll: String {
        String(localized: "log.autoScroll", defaultValue: "Auto-scroll", bundle: bundle, locale: locale)
    }

    static var resumeDisplay: String {
        String(localized: "log.resume", defaultValue: "Resume", bundle: bundle, locale: locale)
    }

    static var pauseDisplay: String {
        String(localized: "log.pause", defaultValue: "Pause", bundle: bundle, locale: locale)
    }

    static var pauseHelp: String {
        String(localized: "log.pause.help", defaultValue: "Data reception and byte counting continue while the display is paused", bundle: bundle, locale: locale)
    }

    static var receiveMonitor: String {
        String(localized: "log.title", defaultValue: "Receive Monitor", bundle: bundle, locale: locale)
    }

    static var receiveDisplay: String {
        String(localized: "log.mode", defaultValue: "Receive Display", bundle: bundle, locale: locale)
    }

    static var textMode: String {
        String(localized: "log.text", defaultValue: "Text", bundle: bundle, locale: locale)
    }

    static var timestamps: String {
        String(localized: "log.timestamps", defaultValue: "Timestamps", bundle: bundle, locale: locale)
    }

    static var showRX: String {
        String(localized: "log.showRX", defaultValue: "Show RX", bundle: bundle, locale: locale)
    }

    static var showRXHelp: String {
        String(localized: "log.showRX.help", defaultValue: "Show or hide received logs; reception and counting continue", bundle: bundle, locale: locale)
    }

    static var showTX: String {
        String(localized: "log.showTX", defaultValue: "Show TX", bundle: bundle, locale: locale)
    }

    static var showTXHelp: String {
        String(localized: "log.showTX.help", defaultValue: "Show or hide sent logs", bundle: bundle, locale: locale)
    }

    static var showSYS: String {
        String(localized: "log.showSYS", defaultValue: "Show SYS", bundle: bundle, locale: locale)
    }

    static var showSYSHelp: String {
        String(localized: "log.showSYS.help", defaultValue: "Show or hide system messages", bundle: bundle, locale: locale)
    }

    static var sendPlaceholder: String {
        String(localized: "send.placeholder", defaultValue: "Enter content to send…", bundle: bundle, locale: locale)
    }

    static var hexEndingHelp: String {
        String(localized: "send.hexEnding.help", defaultValue: "The line ending is appended as extra bytes after the HEX data.", bundle: bundle, locale: locale)
    }

    static var repeatHelp: String {
        String(localized: "send.repeat.help", defaultValue: "⌘↩ Send · Repeated sending uses the content and settings captured at start.", bundle: bundle, locale: locale)
    }

    static var hexInput: String {
        String(localized: "send.hex", defaultValue: "HEX Input", bundle: bundle, locale: locale)
    }

    static var encoding: String {
        String(localized: "send.encoding", defaultValue: "Encoding", bundle: bundle, locale: locale)
    }

    static var lineEnding: String {
        String(localized: "send.lineEnding", defaultValue: "Line Ending", bundle: bundle, locale: locale)
    }

    /// Short label for the compact inline preset editor.
    static var compactLineEnding: String {
        String(localized: "send.lineEnding.compact", defaultValue: "Ending", bundle: bundle, locale: locale)
    }

    static var saveAsPreset: String {
        String(localized: "preset.saveAs", defaultValue: "Save as Preset", bundle: bundle, locale: locale)
    }

    static var intervalAccessibility: String {
        String(localized: "send.interval.accessibility", defaultValue: "Repeat interval in milliseconds", bundle: bundle, locale: locale)
    }

    static var intervalHelp: String {
        String(localized: "send.interval.help", defaultValue: "Repeat interval (milliseconds)", bundle: bundle, locale: locale)
    }

    static var milliseconds: String {
        String(localized: "unit.milliseconds", defaultValue: "ms", bundle: bundle, locale: locale)
    }

    static var stopRepeating: String {
        String(localized: "send.repeat.stop", defaultValue: "Stop Repeat", bundle: bundle, locale: locale)
    }

    static var repeatSend: String {
        String(localized: "send.repeat.start", defaultValue: "Repeat", bundle: bundle, locale: locale)
    }

    static var commandPanel: String {
        String(localized: "panel.command", defaultValue: "Send Command", bundle: bundle, locale: locale)
    }

    static var presetPanel: String {
        String(localized: "panel.presets", defaultValue: "Presets", bundle: bundle, locale: locale)
    }

    static var composeCommand: String {
        String(localized: "preset.compose", defaultValue: "Compose Command", bundle: bundle, locale: locale)
    }

    static var noPresets: String {
        String(localized: "preset.empty", defaultValue: "No Command Presets", bundle: bundle, locale: locale)
    }

    static var noPresetsHelp: String {
        String(localized: "preset.empty.help", defaultValue: "Compose a command in the Send Command panel, then choose “Save as Preset”.", bundle: bundle, locale: locale)
    }

    static var stopRepeatToSwitch: String {
        String(localized: "panel.switch.disabled", defaultValue: "Stop repeated sending to switch panels", bundle: bundle, locale: locale)
    }

    static var switchPanelHelp: String {
        String(localized: "panel.switch.help", defaultValue: "Switch between the command and preset panels", bundle: bundle, locale: locale)
    }

    static var repeating: String {
        String(localized: "status.repeating", defaultValue: "Repeating", bundle: bundle, locale: locale)
    }

    static var sendPanel: String {
        String(localized: "panel.title", defaultValue: "Send Panel", bundle: bundle, locale: locale)
    }

    static var systemTheme: String {
        String(localized: "theme.system", defaultValue: "System", bundle: bundle, locale: locale)
    }

    static var lightTheme: String {
        String(localized: "theme.light", defaultValue: "Light", bundle: bundle, locale: locale)
    }

    static var darkTheme: String {
        String(localized: "theme.dark", defaultValue: "Dark", bundle: bundle, locale: locale)
    }

    static var appearance: String {
        String(localized: "settings.appearance", defaultValue: "Appearance", bundle: bundle, locale: locale)
    }

    static var themeHelp: String {
        String(localized: "settings.appearance.help", defaultValue: "The theme applies to all serial windows and is saved automatically.", bundle: bundle, locale: locale)
    }

    static var selected: String {
        String(localized: "accessibility.selected", defaultValue: "Selected", bundle: bundle, locale: locale)
    }

    static var notSelected: String {
        String(localized: "accessibility.notSelected", defaultValue: "Not selected", bundle: bundle, locale: locale)
    }

    static var invalidHex: String {
        String(localized: "error.invalidHex", defaultValue: "Invalid HEX format. Enter pairs of hexadecimal characters, such as AA 01 0D 0A.", bundle: bundle, locale: locale)
    }

    static var emptyPayload: String {
        String(localized: "error.emptyPayload", defaultValue: "Enter data to send.", bundle: bundle, locale: locale)
    }

    static var payloadTooLarge: String {
        String(localized: "error.payloadTooLarge", defaultValue: "Each transmission supports up to 64 KiB. Split the data into smaller parts.", bundle: bundle, locale: locale)
    }

    static var disconnected: String {
        String(localized: "status.disconnected", defaultValue: "Disconnected", bundle: bundle, locale: locale)
    }

    static var invalidBaud: String {
        String(localized: "error.invalidBaud", defaultValue: "Enter a baud rate from 1 to 4,000,000. Device support may vary.", bundle: bundle, locale: locale)
    }

    static var connectingStatus: String {
        String(localized: "status.connecting", defaultValue: "Connecting…", bundle: bundle, locale: locale)
    }

    static var connectionEnded: String {
        String(localized: "status.connectionEnded", defaultValue: "Connection Closed", bundle: bundle, locale: locale)
    }

    static var receiveStopped: String {
        String(localized: "log.receiveStopped", defaultValue: "Serial reception stopped.", bundle: bundle, locale: locale)
    }

    static var connectionFailed: String {
        String(localized: "status.connectionFailed", defaultValue: "Connection Failed", bundle: bundle, locale: locale)
    }

    static var portDisconnected: String {
        String(localized: "log.disconnected", defaultValue: "Serial port disconnected.", bundle: bundle, locale: locale)
    }

    static var invalidInterval: String {
        String(localized: "error.invalidInterval", defaultValue: "Connect a serial port and enter an interval from 10 to 3,600,000 milliseconds.", bundle: bundle, locale: locale)
    }

    static var incompletePreset: String {
        String(localized: "error.incompletePreset", defaultValue: "Enter a preset name and content to send.", bundle: bundle, locale: locale)
    }

    static var disconnectFirst: String {
        String(localized: "error.disconnectFirst", defaultValue: "Disconnect the current serial port first.", bundle: bundle, locale: locale)
    }

    static var invalidSerialParameters: String {
        String(localized: "error.serialParameters", defaultValue: "Invalid serial settings. Check the device path and baud rate.", bundle: bundle, locale: locale)
    }

    static var portAlreadyOpen: String {
        String(localized: "error.portAlreadyOpen", defaultValue: "This port is open in another window. Disconnect it there first.", bundle: bundle, locale: locale)
    }

    static var readSettingsFailed: String {
        String(localized: "error.readSettings", defaultValue: "Unable to read serial settings", bundle: bundle, locale: locale)
    }

    static var exclusiveAccessFailed: String {
        String(localized: "error.exclusiveAccess", defaultValue: "Unable to obtain exclusive access; another app may be using the port", bundle: bundle, locale: locale)
    }

    static var unsupportedSettings: String {
        String(localized: "error.unsupportedSettings", defaultValue: "The device does not support the selected serial settings", bundle: bundle, locale: locale)
    }

    static var portNotConnected: String {
        String(localized: "error.notConnected", defaultValue: "The serial port is not connected.", bundle: bundle, locale: locale)
    }

    static var sendInProgress: String {
        String(localized: "error.sendInProgress", defaultValue: "The previous transmission is still in progress. Try again shortly.", bundle: bundle, locale: locale)
    }

    static var sendInterrupted: String {
        String(localized: "error.sendInterrupted", defaultValue: "Transmission interrupted.", bundle: bundle, locale: locale)
    }

    static var writeFailed: String {
        String(localized: "error.writeFailed", defaultValue: "Serial write failed", bundle: bundle, locale: locale)
    }

    static var sendTimeout: String {
        String(localized: "error.sendTimeout", defaultValue: "Transmission timed out; some data may have been written. Check flow control and the device connection.", bundle: bundle, locale: locale)
    }

    static var sendCancelled: String {
        String(localized: "error.sendCancelled", defaultValue: "Transmission cancelled.", bundle: bundle, locale: locale)
    }

    static var deviceDisconnected: String {
        String(localized: "error.deviceDisconnected", defaultValue: "The device disconnected.", bundle: bundle, locale: locale)
    }

    static var readFailed: String {
        String(localized: "error.readFailed", defaultValue: "Read failed; the device may have been removed", bundle: bundle, locale: locale)
    }

    static var receiveQueueFull: String {
        String(localized: "error.receiveQueueFull", defaultValue: "The receive queue is full. The connection was stopped to avoid silent data loss.", bundle: bundle, locale: locale)
    }

    static var editingPreset: String {
        String(localized: "preset.editing", defaultValue: "Editing Preset", bundle: bundle, locale: locale)
    }

    static var saveShortcut: String {
        String(localized: "preset.saveShortcut", defaultValue: "⌘↩ Save", bundle: bundle, locale: locale)
    }

    static var presetPlaceholder: String {
        String(localized: "preset.placeholder", defaultValue: "Enter preset command content…", bundle: bundle, locale: locale)
    }

    static var savePresetShortcut: String {
        String(localized: "preset.saveShortcut.help", defaultValue: "⌘↩ Save Preset", bundle: bundle, locale: locale)
    }

    static var newSerialWindow: String {
        String(localized: "menu.newWindow", defaultValue: "New Serial Window", bundle: bundle, locale: locale)
    }

    static var serialDevice: String {
        String(localized: "accessibility.serialDevice", defaultValue: "Serial Device", bundle: bundle, locale: locale)
    }

    static var manualPath: String {
        String(localized: "serial.manualPath", defaultValue: "Enter Path Manually", bundle: bundle, locale: locale)
    }

    static var sendContent: String {
        String(localized: "accessibility.sendContent", defaultValue: "Content to Send", bundle: bundle, locale: locale)
    }

    static var displayPaused: String {
        String(localized: "log.paused", defaultValue: "Display paused · Still receiving", bundle: bundle, locale: locale)
    }

    static var resetCounters: String {
        String(localized: "counter.reset", defaultValue: "Reset Counters", bundle: bundle, locale: locale)
    }

    static var received: String {
        String(localized: "counter.received", defaultValue: "Received", bundle: bundle, locale: locale)
    }

    static var sent: String {
        String(localized: "counter.sent", defaultValue: "Sent", bundle: bundle, locale: locale)
    }

    static var outputLog: String {
        String(localized: "accessibility.outputLog", defaultValue: "Serial Output Log", bundle: bundle, locale: locale)
    }

    static func customBaudLabel(_ rate: String) -> String {
        String(localized: "serial.customLabel", defaultValue: "\(rate) (Custom)…", bundle: bundle, locale: locale)
    }

    static func unencodable(_ encoding: String) -> String {
        String(localized: "error.unencodable", defaultValue: "The input contains characters that cannot be encoded as \(encoding).", bundle: bundle, locale: locale)
    }

    static func undecodable(_ hex: String) -> String {
        String(localized: "log.undecodable", defaultValue: "⟦Unable to decode: \(hex)⟧", bundle: bundle, locale: locale)
    }

    static func connectedMessage(_ path: String, _ configuration: String, _ flowControl: String) -> String {
        String(localized: "log.connected", defaultValue: "Connected to \(path) · \(configuration) · Flow control: \(flowControl)", bundle: bundle, locale: locale)
    }

    static func exportHeader(_ path: String, _ configuration: String, _ date: String) -> String {
        String(localized: "log.exportHeader", defaultValue: "Serial Debug Tool · \(path) · \(configuration)\nExported: \(date)\n\n", bundle: bundle, locale: locale)
    }

    static func openFailed(_ path: String) -> String {
        String(localized: "error.openFailed", defaultValue: "Unable to open \(path)", bundle: bundle, locale: locale)
    }

    static func unsupportedBaud(_ rate: Int) -> String {
        String(localized: "error.unsupportedBaud", defaultValue: "The device does not support custom baud rate \(rate)", bundle: bundle, locale: locale)
    }

    static func systemError(_ operation: String, _ message: String, _ code: Int32) -> String {
        String(localized: "error.system", defaultValue: "\(operation): \(message) (\(code))", bundle: bundle, locale: locale)
    }

    static func discardedRecords(_ count: Int) -> String {
        String(localized: "log.discarded", defaultValue: "… \(count) earlier records were removed from the display buffer; exports include the current buffer.", bundle: bundle, locale: locale)
    }

    static func presetCount(_ count: Int) -> String {
        String(localized: "preset.count", defaultValue: "\(count) presets", bundle: bundle, locale: locale)
    }

    static func byteCount(_ count: Int) -> String {
        String(localized: "counter.bytes", defaultValue: "\(count) bytes", bundle: bundle, locale: locale)
    }

    static func repeatPreset(_ name: String) -> String {
        String(localized: "preset.repeat", defaultValue: "Repeat preset “\(name)” using the panel interval", bundle: bundle, locale: locale)
    }

    static func stopPresetRepeat(_ name: String) -> String {
        String(localized: "preset.repeat.stop", defaultValue: "Stop repeating preset “\(name)”", bundle: bundle, locale: locale)
    }

    static var deletePresetTitle: String {
        String(localized: "preset.delete.title", defaultValue: "Delete Preset?", bundle: bundle, locale: locale)
    }

    static func deletePresetConfirmation(_ name: String) -> String {
        String(localized: "preset.delete.confirmation", defaultValue: "Delete the preset “\(name)”? This cannot be undone.", bundle: bundle, locale: locale)
    }

    static func deletePreset(_ name: String) -> String {
        String(localized: "preset.delete", defaultValue: "Delete preset “\(name)”", bundle: bundle, locale: locale)
    }
}
