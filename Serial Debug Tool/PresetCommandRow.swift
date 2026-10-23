import SwiftUI

@MainActor
struct PresetCommandRow: View {
    let preset: CommandPreset
    let canSend: Bool
    let onSave: (CommandPreset) -> Bool
    let onSend: () -> Void
    let onDelete: () -> Void
    var isRepeating = false
    var canRepeat = false
    var onToggleRepeating: () -> Void = {}
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isEditing = false
    @State private var confirmingDeletion = false
    @State private var draft = CommandPreset(name: "", text: "", isHex: false, ending: .crlf, encoding: .utf8)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isEditing {
                editor
                    .transition(.opacity)
            } else {
                summary
                    .transition(.opacity)
            }
        }
        .modifier(PresetCardStyle(isEditing: isEditing))
        .contextMenu {
            if !isEditing {
                Button(AppText.edit) { beginEditing() }
            }
            Button(AppText.delete, role: .destructive) { confirmingDeletion = true }
        }
        .alert(AppText.deletePresetTitle, isPresented: $confirmingDeletion) {
            Button(AppText.cancel, role: .cancel) {}
            Button(AppText.delete, role: .destructive) { onDelete() }
        } message: {
            Text(AppText.deletePresetConfirmation(preset.name))
        }
    }

    private var summary: some View {
        ViewThatFits(in: .horizontal) {
            summaryRow(compact: false)
            summaryRow(compact: true)
        }
    }

    private func summaryRow(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Text(preset.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: compact ? 88 : 140, alignment: .leading)
                .help(preset.name)

            Divider().frame(height: 14)

            Text(preset.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: compact ? 40 : 80, maxWidth: .infinity, alignment: .leading)
                .help("\(preset.isHex ? "HEX" : preset.encoding.rawValue) · \(preset.ending.title)\n\(preset.text)")

            HStack(spacing: compact ? 6 : 8) {
                if compact {
                    editButton.labelStyle(.iconOnly)
                } else {
                    editButton
                }
                repeatButton
                sendButton
                Button(role: .destructive, action: { confirmingDeletion = true }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(AppText.deletePreset(preset.name))
                .accessibilityLabel(AppText.deletePreset(preset.name))
            }
            .controlSize(compact ? .small : .regular)
            .font(compact ? .caption : .body)
            .fixedSize()
        }
    }

    private var editButton: some View {
        Button { beginEditing() } label: {
            Label(AppText.edit, systemImage: "pencil")
        }
        .help(AppText.edit)
    }

    private var repeatButton: some View {
        Button(action: { onToggleRepeating() }) {
            Label(
                isRepeating ? AppText.stopRepeating : AppText.repeatSend,
                systemImage: isRepeating ? "stop.circle.fill" : "timer"
            )
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .disabled(!isRepeating && !canRepeat)
        .help(isRepeating ? AppText.stopPresetRepeat(preset.name) : AppText.repeatPreset(preset.name))
        .accessibilityLabel(isRepeating ? AppText.stopPresetRepeat(preset.name) : AppText.repeatPreset(preset.name))
    }

    private var sendButton: some View {
        Button(action: { onSend() }) {
            Label(AppText.sendOnce, systemImage: "paperplane")
        }
        .labelStyle(.titleAndIcon)
        .disabled(!canSend)
        .help(AppText.sendOnce)
    }

    private var editor: some View {
        PresetCommandEditor(draft: $draft, onCancel: { setEditing(false) }, onSave: { saveChanges() })
    }

    private func beginEditing() {
        // Work on a copy so cancelling never changes the saved command or the send-panel draft.
        draft = preset
        setEditing(true)
    }

    private func saveChanges() {
        guard onSave(draft) else { return }
        setEditing(false)
    }

    private func setEditing(_ editing: Bool) {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.26, bounce: 0)) {
            isEditing = editing
            onEditingChanged(editing)
        }
    }
}

private struct PresetCardStyle: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    let isEditing: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, isEditing ? 12 : 8)
            .padding(.vertical, isEditing ? 12 : 7)
            .background {
                if isEditing {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(.quaternary.opacity(0.45))
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.accentColor.opacity(0.09))
                }
            }
            .overlay(alignment: .bottom) {
                if !isEditing { Divider() }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(
                        Color.accentColor.opacity(isEditing ? (contrast == .increased ? 1 : 0.7) : 0),
                        lineWidth: 1.5
                    )
            }
    }
}

