import Foundation
import Observation

@MainActor
@Observable
final class SerialSession {
    var connectionMode: SerialConnectionMode = .local
    var sshHost = "" { didSet { if sshHost != oldValue { invalidateSSHSupport() } } }
    var sshPort = "22" { didSet { if sshPort != oldValue { invalidateSSHSupport() } } }
    var sshUsername = "" { didSet { if sshUsername != oldValue { invalidateSSHSupport() } } }
    var sshAuthentication: SSHAuthentication = .password { didSet { if sshAuthentication != oldValue { invalidateSSHSupport() } } }
    private(set) var sshIdentityURL: URL?
    private(set) var sshKeyName = ""
    var remotePath = "" { didSet { if remotePath != oldValue { sshDeviceError = nil } } }
    private(set) var sshSupportStatus: SSHSupportStatus = .unchecked
    private(set) var sshDeviceError: String?
    private(set) var remotePorts: [SerialPort] = []
    private(set) var isScanning = false
    var ports: [SerialPort] = []
    var selectedPath = ""
    var baudRate = "115200"
    var dataBits = 8
    var stopBits = 1
    var parity: SerialParity = .none
    var flowControl: SerialFlowControl = .none
    private(set) var isConnected = false
    private(set) var isConnecting = false
    private(set) var isSending = false
    private(set) var isRepeating = false
    private(set) var repeatingPresetID: UUID?
    private(set) var receivedBytes = 0
    private(set) var sentBytes = 0
    private(set) var logText = ""
    private(set) var logUpdate = TerminalTextUpdate()
    private enum ConnectionStatus {
        case disconnected, connecting, closed, failed
        case connected(String)
    }

    private var connectionStatus: ConnectionStatus = .disconnected

    var status: String {
        switch connectionStatus {
        case .disconnected: AppText.disconnected
        case .connecting: AppText.connectingStatus
        case .closed: AppText.connectionEnded
        case .failed: AppText.connectionFailed
        case .connected(let device): device
        }
    }
    private(set) var discardedEntries = 0

