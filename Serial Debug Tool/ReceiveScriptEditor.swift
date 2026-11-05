import SwiftUI

@MainActor
struct ReceiveScriptEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var source: String
    @State private var name: String
    @State private var baselineSource: String
    @State private var baselineName: String
    @State private var selectedID: UUID
    @State private var draftID: UUID
    @State private var enabled: Bool
    @State private var sample = "$AZCT,M,1792643379,IDLE,35.86V,43.04mA\r\n"
    @State private var result: String?
    @State private var error: String?
    @State private var running = false
    @State private var operation: Task<Void, Never>?
    @State private var previewEngine = ReceiveScriptEngine()
    @State private var confirmingSwitch = false
    @State private var pendingSelection: UUID?
    @State private var pendingDeletion: SavedReceiveScript?
    @State private var savingCopy = false
    @State private var copyName = ""
    let store: ReceiveScriptStore
    let onApply: (String, Bool, UUID?) -> Void

    init(source: String, enabled: Bool, scriptID: UUID? = nil,
         store: ReceiveScriptStore? = nil, onApply: @escaping (String, Bool, UUID?) -> Void) {
        let store = store ?? .shared
        let saved = store.script(id: scriptID).flatMap { $0.source == source ? $0 : nil }
        let draft = UUID()
        _source = State(initialValue: source)
        _name = State(initialValue: saved?.name ?? "")
        _baselineSource = State(initialValue: source)
        _baselineName = State(initialValue: saved?.name ?? "")
        _selectedID = State(initialValue: saved?.id ?? draft)
        _draftID = State(initialValue: draft)
        _enabled = State(initialValue: enabled)
        self.store = store
        self.onApply = onApply
    }

    private var isDirty: Bool { source != baselineSource || name != baselineName }
    private var selectedScript: SavedReceiveScript? { store.script(id: selectedID) }
    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !running && !trimmed.isEmpty && trimmed.count <= 80 && source.utf8.count <= 65_536
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(AppText.scriptTitle, systemImage: "curlybraces")
                    .font(.title2.bold())
                Spacer()
                Toggle(AppText.scriptEnable, isOn: $enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(20)
            Divider()
            HStack(spacing: 0) {
                library
                    .frame(width: 190)
                Divider()
                scriptForm
                    .padding(20)
            }
            Divider()
            HStack(spacing: 10) {
                Button { saveScript(asCopy: false) } label: {
                    Label(AppText.scriptSave, systemImage: "square.and.arrow.down")
                }
                .disabled(!canSave || (selectedScript != nil && !isDirty))
                Button(AppText.scriptSaveAs) {
                    copyName = ""
                    savingCopy = true
                }
                .disabled(running || source.utf8.count > 65_536)
                Button { runPreview() } label: {
                    Label(AppText.scriptPreview, systemImage: "play")
                }
                .disabled(running)
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button(AppText.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AppText.scriptApply) { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || source.utf8.count > 65_536)
            }
            .padding(16)
        }
        .frame(width: 900, height: 720)
        .onChange(of: source) { _, _ in result = nil; error = nil }
        .onChange(of: sample) { _, _ in result = nil; error = nil }
        .onChange(of: store.scripts.map(\.id)) { _, ids in
            if selectedID != draftID, !ids.contains(selectedID) { selectedID = draftID }
        }
        .onDisappear {
            operation?.cancel()
            previewEngine.reset()
        }
        .alert(AppText.scriptDiscardTitle, isPresented: $confirmingSwitch) {
            Button(AppText.cancel, role: .cancel) { pendingSelection = nil }
            Button(AppText.scriptDiscard, role: .destructive) {
                if let pendingSelection { loadScript(pendingSelection) }
                pendingSelection = nil
            }
        } message: {
            Text(AppText.scriptDiscardHelp)
        }
        .alert(AppText.scriptDeleteTitle, isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button(AppText.cancel, role: .cancel) { pendingDeletion = nil }
            Button(AppText.delete, role: .destructive) {
                if let pendingDeletion { store.remove(id: pendingDeletion.id) }
                pendingDeletion = nil
            }
        } message: {
            Text((pendingDeletion?.name ?? "") + "\n" + AppText.scriptDeleteHelp)
        }
        .alert(AppText.scriptSaveAs, isPresented: $savingCopy) {
            TextField(AppText.scriptName, text: $copyName)
            Button(AppText.cancel, role: .cancel) {}
            Button(AppText.save) { saveScript(asCopy: true) }
        }
    }

    private var library: some View {
        VStack(spacing: 0) {
            HStack {
                Text(AppText.scriptLibrary).font(.headline)
                Spacer()
                Button { requestSelection(draftID, force: true) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help(AppText.scriptNew)
                    .accessibilityLabel(AppText.scriptNew)
                    .disabled(running)
            }
            .padding(12)
            List(selection: Binding<UUID?>(
                get: { selectedID },
                set: { if let id = $0 { requestSelection(id) } }
            )) {
                Label(AppText.scriptDraft, systemImage: "doc")
                    .tag(draftID)
                ForEach(store.scripts) { script in
                    HStack(spacing: 6) {
                        Text(script.name).lineLimit(1)
                        Spacer(minLength: 0)
                        if selectedID == script.id, isDirty {
                            Image(systemName: "pencil").foregroundStyle(.secondary)
                        }
                    }
                    .help(script.name)
                    .tag(script.id)
                    .contextMenu {
                        Button(AppText.scriptDelete, role: .destructive) { pendingDeletion = script }
                    }
                }
            }
            .listStyle(.sidebar)
            .disabled(running)
            HStack {
                Spacer()
                Button {
                    pendingDeletion = selectedScript
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(AppText.scriptDelete)
                .accessibilityLabel(AppText.scriptDelete)
                .disabled(running || selectedScript == nil)
            }
            .padding(12)
        }
        .background(.quaternary.opacity(0.2))
    }

    private var scriptForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(AppText.scriptName, text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(AppText.scriptName)
                .disabled(running)
            editor(source: $source, title: AppText.scriptCode)
                .frame(minHeight: 170)
            HStack(alignment: .top, spacing: 14) {
                editor(source: $sample, title: AppText.scriptSample)
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppText.scriptResult).font(.headline)
                    ScrollView {
                        Text(result.map { $0.isEmpty ? AppText.scriptPreviewEmpty : $0 } ?? AppText.scriptPreviewHint)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(result == nil ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator.opacity(0.5)))
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 125)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
        }
    }

    private func requestSelection(_ id: UUID, force: Bool = false) {
        guard (id != selectedID || force), !running else { return }
        if isDirty {
            pendingSelection = id
            confirmingSwitch = true
        } else {
            loadScript(id)
        }
    }

    private func loadScript(_ id: UUID) {
        guard id == draftID || store.script(id: id) != nil else { return }
        let script = store.script(id: id)
        selectedID = id
        source = script?.source ?? ReceiveScriptWorker.defaultSource
        name = script?.name ?? ""
        baselineSource = source
        baselineName = name
        result = nil
        error = nil
    }

    private func saveScript(asCopy: Bool) {
        do {
            let saved = try store.save(name: asCopy ? copyName : name, source: source,
                                       replacing: asCopy ? nil : selectedScript?.id)
            selectedID = saved.id
            name = saved.name
            baselineName = saved.name
            baselineSource = saved.source
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func editor(source: Binding<String>, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            SendTextEditor(text: source, placeholder: "", onSend: {}, accessibilityLabel: title)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator.opacity(0.5)))
                .disabled(running)
        }
        .frame(maxWidth: .infinity)
    }

    private func runPreview() {
        running = true
        error = nil
        let code = source
        let input = sample
        operation = Task {
            do {
                let output = try await previewEngine.preview(source: code, text: input)
                guard !Task.isCancelled else { return }
                if source == code, sample == input { result = output }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                result = nil
            }
            previewEngine.reset()
            running = false
        }
    }

    private func apply() {
        running = true
        error = nil
        let code = source
        let shouldEnable = enabled
        let scriptName = name
        let existingID = selectedScript?.id
        operation = Task {
            do {
                _ = try await previewEngine.transform([], source: code, generation: UUID())
                guard !Task.isCancelled else { return }
                previewEngine.reset()
                if source == code {
                    let saved = try store.saveForApplying(name: scriptName, source: code, replacing: existingID)
                    onApply(saved.source, shouldEnable, saved.id)
                    dismiss()
                }
            } catch {
                guard !Task.isCancelled else { return }
                previewEngine.reset()
                self.error = error.localizedDescription
            }
            running = false
        }
    }
}

#Preview("Receive Script Library") {
    ReceiveScriptEditor(source: ReceiveScriptWorker.defaultSource, enabled: false) { _, _, _ in }
}
