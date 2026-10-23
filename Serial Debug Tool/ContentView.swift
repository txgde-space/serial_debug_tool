import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var session = SerialSession()
    @State private var dockWindowID = UUID()
    @State private var exporting = false
    @State private var exportDocument = TerminalDocument(text: "")
    @State private var savingPreset = false
    @State private var presetName = ""
    @State private var editingBaudRate = false
    @State private var customBaudRate = ""
    @State private var sendMode: SendMode = .command
    @State private var editingPresetID: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    private enum SendMode: CaseIterable {
        case command
        case presets

        var title: String {
            switch self {
            case .command: AppText.commandPanel
            case .presets: AppText.presetPanel
            }
        }
    }

    private let baudRates = [300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600, 1_000_000, 1_500_000, 2_000_000]

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 232, max: 280)
        } detail: {
            VStack(spacing: 0) {
                receiveControls
                terminal
                Divider()
                ZStack(alignment: .topLeading) {
                    switch sendMode {
                    case .command:
                        sendPanel
                            .transition(sendPanelTransition)
                            .zIndex(1)
                    case .presets:
                        presetsPanel
                            .transition(sendPanelTransition)
                            .zIndex(2)
                    }
                }
                .frame(height: editingPresetID == nil ? 224 : 272)
                .clipped()
                .animation(sendPanelAnimation, value: sendMode)
                .animation(interfaceAnimation, value: editingPresetID)
                Divider()
                footer
            }
            .frame(minWidth: 450)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(AppText.appName)
        .frame(minWidth: 700, minHeight: 640)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    exportDocument = TerminalDocument(text: session.exportText())
                    exporting = true
                } label: {
                    Label(AppText.exportLog, systemImage: "square.and.arrow.up")
                }
                .help(AppText.exportLogHelp)
                Button {
                    session.clearLog()
                } label: {
                    Label(AppText.clear, systemImage: "trash")
                }
                .keyboardShortcut("k", modifiers: .command)
                .help(AppText.clearLogHelp)
                SettingsLink {
                    Label(AppText.settings, systemImage: "gearshape")
                }
                .help(AppText.settingsHelp)
            }
        }
        .task {
            // Apply the launch default after the split view restores its saved state.
            await Task.yield()
            columnVisibility = .all
            await session.monitor()
        }
        .onChange(of: session.presets.map(\.id)) { _, ids in
            if let repeatingID = session.repeatingPresetID, !ids.contains(repeatingID) {
                session.stopRepeating()
            }
            if let editingPresetID, !ids.contains(editingPresetID) {
                self.editingPresetID = nil
            }
        }
        .onChange(of: AppLocalization.shared.language) { _, _ in
            session.refreshLocalization()
        }
        .onChange(of: session.isConnected, initial: true) { _, connected in
            DockConnectionIndicator.shared.setConnected(connected, for: dockWindowID)
        }
        .onDisappear {
            DockConnectionIndicator.shared.setConnected(false, for: dockWindowID)
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .plainText, defaultFilename: "Serial-\(Date().formatted(.iso8601.year().month().day()))") { result in
            if case .failure(let error) = result { session.errorMessage = error.localizedDescription }
        }
        .alert(AppText.operationIncomplete, isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button(AppText.ok) { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? "")
        }
        .alert(AppText.customBaudRate, isPresented: $editingBaudRate) {
            TextField(AppText.baudExample, text: $customBaudRate)
            Button(AppText.cancel, role: .cancel) {}
            Button(AppText.confirm) {
                let value = customBaudRate.trimmingCharacters(in: .whitespacesAndNewlines)
                if let rate = Int(value), (1...4_000_000).contains(rate) {
                    session.baudRate = String(rate)
                } else {
                    session.errorMessage = AppText.invalidIntegerBaud
                }
            }
        } message: {
            Text(AppText.baudSupportHelp)
        }
        .alert(AppText.savePreset, isPresented: $savingPreset) {
            TextField(AppText.presetName, text: $presetName)
            Button(AppText.cancel, role: .cancel) {}
            Button(AppText.save) { session.savePreset(name: presetName) }
        } message: {
            Text(AppText.savePresetHelp)
        }
    }

    private var interfaceAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }

    private var sendPanelAnimation: Animation {
        .easeInOut(duration: reduceMotion ? 0.12 : 0.28)
    }

    private var sendPanelTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8))
    }

    private func selectSendMode(_ mode: SendMode) {
        guard mode != sendMode else { return }
        withAnimation(sendPanelAnimation) {
            if mode != .presets { editingPresetID = nil }
            sendMode = mode
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 10) {
                        Image(systemName: "cable.connector")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text(AppText.appName)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                    }
                    .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle(AppText.connectionSettings, icon: "slider.horizontal.3")
                        HStack {
                            Text(AppText.device).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                Task { await session.refreshPorts() }
                            } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(AppText.rescanPorts)
                                .help(AppText.rescanPorts)
                        }
                        SerialDevicePicker(ports: session.ports, path: $session.selectedPath)
                            .frame(maxWidth: .infinity)
                        TextField(AppText.devicePathPlaceholder, text: $session.selectedPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .accessibilityLabel(AppText.devicePath)
                            .help(AppText.devicePathHelp)
                        if session.ports.isEmpty {
                            Label(AppText.noDevices, systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider().padding(.vertical, 2)
                        connectionParameters
                    }
                    .disabled(session.isConnected || session.isConnecting)
                }
                .padding(16)
            }
            Divider()
            connectionButton
                .padding(14)
        }
        .background(.background.secondary)
    }

    @ViewBuilder
    private var connectionParameters: some View {
        if #available(macOS 26.0, *) {
            connectionParameterGrid.buttonSizing(.flexible)
        } else {
            connectionParameterGrid
        }
    }

    private var connectionParameterGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
            GridRow {
                Text(AppText.baudRate).gridColumnAlignment(.trailing)
                baudRatePicker
            }
            GridRow {
                Text(AppText.dataBits)
                Picker(AppText.dataBits, selection: $session.dataBits) {
                    ForEach(5...8, id: \.self) { Text(String($0)).tag($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GridRow {
                Text(AppText.stopBits)
                Picker(AppText.stopBits, selection: $session.stopBits) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                }
                .frame(maxWidth: .infinity)
            }
            GridRow {
                Text(AppText.parity)
                Picker(AppText.parity, selection: $session.parity) {
                    ForEach(SerialParity.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: .infinity)
            }
            GridRow {
                Text(AppText.flowControl)
                Picker(AppText.flowControl, selection: $session.flowControl) {
                    ForEach(SerialFlowControl.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .font(.callout)
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private var baudRatePicker: some View {
        Picker(AppText.baudRate, selection: Binding(
            get: { baudRates.contains(Int(session.baudRate) ?? 0) ? session.baudRate : "custom" },
            set: { value in
                if value == "custom" {
                    customBaudRate = session.baudRate
                    editingBaudRate = true
                } else {
                    session.baudRate = value
                }
            }
        )) {
            ForEach(baudRates, id: \.self) { rate in
                Text(String(rate)).tag(String(rate))
            }
            Divider()
            Text(baudRates.contains(Int(session.baudRate) ?? 0) ? AppText.custom : AppText.customBaudLabel(session.baudRate))
                .tag("custom")
        }
        .frame(maxWidth: .infinity)
    }

    private var connectionButton: some View {
        Button {
            Task {
                if session.isConnected { await session.disconnect() }
                else { await session.connect() }
            }
        } label: {
            HStack {
                if session.isConnecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: session.isConnected ? "stop.fill" : "bolt.fill")
                }
                Text(session.isConnected ? AppText.disconnect : session.isConnecting ? AppText.connecting : AppText.connect)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .animation(interfaceAnimation, value: session.isConnected)
            .animation(interfaceAnimation, value: session.isConnecting)
        }
        .buttonStyle(.borderedProminent)
        .tint(session.isConnected ? .red : .accentColor)
        .disabled(session.isConnecting || session.selectedPath.isEmpty)
        .keyboardShortcut("o", modifiers: .command)
    }

    private var receiveControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                receiveDisplaySelector
                Spacer(minLength: 8)
                ViewThatFits(in: .horizontal) {
                    logVisibilityControls
                    Menu {
                        logVisibilityOptions
                    } label: {
                        Label(AppText.displayOptions, systemImage: "line.3.horizontal.decrease")
                    }
                    .fixedSize()
                    .help(AppText.displayOptions)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    logSearchField.frame(minWidth: 140)
                    logPlaybackControls
                }
                VStack(spacing: 8) {
                    logSearchField
                    HStack {
                        Spacer(minLength: 0)
                        logPlaybackControls
                    }
                }
            }
        }
        .font(.caption)
        .toggleStyle(.checkbox)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var logSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(AppText.filterBuffer, text: $session.search)
                .textFieldStyle(.plain)
                .accessibilityLabel(AppText.filterBuffer)
            if !session.search.isEmpty {
                Button { session.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(AppText.clearFilter)
                    .help(AppText.clearFilter)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
        .animation(interfaceAnimation, value: session.search.isEmpty)
    }

    private var logPlaybackControls: some View {
        HStack(spacing: 12) {
            Toggle(AppText.autoWrap, isOn: $session.autoWrap)
                .help(AppText.autoWrapHelp)
            Toggle(AppText.autoScroll, isOn: $session.autoScroll)
            Button {
                session.paused.toggle()
            } label: {
                Label(session.paused ? AppText.resumeDisplay : AppText.pauseDisplay, systemImage: session.paused ? "play.fill" : "pause.fill")
            }
            .help(AppText.pauseHelp)
        }
        .fixedSize()
    }

    private var receiveDisplaySelector: some View {
        HStack(spacing: 12) {
            Text(AppText.receiveMonitor).font(.headline)
            Picker(AppText.receiveDisplay, selection: $session.receiveHex) {
                Text(AppText.textMode).tag(false)
                Text("HEX").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 112)
        }
        .fixedSize()
    }

    private var logVisibilityControls: some View {
        HStack(spacing: 12) {
            logVisibilityOptions
        }
        .fixedSize()
    }

    private var logVisibilityOptions: some View {
        Group {
            Toggle(AppText.timestamps, isOn: $session.timestamps)
            Toggle(AppText.showRX, isOn: $session.showReceived)
                .help(AppText.showRXHelp)
            Toggle(AppText.showTX, isOn: $session.showSent)
                .help(AppText.showTXHelp)
            Toggle(AppText.showSYS, isOn: $session.showSystem)
                .help(AppText.showSYSHelp)
        }
    }

    private var terminal: some View {
        TerminalOutputView(session: session)
    }

    private var sendPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    sendInputMode
                    Spacer(minLength: 8)
                    sendFormatControls(compact: false)
                }
                HStack(spacing: 10) {
                    sendInputMode
                    Spacer(minLength: 8)
                    sendFormatControls(compact: true)
                }
            }
            .font(.caption)
            SendTextEditor(
                text: $session.input,
                placeholder: session.sendHex ? AppText.hexPlaceholder : AppText.sendPlaceholder,
                onSend: {
                    guard session.isConnected, !session.isSending, !session.isRepeating, !session.input.isEmpty else { return }
                    Task { await session.send() }
                }
            )
            .frame(minHeight: 65, maxHeight: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 7))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
            ViewThatFits(in: .horizontal) {
                sendActions(compact: false)
                sendActions(compact: true)
            }
            Text(session.sendHex ? AppText.hexEndingHelp : AppText.repeatHelp)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.background.secondary)
    }

    private func sendActions(compact: Bool) -> some View {
        HStack(spacing: 10) {
            if compact {
                savePresetButton.labelStyle(.iconOnly)
            } else {
                savePresetButton
            }
            Spacer(minLength: 8)
            sendIntervalControls
            repeatSendButton
            sendCommandButton
        }
    }

    private var sendInputMode: some View {
        HStack {
            Text(AppText.send).font(.headline)
            Toggle(AppText.hexInput, isOn: $session.sendHex).toggleStyle(.checkbox)
        }
    }

    private func sendFormatControls(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if compact {
                    encodingPicker.labelsHidden().frame(width: 106)
                    lineEndingPicker.labelsHidden().frame(width: 88)
                } else {
                    encodingPicker.frame(width: 166)
                    lineEndingPicker.frame(width: 132)
                }
            }
        }
        .fixedSize()
    }

    private var encodingPicker: some View {
        Picker(AppText.encoding, selection: $session.encoding) {
            ForEach(TextEncoding.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .help(AppText.encoding)
    }

    private var lineEndingPicker: some View {
        Picker(AppText.lineEnding, selection: $session.ending) {
            ForEach(LineEnding.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .help(AppText.lineEnding)
    }

    private var savePresetButton: some View {
        Button {
            presetName = ""
            savingPreset = true
        } label: {
            Label(AppText.saveAsPreset, systemImage: "bookmark")
        }
        .disabled(session.input.isEmpty)
        .help(AppText.saveAsPreset)
    }

    private var sendIntervalControls: some View {
        HStack(spacing: 6) {
            TextField("1000", text: $session.interval)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(AppText.intervalAccessibility)
                .help(AppText.intervalHelp)
                .frame(width: 65).multilineTextAlignment(.trailing)
                .disabled(session.isRepeating)
            Text(AppText.milliseconds).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var repeatSendButton: some View {
        Button(session.isRepeating ? AppText.stopRepeating : AppText.repeatSend) { session.toggleRepeating() }
            .disabled(!session.isRepeating && (!session.isConnected || session.input.isEmpty || session.isSending))
    }

    private var sendCommandButton: some View {
        Button {
            Task { await session.send() }
        } label: {
            Label(AppText.send, systemImage: "paperplane.fill")
                .padding(.horizontal, 10)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!session.isConnected || session.isRepeating || session.input.isEmpty || session.isSending)
    }

    private var presetsPanel: some View {
        let currentEditingID = editingPresetID

        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                presetHeader(compact: false)
                presetHeader(compact: true)
            }
            if session.presets.isEmpty {
                VStack(spacing: 8) {
                    Label(AppText.noPresets, systemImage: "bookmark")
                        .font(.subheadline)
                    Text(AppText.noPresetsHelp)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PresetCommandScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.presets) { preset in
                            presetRow(preset)
                                .presetScrollAnchor(active: currentEditingID == preset.id)
                                .transition(.opacity)
                        }
                    }
                }
            }
        }
        .animation(interfaceAnimation, value: session.presets.map(\.id))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.background.secondary)
    }

    private var presetPanelTitle: some View {
        HStack(spacing: 8) {
            Text(AppText.presetPanel).font(.headline)
            Text(AppText.presetCount(session.presets.count))
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private func presetHeader(compact: Bool) -> some View {
        HStack(spacing: 12) {
            presetPanelTitle
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if compact {
                    Image(systemName: "timer")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                } else {
                    Label(AppText.repeatSend, systemImage: "timer")
                        .font(.caption).foregroundStyle(.secondary)
                }
                sendIntervalControls
            }
            .fixedSize()
            if session.isRepeating {
                Button(AppText.stopRepeating) { session.stopRepeating() }
                    .fixedSize()
            } else {
                Button { selectSendMode(.command) } label: {
                    if compact {
                        Label(AppText.composeCommand, systemImage: "square.and.pencil").labelStyle(.iconOnly)
                    } else {
                        Text(AppText.composeCommand)
                    }
                }
                .fixedSize()
                .help(AppText.composeCommand)
            }
        }
    }

    private func presetRow(_ preset: CommandPreset) -> some View {
        PresetCommandRow(
            preset: preset,
            canSend: session.isConnected && !session.isRepeating && !session.isSending,
            onSave: { session.updatePreset($0) },
            onSend: { Task { await session.sendPreset(preset) } },
            onDelete: {
                if editingPresetID == preset.id { editingPresetID = nil }
                session.deletePreset(id: preset.id)
            },
            isRepeating: session.repeatingPresetID == preset.id,
            canRepeat: session.isConnected && !session.isRepeating && !session.isSending,
            onToggleRepeating: { session.togglePresetRepeating(preset) },
            onEditingChanged: { editing in
                if editing {
                    editingPresetID = preset.id
                } else if editingPresetID == preset.id {
                    editingPresetID = nil
                }
            }
        )
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                sendPanelSelector
                Spacer(minLength: 0)
                connectionStatus
                trafficCounters
            }
            VStack(spacing: 5) {
                HStack(spacing: 12) {
                    sendPanelSelector
                    Spacer(minLength: 0)
                    connectionStatus
                }
                HStack {
                    Spacer(minLength: 0)
                    trafficCounters
                }
            }
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.vertical, 7)
    }

    private var sendPanelSelector: some View {
        sendModePicker
            .labelsHidden()
            .fixedSize(horizontal: true, vertical: false)
            .disabled(session.isRepeating)
            .help(session.isRepeating ? AppText.stopRepeatToSwitch : AppText.switchPanelHelp)
    }

    private var connectionStatus: some View {
        ConnectionStatusView(
            title: session.isRepeating ? AppText.repeating : session.status,
            connected: session.isConnected,
            repeating: session.isRepeating
        )
        .help(session.isConnected ? "\(session.selectedPath) · \(session.configurationSummary)" : session.status)
    }

    private var trafficCounters: some View {
        TrafficCountersView(session: session)
    }

    @ViewBuilder
    private var sendModePicker: some View {
        // Use tab semantics for switching panels, with the native segmented control on older macOS versions.
        if #available(macOS 27.0, *) {
            sendModeOptions.pickerStyle(.tabs)
        } else {
            sendModeOptions.pickerStyle(.segmented)
        }
    }

    private var sendModeOptions: some View {
        Picker(AppText.sendPanel, selection: Binding(
            get: { sendMode },
            set: { selectSendMode($0) }
        )) {
            ForEach(SendMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

}

/// Keep the status slot stable so changing a device name never moves nearby controls.
struct ConnectionStatusView: View {
    let title: String
    let connected: Bool
    let repeating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(repeating ? Color.orange : connected ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: connected)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: repeating)
            ZStack(alignment: .leading) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .id(title)
                    .transition(.opacity)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: title)
        }
        .frame(width: 152, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

#Preview("默认窗口") {
    ContentView()
}

#Preview("紧凑窗口 · 浅色") {
    ContentView()
        .frame(width: 920, height: 640)
        .preferredColorScheme(.light)
}

#Preview("紧凑窗口 · 深色") {
    ContentView()
        .frame(width: 920, height: 640)
        .preferredColorScheme(.dark)
}

#Preview("左右平铺 · 窄窗口") {
    ContentView()
        .frame(width: 700, height: 640)
}

#if DEBUG
extension ContentView {
    fileprivate static func presetCommandsPreview() -> ContentView {
        var view = ContentView()
        view._sendMode = State(initialValue: .presets)
        return view
    }
}

#Preview("预设面板 · 窄窗口") {
    ContentView.presetCommandsPreview()
        .frame(width: 700, height: 640)
}

#Preview("常规窗口 · 预设面板") {
    ContentView.presetCommandsPreview()
        .frame(width: 1120, height: 780)
}
#endif