    var input = ""
    var sendHex = false
    var receiveHex = false { didSet { if receiveHex != oldValue { refreshLogDisplay() } } }
    var encoding: TextEncoding = .utf8 { didSet { if encoding != oldValue { rebuildLog() } } }
    var ending: LineEnding = .crlf
    var timestamps = true { didSet { if timestamps != oldValue { refreshLogDisplay() } } }
    var showReceived = true { didSet { if showReceived != oldValue { refreshLogDisplay() } } }
    var showSent = true { didSet { if showSent != oldValue { refreshLogDisplay() } } }
    var showSystem = true { didSet { if showSystem != oldValue { refreshLogDisplay() } } }
    var paused = false { didSet { if paused != oldValue, !paused { refreshLogDisplay() } } }
    private(set) var preprocessingEnabled = false
    private(set) var scriptSource = ReceiveScriptWorker.defaultSource
    private(set) var activeScriptID: UUID?
    private(set) var scriptError: String?
    private(set) var sendScriptEnabled = false
    private(set) var sendScriptSource = SendScriptExample.defaultSource
    private(set) var activeSendScriptID: UUID?
    private(set) var sendScriptError: String?
    var autoWrap = true
    var autoScroll = true
    var search = "" { didSet { if search != oldValue { refreshLogDisplay() } } }
    var interval = "1000"
    var errorMessage: String?
    var presets: [CommandPreset] { presetStore.presets }
    var sshProfiles: [SSHProfile] { sshProfileStore.profiles }
    var isSavingSSHProfile: Bool { sshProfileStore.isMutating }
    private(set) var sshProfileID: UUID?
    var selectedSSHProfile: SSHProfile? { sshProfiles.first { $0.id == sshProfileID } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let presetStore: CommandPresetStore
    @ObservationIgnored private let sshProfileStore: SSHProfileStore
    @ObservationIgnored private var savedPath = ""
    @ObservationIgnored private var lastConnectedPath: String?
    @ObservationIgnored private var savedBaudRate = ""
    @ObservationIgnored private var repeatTaskID: UUID?
    @ObservationIgnored private let transport = SerialTransport()
    @ObservationIgnored private let sshTransport: SSHSerialTransport
    @ObservationIgnored private let sshScanner: SSHSerialTransport
    @ObservationIgnored private var scanID = UUID()
    @ObservationIgnored private var sshSettingsID = UUID()
    @ObservationIgnored private var connectedRemotely = false
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var repeatTask: Task<Void, Never>?
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var entries: [LogEntry] = []
    @ObservationIgnored private var pendingEntries: [LogEntry] = []
    @ObservationIgnored private var pendingReceivedBytes = 0
    @ObservationIgnored private var storageBytes = 0
    @ObservationIgnored private var needsRender = false
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var renderer = TerminalLogRenderer()
    @ObservationIgnored private var decoder = StreamingTextDecoder(encoding: .utf8)
    @ObservationIgnored private let sendScriptEngine: SendScriptEngine
    @ObservationIgnored private var sendScriptGeneration = UUID()
    @ObservationIgnored private let scriptEngine: ReceiveScriptEngine
    @ObservationIgnored private var scriptGeneration = UUID()
    @ObservationIgnored private var scriptTask: Task<Void, Never>?
    @ObservationIgnored private var scriptPendingEntries: [LogEntry] = []
    @ObservationIgnored private var scriptPendingBytes = 0
    @ObservationIgnored private var processedEntries: [LogEntry] = []
    @ObservationIgnored private var processedBytes = 0
    @ObservationIgnored private var processedDiscarded = 0
    @ObservationIgnored private lazy var formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init(defaults: UserDefaults = .standard, presetStore: CommandPresetStore? = nil, scriptEngine: ReceiveScriptEngine = ReceiveScriptEngine(), sendScriptEngine: SendScriptEngine = SendScriptEngine(), sshTransport: SSHSerialTransport? = nil, sshScanner: SSHSerialTransport? = nil, sshProfileStore: SSHProfileStore? = nil) {
        self.sshTransport = sshTransport ?? SSHSerialTransport()
        self.sshScanner = sshScanner ?? SSHSerialTransport()
        self.scriptEngine = scriptEngine
        self.sendScriptEngine = sendScriptEngine
        self.defaults = defaults
        self.presetStore = presetStore ?? .shared
        self.sshProfileStore = sshProfileStore ?? .shared
        selectedPath = defaults.string(forKey: "serial.path") ?? ""
        baudRate = defaults.string(forKey: "serial.baud") ?? "115200"
        sshHost = defaults.string(forKey: "ssh.host") ?? ""
        sshPort = defaults.string(forKey: "ssh.port") ?? "22"
        sshUsername = defaults.string(forKey: "ssh.username") ?? ""
        remotePath = defaults.string(forKey: "ssh.device") ?? ""
        sshAuthentication = SSHAuthentication(rawValue: defaults.string(forKey: "ssh.authentication") ?? "") ?? .password
        if let name = defaults.string(forKey: "ssh.identity"), name.hasPrefix("identity-"), !name.contains("/") {
            sshIdentityURL = try? SSHFiles.directory().appendingPathComponent(name)
            sshKeyName = defaults.string(forKey: "ssh.keyName") ?? name
        }
        savedPath = selectedPath
        savedBaudRate = baudRate
        scriptSource = defaults.string(forKey: "serial.receiveScript") ?? ReceiveScriptWorker.defaultSource
        activeScriptID = defaults.string(forKey: "serial.receiveScriptID").flatMap(UUID.init(uuidString:))
        sendScriptSource = defaults.string(forKey: "serial.sendScript") ?? SendScriptExample.defaultSource
        activeSendScriptID = defaults.string(forKey: "serial.sendScriptID").flatMap(UUID.init(uuidString:))
        if let configuration = try? sshConfiguration() {
            if let savedID = defaults.string(forKey: "ssh.profileID") {
                // An empty identifier preserves an explicitly unsaved connection.
                if let profile = self.sshProfileStore.profiles.first(where: {
                    $0.id.uuidString == savedID && $0.matches(configuration)
                }) {
                    sshProfileID = profile.id
                }
            } else {
                // Migrate settings saved before profile selection was persisted.
                let matches = self.sshProfileStore.profiles.filter { $0.matches(configuration) }
                if matches.count == 1 { sshProfileID = matches[0].id }
            }
        }
    }

    var configurationSummary: String {
        "\(baudRate) · \(dataBits)\(parity == .none ? "N" : parity == .even ? "E" : "O")\(stopBits)"
    }

    func monitor() async {
        while !Task.isCancelled {
            if connectionMode == .local && !isConnected && !isConnecting && !isScanning { await refreshPorts() }
            do { try await Task.sleep(for: .seconds(2)) } catch { break }
        }
        savePreferences()
        await disconnect()
    }

    func newSSHProfile() {
        guard !isConnected, !isConnecting, !isScanning else { return }
        sshProfileID = nil
        sshHost = ""
        sshPort = "22"
        sshUsername = ""
        sshAuthentication = .password
        sshIdentityURL = nil
        sshKeyName = ""
        remotePath = ""
        invalidateSSHSupport()
    }

    func selectSSHProfile(_ id: UUID?) {
        guard !isConnected, !isConnecting, !isScanning else { return }
        guard let profile = sshProfiles.first(where: { $0.id == id }) else {
            sshProfileID = nil
            return
        }
        do {
            let configuration = try profile.configuration()
            try configuration.validate()
            sshProfileID = profile.id
            sshHost = profile.host
            sshPort = String(profile.port)
            sshUsername = profile.username
            sshAuthentication = profile.authentication
            sshIdentityURL = configuration.identityURL
            sshKeyName = profile.keyName
            remotePath = profile.device
            baudRate = String(profile.baudRate)
            dataBits = profile.dataBits
            stopBits = profile.stopBits
            parity = profile.parity
            flowControl = profile.flowControl
            invalidateSSHSupport()
        } catch { errorMessage = error.localizedDescription }
    }

    func saveSSHProfile(name: String, password: String, asNew: Bool) async throws {
        guard !isConnected, !isConnecting, !isScanning else {
            throw SerialTransportError(message: AppText.disconnectFirst)
        }
        let configuration = try sshConfiguration()
        guard let baud = Int(baudRate) else { throw SerialTransportError(message: AppText.invalidBaud) }
        let profile = SSHProfile(
            id: asNew ? UUID() : selectedSSHProfile?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: configuration.host, port: configuration.port, username: configuration.username,
            authentication: configuration.authentication, identityFile: sshIdentityURL?.lastPathComponent,
            keyName: sshKeyName, device: remotePath, baudRate: baud, dataBits: dataBits,
            stopBits: stopBits, parity: parity, flowControl: flowControl
        )
        try await sshProfileStore.save(profile, password: password)
        sshProfileID = profile.id
    }

    func deleteSSHProfile() async throws {
        guard let id = selectedSSHProfile?.id else { return }
        try await sshProfileStore.remove(id: id)
        if sshProfileID == id { sshProfileID = nil }
    }

    func forgetSSHPassword() async throws {
        guard let id = selectedSSHProfile?.id else { return }
        try await sshProfileStore.forgetPassword(id: id)
    }

    func importSSHIdentity(from url: URL) throws {
        sshIdentityURL = try SSHFiles.importIdentity(from: url)
        sshKeyName = url.lastPathComponent
        invalidateSSHSupport()
        defaults.set(sshIdentityURL?.lastPathComponent, forKey: "ssh.identity")
        defaults.set(sshKeyName, forKey: "ssh.keyName")
    }

    private func invalidateSSHSupport() {
        sshSettingsID = UUID()
        sshSupportStatus = .unchecked
        sshDeviceError = nil
        remotePorts = []
    }

    private func setSSHSupport(_ report: SSHSupportReport?, error: Error? = nil) {
        if let report {
            sshSupportStatus = .checked(report)
        } else if let error {
            sshSupportStatus = .failed(error.localizedDescription)
        } else {
            sshSupportStatus = .unchecked
        }
    }

    private func sshConfiguration() throws -> SSHConfiguration {
        guard let port = Int(sshPort) else { throw SerialTransportError(message: AppText.sshInvalidConfiguration) }
        var configuration = SSHConfiguration(host: sshHost.trimmingCharacters(in: .whitespacesAndNewlines),
                                             port: port, username: sshUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                                             authentication: sshAuthentication, identityURL: sshIdentityURL)
        try configuration.validate()
        if configuration.authentication == .password, let profile = selectedSSHProfile, profile.matches(configuration) {
            configuration.passwordAccount = profile.passwordAccount
        }
        return configuration
    }

    func refreshPorts() async {
        if connectionMode == .ssh {
            guard !isConnected, !isConnecting, !isScanning else { return }
            let token = UUID()
            scanID = token
            let settingsID = sshSettingsID
            isScanning = true
            sshSupportStatus = .checking
            sshDeviceError = nil
            defer { if scanID == token { isScanning = false } }
            do {
                let configuration = try sshConfiguration()
                let discovered = try await sshScanner.scan(configuration, generation: token)
                let report = await sshScanner.checkedSupport(for: token)
                guard scanID == token, sshSettingsID == settingsID, !Task.isCancelled else { return }
                setSSHSupport(report)
                remotePorts = discovered
                if remotePath.isEmpty { remotePath = discovered.first?.path ?? "" }
                savePreferences(force: true)
            } catch {
                let report = await sshScanner.checkedSupport(for: token)
                guard scanID == token, sshSettingsID == settingsID, !Task.isCancelled else { return }
                setSSHSupport(report, error: error)
                errorMessage = error.localizedDescription
            }
            return
        }
        let discovered = await Task.detached { SerialTransport.availablePorts() }.value
        if ports != discovered { ports = discovered }
        if selectedPath.isEmpty { selectedPath = ports.first?.path ?? "" }
    }

    func connect() async {
        guard !isConnected, !isConnecting, !isScanning else { return }
        guard let baud = Int(baudRate), (1...4_000_000).contains(baud) else {
            errorMessage = AppText.invalidBaud
            return
        }
        let remote = connectionMode == .ssh
        let ssh: SSHConfiguration?
        do { ssh = remote ? try sshConfiguration() : nil }
        catch { errorMessage = error.localizedDescription; return }
        let path = remote ? remotePath.trimmingCharacters(in: .whitespacesAndNewlines) : selectedPath
        isConnecting = true
        connectionStatus = .connecting
        sessionID = UUID()
        let token = sessionID
        let configuration = SerialConfiguration(path: path, baudRate: baud, dataBits: dataBits, stopBits: stopBits, parity: parity, flowControl: flowControl)
        let settingsID = sshSettingsID
        if remote { sshSupportStatus = .checking; sshDeviceError = nil }
        let endpoint = ssh.map { "ssh://" + $0.authority + path } ?? path
        do {
            let stream: AsyncThrowingStream<Data, Error>
            if let ssh { stream = try await sshTransport.open(ssh, configuration: configuration, generation: token) }
            else { stream = try await transport.open(configuration, generation: token) }
            let report = remote ? await sshTransport.checkedSupport(for: token) : nil
            guard sessionID == token, !Task.isCancelled else {
                await transport.close(ifGeneration: token)
                await sshTransport.close(ifGeneration: token)
                guard sessionID == token else { return }
                isConnecting = false
                connectionStatus = .disconnected
                return
            }
            if remote, sshSettingsID == settingsID { setSSHSupport(report) }
            decoder = StreamingTextDecoder(encoding: encoding)
            // Keep preprocessing on reconnect; require opting in again for a different port.
            if let lastConnectedPath, lastConnectedPath != endpoint {
                preprocessingEnabled = false
            }
            lastConnectedPath = endpoint
            scriptError = nil
            resetScriptProcessing()
            resetSendScript()
            connectedRemotely = remote
            isConnected = true
            isConnecting = false
            let deviceName = URL(fileURLWithPath: path).lastPathComponent
            connectionStatus = .connected(ssh.map { $0.authority + " · " + deviceName } ?? deviceName)
            savePreferences(force: true)
            appendSystem(AppText.connectedMessage(endpoint, configurationSummary, flowControl.title))
            streamTask = Task { [weak self] in
                do {
                    for try await data in stream {
                        guard let self, self.sessionID == token, !Task.isCancelled else { break }
                        self.pendingReceivedBytes += data.count
                        self.pendingEntries.append(LogEntry(date: Date(), direction: .received, data: data, text: ""))
                        self.scheduleFlush()
                    }
                } catch {
                    guard let self, self.sessionID == token else { return }
                    self.errorMessage = error.localizedDescription
                    self.appendSystem(error.localizedDescription)
                }
                guard let self, self.sessionID == token else { return }
                self.resetScriptProcessing(clearOutput: false)
                self.isConnected = false
                self.isSending = false
                self.connectionStatus = .closed
                self.stopRepeating()
                self.appendSystem(AppText.receiveStopped)
                self.flush()
            }
        } catch {
            let report = remote ? await sshTransport.checkedSupport(for: token) : nil
            guard sessionID == token else { return }
            if remote, sshSettingsID == settingsID {
                setSSHSupport(report, error: error)
                if report == .supported { sshDeviceError = error.localizedDescription }
            }
            isConnecting = false
            connectionStatus = .failed
            errorMessage = error.localizedDescription
            appendSystem(error.localizedDescription)
        }
        flush()
    }

    func disconnect() async {
        let closingSessionID = sessionID
        sessionID = UUID()
        let disconnectedSessionID = sessionID
        streamTask?.cancel()
        streamTask = nil
        stopRepeating()
        resetScriptProcessing(clearOutput: false)
        let wasActive = isConnected || isConnecting
        isConnected = false
        isConnecting = false
        isSending = false
        connectionStatus = .disconnected
        let closingScanID = scanID
        scanID = UUID()
        isScanning = false
        if sshSupportStatus == .checking { sshSupportStatus = .unchecked }
        await transport.close(ifGeneration: closingSessionID)
        await sshTransport.close(ifGeneration: closingSessionID)
        await sshScanner.close(ifGeneration: closingScanID)
        guard sessionID == disconnectedSessionID else { return }
        if wasActive { appendSystem(AppText.portDisconnected) }
        flush()
    }

    @discardableResult
    func send(text: String? = nil, hex: Bool? = nil, lineEnding: LineEnding? = nil, textEncoding: TextEncoding? = nil) async -> Bool {
        guard isConnected, !isSending else { return false }
        let data: Data
        do {
            data = try PayloadCodec.encode(text ?? input, hex: hex ?? sendHex, encoding: textEncoding ?? encoding, ending: lineEnding ?? ending)
        } catch {
            errorMessage = error.localizedDescription
            stopRepeating()
            return false
        }
        isSending = true
        let token = sessionID
        defer { if token == sessionID { isSending = false } }
        return await writePayload(data, token: token)
    }

    private func writePayload(_ data: Data, token: UUID) async -> Bool {
        do {
            let count = connectedRemotely ? try await sshTransport.write(data) : try await transport.write(data)
            guard token == sessionID else { return false }
            sentBytes += count
            pendingEntries.append(LogEntry(date: Date(), direction: .sent, data: data, text: ""))
            scheduleFlush()
            return true
        } catch {
            guard token == sessionID else { return false }
            if let serialError = error as? SerialTransportError, serialError.bytesWritten > 0 {
                sentBytes += serialError.bytesWritten
                pendingEntries.append(LogEntry(date: Date(), direction: .sent, data: Data(data.prefix(serialError.bytesWritten)), text: ""))
            }
            errorMessage = error.localizedDescription
            appendSystem(error.localizedDescription)
            await disconnect()
            return false
        }
    }

    func configureSendScript(source: String, enabled: Bool, scriptID: UUID? = nil) {
        if isRepeating, repeatingPresetID == nil { stopRepeating() }
        sendScriptSource = source
        sendScriptEnabled = enabled
        activeSendScriptID = scriptID
        sendScriptError = nil
        defaults.set(source, forKey: "serial.sendScript")
        defaults.set(scriptID?.uuidString, forKey: "serial.sendScriptID")
        resetSendScript()
    }

    private func resetSendScript() {
        sendScriptGeneration = UUID()
        sendScriptEngine.reset()
    }

    @discardableResult
    func sendCommand() async -> Bool {
        guard !isRepeating else { return false }
        if !sendScriptEnabled { return await send() }
        return await sendGenerated(
            input: input, source: sendScriptSource, generation: sendScriptGeneration,
            textEncoding: encoding, lineEnding: ending
        )
    }

    private func sendGenerated(
        input: String, source: String, generation: UUID,
        textEncoding: TextEncoding, lineEnding: LineEnding
    ) async -> Bool {
        guard isConnected, !isSending else { return false }
        isSending = true
        let token = sessionID
        defer { if token == sessionID { isSending = false } }
        do {
            let payload = try await sendScriptEngine.generate(source: source, input: input, generation: generation)
            // Stopping a timer, editing a script, or reconnecting invalidates work in flight.
            guard !Task.isCancelled, token == sessionID, generation == sendScriptGeneration, isConnected else { return false }
            sendScriptError = nil
            guard let payload else { return true }
            let data = try payload.data(encoding: textEncoding, ending: lineEnding)
            return await writePayload(data, token: token)
        } catch {
            guard !Task.isCancelled, token == sessionID, generation == sendScriptGeneration else { return false }
            sendScriptError = error.localizedDescription
            errorMessage = error.localizedDescription
            stopRepeating()
            return false
        }
    }

    func toggleRepeating() {
        if isRepeating {
            stopRepeating()
            return
        }
        startRepeating(text: input, hex: sendHex, lineEnding: ending, textEncoding: encoding,
                       scriptSource: sendScriptEnabled ? sendScriptSource : nil)
    }

    func togglePresetRepeating(_ preset: CommandPreset) {
        if repeatingPresetID == preset.id {
            stopRepeating()
            return
        }
        guard !isRepeating, presets.contains(where: { $0.id == preset.id }) else { return }
        startRepeating(
            text: preset.text, hex: preset.isHex, lineEnding: preset.ending,
            textEncoding: preset.encoding, presetID: preset.id
        )
    }

    private func startRepeating(
        text: String, hex: Bool, lineEnding: LineEnding, textEncoding: TextEncoding,
        presetID: UUID? = nil, scriptSource: String? = nil
    ) {
        guard isConnected, !isSending, let milliseconds = Int(interval), (10...3_600_000).contains(milliseconds) else {
            errorMessage = AppText.invalidInterval
            return
        }
        // Capture input, script, and parameters. Each scripted tick generates a fresh payload.
        if scriptSource != nil { resetSendScript() }
        let scriptGeneration = sendScriptGeneration
        isRepeating = true
        repeatingPresetID = presetID
        let taskID = UUID()
        repeatTaskID = taskID
        repeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.repeatTaskID == taskID, self.isConnected else { break }
                // The library is shared across windows; a deleted command must not be sent again.
                if let presetID, !self.presets.contains(where: { $0.id == presetID }) { break }
                let sent: Bool
                if let scriptSource {
                    sent = await self.sendGenerated(input: text, source: scriptSource, generation: scriptGeneration,
                                                    textEncoding: textEncoding, lineEnding: lineEnding)
                } else {
                    sent = await self.send(text: text, hex: hex, lineEnding: lineEnding, textEncoding: textEncoding)
                }
                guard sent else { break }
                do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { break }
            }
            guard let self, self.repeatTaskID == taskID else { return }
            self.stopRepeating()
        }
    }

    func stopRepeating() {
        resetSendScript()
        repeatTaskID = nil
        repeatTask?.cancel()
        repeatTask = nil
        isRepeating = false
        repeatingPresetID = nil
    }

    func savePreset(name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !input.isEmpty else {
            errorMessage = AppText.incompletePreset
            return
        }
        presetStore.append(CommandPreset(name: title, text: input, isHex: sendHex, ending: ending, encoding: encoding))
    }

    @discardableResult
    func updatePreset(_ preset: CommandPreset) -> Bool {
        let title = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !preset.text.isEmpty else {
            errorMessage = AppText.incompletePreset
            return false
        }
        var updated = preset
        updated.name = title
        return presetStore.update(updated)
    }

    func deletePreset(id: UUID) {
        if repeatingPresetID == id { stopRepeating() }
        presetStore.remove(id: id)
    }

    func sendPreset(_ preset: CommandPreset) async {
        await send(text: preset.text, hex: preset.isHex, lineEnding: preset.ending, textEncoding: preset.encoding)
    }

    func clearLog() {
        flushTask?.cancel()
        flushTask = nil
        resetScriptProcessing()
        entries.removeAll()
        pendingEntries.removeAll()
        receivedBytes += pendingReceivedBytes
        pendingReceivedBytes = 0
        storageBytes = 0
        discardedEntries = 0
        decoder = StreamingTextDecoder(encoding: encoding)
        renderer.clear()
        if logUpdate.revision != renderer.update.revision {
            logText = renderer.text
            logUpdate = renderer.update
        }
        needsRender = false
    }

    func resetCounters() {
        flush()
        receivedBytes = 0
        sentBytes = 0
    }

    func exportText() -> String {
        flush()
        let header = AppText.exportHeader(selectedPath, configurationSummary, Date().formatted())
        return header + entries.map { entry in
            let content = entry.direction == .system ? entry.text : PayloadCodec.hex(entry.data)
            return "[\(formatter.string(from: entry.date))] \(entry.direction.rawValue) \(content)"
        }.joined(separator: "\n")
    }

    private func appendSystem(_ message: String) {
        pendingEntries.append(LogEntry(date: Date(), direction: .system, data: Data(), text: message))
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            // Coalesce serial reads to about 30 display updates per second.
            do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            self?.flush()
        }
    }

    func refreshLocalization() {
        refreshLogDisplay()
    }

    private func refreshLogDisplay() {
        needsRender = true
        flush()
    }

    private func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingEntries.isEmpty || needsRender else { return }
        receivedBytes += pendingReceivedBytes
        pendingReceivedBytes = 0
        var appendedEntries: [LogEntry] = []
        appendedEntries.reserveCapacity(pendingEntries.count)
        for var entry in pendingEntries {
            if entry.direction == .received {
                entry.text = decoder.decode(entry.data)
            } else if entry.direction == .sent {
                entry.text = String(data: entry.data, encoding: encoding.foundationEncoding) ?? PayloadCodec.hex(entry.data)
            }
            storageBytes += entry.data.count + entry.text.utf8.count
            entries.append(entry)
            appendedEntries.append(entry)
        }
        pendingEntries.removeAll(keepingCapacity: true)
        if preprocessingEnabled {
            scriptPendingEntries.append(contentsOf: appendedEntries)
            scriptPendingBytes += appendedEntries.reduce(0) { $0 + $1.data.count + $1.text.utf8.count }
            if scriptPendingBytes > 262_144 || scriptPendingEntries.count > 1500 {
                failPreprocessing(ReceiveScriptFailure.backlog)
            } else {
                scheduleScriptProcessing()
            }
        }
        // Keep the UI bounded under continuous telemetry; counters continue counting all bytes.
        var removedCount = 0
        if entries.count > 1500 || storageBytes > 512_000 {
            // Leave headroom so the text view does not reflow its prefix on every packet.
            while entries.count - removedCount > 1200 || storageBytes > 384_000 {
                let removed = entries[removedCount]
                storageBytes -= removed.data.count + removed.text.utf8.count
                removedCount += 1
            }
        }
        let removedEntryIDs = entries.prefix(removedCount).map(\.id)
        if removedCount > 0 {
            entries.removeFirst(removedCount)
            discardedEntries += removedCount
        }
        if !paused {
            renderLog(appendedEntries: appendedEntries, removedEntryIDs: removedEntryIDs)
            needsRender = false
        } else {
            renderer.invalidate()
            needsRender = true
        }
    }

    private func rebuildLog() {
        renderer.invalidate()
        resetScriptProcessing()
        decoder = StreamingTextDecoder(encoding: encoding)
        storageBytes = 0
        for index in entries.indices {
            switch entries[index].direction {
            case .received: entries[index].text = decoder.decode(entries[index].data)
            case .sent:
                entries[index].text = String(data: entries[index].data, encoding: encoding.foundationEncoding) ?? PayloadCodec.hex(entries[index].data)
            case .system: break
            }
            storageBytes += entries[index].data.count + entries[index].text.utf8.count
        }
        refreshLogDisplay()
    }

    private func renderLog(appendedEntries: [LogEntry], removedEntryIDs: [UUID], processedUpdate: Bool = false) {
        let processed = preprocessingEnabled && !receiveHex
        // Raw input updates counters immediately; text changes only when the script returns.
        guard !processed || processedUpdate || needsRender else { return }
        renderer.render(
            entries: processed ? processedEntries : entries,
            discardedEntries: processed ? processedDiscarded : discardedEntries,
            options: LogDisplayOptions(hex: receiveHex, timestamps: timestamps, showReceived: showReceived, showSent: showSent, showSystem: showSystem, search: search),
            appendedEntries: processed && !processedUpdate ? nil : appendedEntries,
            removedEntryIDs: processed && !processedUpdate ? [] : removedEntryIDs
        )
        logText = renderer.text
        logUpdate = renderer.update
    }

    func configurePreprocessing(source: String, enabled: Bool, scriptID: UUID? = nil) {
        flush()
        scriptSource = source
        defaults.set(source, forKey: "serial.receiveScript")
        activeScriptID = scriptID
        defaults.set(scriptID?.uuidString, forKey: "serial.receiveScriptID")
        preprocessingEnabled = enabled
        scriptError = nil
        resetScriptProcessing()
        renderer.invalidate()
        refreshLogDisplay()
        if enabled { scheduleScriptProcessing() }
    }

    private func resetScriptProcessing(clearOutput: Bool = true) {
        scriptGeneration = UUID()
        scriptTask?.cancel()
        scriptTask = nil
        scriptPendingEntries.removeAll(keepingCapacity: true)
        scriptPendingBytes = 0
        scriptEngine.reset()
        if clearOutput {
            processedEntries.removeAll(keepingCapacity: true)
            processedBytes = 0
            processedDiscarded = 0
            renderer.invalidate()
        }
    }

    private func failPreprocessing(_ error: Error) {
        preprocessingEnabled = false
        scriptError = error.localizedDescription
        resetScriptProcessing()
        renderer.invalidate()
        appendSystem(AppText.scriptStopped(error.localizedDescription))
        needsRender = true
    }

    private func scheduleScriptProcessing() {
        guard preprocessingEnabled, scriptTask == nil else { return }
        let token = scriptGeneration
        let source = scriptSource
        scriptTask = Task { [weak self] in
            guard let self else { return }
            do {
                repeat {
                    let batch = self.scriptPendingEntries
                    self.scriptPendingEntries.removeAll(keepingCapacity: true)
                    self.scriptPendingBytes = 0
                    let processed = try await self.scriptEngine.transform(batch, source: source, generation: token)
                    guard !Task.isCancelled, self.scriptGeneration == token else { return }
                    self.processedEntries.append(contentsOf: processed)
                    self.processedBytes += processed.reduce(0) { $0 + $1.data.count + $1.text.utf8.count }
                    var removed = 0
                    if self.processedEntries.count > 1500 || self.processedBytes > 512_000 {
                        while self.processedEntries.count - removed > 1200 || self.processedBytes > 384_000 {
                            let entry = self.processedEntries[removed]
                            self.processedBytes -= entry.data.count + entry.text.utf8.count
                            removed += 1
                        }
                    }
                    let removedIDs = self.processedEntries.prefix(removed).map(\.id)
                    if removed > 0 {
                        self.processedEntries.removeFirst(removed)
                        self.processedDiscarded += removed
                    }
                    if !self.paused, !self.receiveHex, !processed.isEmpty || removed > 0 {
                        self.renderLog(appendedEntries: processed, removedEntryIDs: removedIDs, processedUpdate: true)
                    }
                } while !self.scriptPendingEntries.isEmpty
                self.scriptTask = nil
            } catch {
                guard !Task.isCancelled, self.scriptGeneration == token else { return }
                self.failPreprocessing(error)
                self.refreshLogDisplay()
            }
        }
    }

    private func savePreferences(force: Bool = false) {
        if force, connectionMode == .ssh {
            defaults.set(sshHost, forKey: "ssh.host")
            defaults.set(sshPort, forKey: "ssh.port")
            defaults.set(sshUsername, forKey: "ssh.username")
            defaults.set(remotePath, forKey: "ssh.device")
            defaults.set(sshAuthentication.rawValue, forKey: "ssh.authentication")
            if let profile = selectedSSHProfile,
               let configuration = try? sshConfiguration(), profile.matches(configuration) {
                defaults.set(profile.id.uuidString, forKey: "ssh.profileID")
            } else {
                defaults.set("", forKey: "ssh.profileID")
            }
        }
        // Closing an unchanged window must not overwrite preferences saved by another window.
        if (force && connectionMode == .local) || selectedPath != savedPath {
            defaults.set(selectedPath, forKey: "serial.path")
            savedPath = selectedPath
        }
        if force || baudRate != savedBaudRate {
            defaults.set(baudRate, forKey: "serial.baud")
            savedBaudRate = baudRate
        }
    }
}