@MainActor
private struct PresetCommandEditor: View {
    @Binding var draft: CommandPreset
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label {
                    Text(AppText.editingPreset).fontWeight(.semibold)
                } icon: {
                    Image(systemName: "pencil.circle.fill").foregroundStyle(.tint)
                }
                Spacer()
                Text(AppText.saveShortcut).foregroundStyle(.secondary)
            }
            .font(.caption)

            HStack {
                TextField(AppText.presetName, text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(AppText.presetName)
                Button(AppText.cancel) { onCancel() }
                Button(AppText.save) { onSave() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }

            HStack {
                Toggle(AppText.hexInput, isOn: $draft.isHex)
                    .toggleStyle(.checkbox)
                Spacer()
                Picker(AppText.encoding, selection: $draft.encoding) {
                    ForEach(TextEncoding.allCases, id: \.self) { encoding in
                        Text(encoding.rawValue).tag(encoding)
                    }
                }
                .frame(width: 150)
                Picker(AppText.compactLineEnding, selection: $draft.ending) {
                    ForEach(LineEnding.allCases, id: \.self) { ending in
                        Text(ending.title).tag(ending)
                    }
                }
                .frame(width: 125)
            }
            .font(.caption)
            .pickerStyle(.menu)

            SendTextEditor(
                text: $draft.text,
                placeholder: draft.isHex ? AppText.hexPlaceholder : AppText.presetPlaceholder,
                onSend: { if canSave { onSave() } }
            )
            .frame(height: 65)
            .background(.background, in: RoundedRectangle(cornerRadius: 7))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
            .help(AppText.savePresetShortcut)
        }
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.text.isEmpty
    }
}

#Preview("预设命令 · 行内编辑") {
    @Previewable @State var draft = CommandPreset(
        name: "读取设备状态",
        text: "AA 01 02 FF",
        isHex: true,
        ending: .none,
        encoding: .utf8
    )
    VStack(spacing: 8) {
        PresetCommandEditor(draft: $draft, onCancel: {}, onSave: {})
            .modifier(PresetCardStyle(isEditing: true))
        PresetCommandRow(
            preset: CommandPreset(name: "读取版本", text: "AT+VERSION", isHex: false, ending: .crlf, encoding: .utf8),
            canSend: false,
            onSave: { _ in true },
            onSend: {},
            onDelete: {}
        )
    }
    .padding(12)
    .frame(width: 430)
}

#Preview("预设命令 · 单行列表") {
    @Previewable @State var presets = [
        CommandPreset(name: "切换空闲状态", text: "$ACZS,IDLE*hh", isHex: false, ending: .crlf, encoding: .utf8),
        CommandPreset(name: "读取设备的详细运行状态", text: "AT+STATUS=DEVICE,DETAIL,ALL", isHex: false, ending: .none, encoding: .utf8)
    ]
    VStack(spacing: 0) {
        ForEach(presets) { preset in
            PresetCommandRow(
                preset: preset,
                canSend: true,
                onSave: { _ in true },
                onSend: {},
                onDelete: { presets.removeAll { $0.id == preset.id } }
            )
        }
    }
    .padding(12)
    .frame(width: 430)
}

#Preview("预设命令 · 编辑交互") {
    @Previewable @State var preset = CommandPreset(
        name: "读取设备状态", text: "AA 01 02 FF", isHex: true, ending: .none, encoding: .utf8
    )
    PresetCommandRow(
        preset: preset,
        canSend: false,
        onSave: { preset = $0; return true },
        onSend: {},
        onDelete: {}
    )
    .padding(12)
    .frame(width: 430)
}

#Preview("预设命令 · 定时发送") {
    @Previewable @State var running = true
    PresetCommandRow(
        preset: CommandPreset(name: "读取状态", text: "AT+STATUS", isHex: false, ending: .crlf, encoding: .utf8),
        canSend: !running,
        onSave: { _ in true },
        onSend: {},
        onDelete: {},
        isRepeating: running,
        canRepeat: !running,
        onToggleRepeating: { running.toggle() }
    )
    .padding(12)
    .frame(width: 430)
}
