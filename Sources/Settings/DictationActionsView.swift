import AppKit
import SwiftUI

@MainActor
final class DictationActionsEditorModel: ObservableObject {
    @Published private(set) var actions: [DictationAction] = []
    @Published private(set) var models: [CodexModel] = []
    @Published private(set) var isDiscoveringModels = false
    @Published private(set) var discoveryErrorMessage: String?
    @Published var editingID: UUID?
    @Published var name = ""
    @Published var hotkey: HotkeyDescriptor?
    @Published var model = ""
    @Published var reasoningEffort = ""
    @Published var prompt = ""
    @Published var validationMessage: String?

    private let settingsStore: SettingsStore
    private let dictationStore: DictationStore
    private let modelDiscoverer: any CodexModelDiscovering

    init(
        settingsStore: SettingsStore,
        dictationStore: DictationStore,
        modelDiscoverer: any CodexModelDiscovering
    ) {
        self.settingsStore = settingsStore
        self.dictationStore = dictationStore
        self.modelDiscoverer = modelDiscoverer
        actions = settingsStore.preferences.dictationActions
    }

    var isEditing: Bool { editingID != nil }
    var selectedModelIsUnavailable: Bool {
        !model.isEmpty && !models.contains(where: { $0.model == model })
    }
    var selectedCodexModel: CodexModel? {
        models.first(where: { $0.model == model })
    }
    var selectedReasoningEffortIsUnavailable: Bool {
        guard !reasoningEffort.isEmpty, let selectedCodexModel else { return false }
        return !selectedCodexModel.supportedReasoningEfforts.contains {
            $0.reasoningEffort == reasoningEffort
        }
    }
    var defaultReasoningLabel: String {
        guard let effort = selectedCodexModel?.defaultReasoningEffort else {
            return "Model default"
        }
        return "Model default (\(effort.capitalized))"
    }
    var selectedReasoningDescription: String? {
        guard let selectedCodexModel else { return nil }
        let selectedEffort = reasoningEffort.isEmpty
            ? selectedCodexModel.defaultReasoningEffort
            : reasoningEffort
        return selectedCodexModel.supportedReasoningEfforts.first {
            $0.reasoningEffort == selectedEffort
        }?.description
    }

    func prepareForPresentation() async {
        actions = settingsStore.preferences.dictationActions
        await refreshModels()
    }

    func refreshModels() async {
        isDiscoveringModels = true
        discoveryErrorMessage = nil
        defer { isDiscoveringModels = false }
        do {
            models = try await modelDiscoverer.listModels()
        } catch {
            discoveryErrorMessage = "Could not load Codex models: \(error.localizedDescription)"
        }
    }

    func beginAdding() {
        editingID = UUID()
        name = ""
        hotkey = nil
        model = ""
        reasoningEffort = ""
        prompt = ""
        validationMessage = nil
    }

    func beginEditing(_ action: DictationAction) {
        editingID = action.id
        name = action.name
        hotkey = action.hotkey
        model = action.model
        reasoningEffort = action.reasoningEffort ?? ""
        prompt = action.prompt
        validationMessage = nil
    }

    func cancelEditing() {
        editingID = nil
        validationMessage = nil
    }

    func save() {
        guard let editingID else { return }
        guard models.contains(where: { $0.model == model }) else {
            validationMessage = "Select an available Codex model."
            return
        }
        guard !selectedReasoningEffortIsUnavailable else {
            validationMessage = "Select a reasoning effort supported by this model."
            return
        }

        do {
            try dictationStore.saveDictationAction(
                DictationAction(
                    id: editingID,
                    name: name,
                    hotkey: hotkey,
                    model: model,
                    reasoningEffort: reasoningEffort.isEmpty ? nil : reasoningEffort,
                    prompt: prompt
                )
            )
            actions = settingsStore.preferences.dictationActions
            self.editingID = nil
            validationMessage = nil
        } catch {
            validationMessage = dictationStore.userMessage(for: error)
        }
    }

    func delete(_ action: DictationAction) {
        do {
            try dictationStore.deleteDictationAction(id: action.id)
            actions = settingsStore.preferences.dictationActions
            if editingID == action.id { cancelEditing() }
        } catch {
            validationMessage = dictationStore.userMessage(for: error)
        }
    }
}

struct DictationActionsView: View {
    @ObservedObject var model: DictationActionsEditorModel
    @FocusState private var focusedField: EditorField?

    private enum EditorField {
        case name
        case prompt
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            editor
        }
        .frame(minWidth: 740, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.actions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wand.and.sparkles")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)

                    Text("No actions yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("Add an action to transform\nyour dictation with Codex.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.actions) { action in
                            actionRow(action)
                        }
                    }
                    .padding(8)
                }
            }

            Divider()

            Button {
                model.beginAdding()
                focusedField = .name
            } label: {
                Label("Add Action", systemImage: "plus")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(10)
        }
        .frame(width: 230)
        .background(.quaternary.opacity(0.14))
    }

    private func actionRow(_ action: DictationAction) -> some View {
        let isSelected = model.editingID == action.id

        return HStack(spacing: 8) {
            Button {
                focusedField = nil
                model.beginEditing(action)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(action.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(action.hotkey == nil ? Color.secondary : Color.accentColor)
                            .frame(width: 5, height: 5)

                        Text(action.hotkey?.displayString ?? "Unbound")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected {
                Button {
                    model.delete(action)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete action")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
    }

    @ViewBuilder
    private var editor: some View {
        if model.isEditing {
            VStack(spacing: 0) {
                editorHeader

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        basicsSection
                        modelSection
                        promptSection
                        statusMessages
                    }
                    .padding(20)
                }

                Divider()

                editorFooter
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "wand.and.sparkles")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Select an action or add a new one")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Each action records normally, then transforms the transcript with Codex.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        }
    }

    private var editorHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(isEditingExistingAction ? "Edit Action" : "New Action")
                .font(.system(size: 15, weight: .semibold))

            Text("Choose how this dictation starts and how Codex transforms it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var isEditingExistingAction: Bool {
        guard let editingID = model.editingID else { return false }
        return model.actions.contains { $0.id == editingID }
    }

    private var basicsSection: some View {
        editorCard(title: "Action") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Name", detail: "Shown in the action list and processing overlay.")
                    TextField("e.g. Clean up", text: $model.name)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .name)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel(
                        "Shortcut",
                        detail: model.hotkey == nil
                            ? "This action is saved but inactive until you assign a shortcut."
                            : "Use this shortcut anywhere to start the action."
                    )

                    HotkeyRecorderView(
                        currentHotkey: model.hotkey,
                        onHotkeyClear: { model.hotkey = nil }
                    ) { model.hotkey = $0 }
                }
            }
        }
    }

    private var modelSection: some View {
        editorCard(title: "Processing") {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Codex model")
                            .font(.system(size: 12, weight: .medium))

                        if model.isDiscoveringModels {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    Picker("Codex model", selection: $model.model) {
                        Text("Select a model").tag("")
                        if model.selectedModelIsUnavailable {
                            Text("\(model.model) (Unavailable)").tag(model.model)
                        }
                        ForEach(model.models) { codexModel in
                            Text(codexModel.displayName).tag(codexModel.model)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Reasoning")
                        .font(.system(size: 12, weight: .medium))

                    Picker("Reasoning", selection: $model.reasoningEffort) {
                        Text(model.defaultReasoningLabel).tag("")
                        if model.selectedReasoningEffortIsUnavailable {
                            Text("\(model.reasoningEffort.capitalized) (Unavailable)")
                                .tag(model.reasoningEffort)
                        }
                        ForEach(model.selectedCodexModel?.supportedReasoningEfforts ?? []) { effort in
                            Text(effort.reasoningEffort.capitalized)
                                .tag(effort.reasoningEffort)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(model.selectedCodexModel == nil)
                    .frame(maxWidth: .infinity)

                    if let reasoningDescription = model.selectedReasoningDescription {
                        Text(reasoningDescription)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var promptSection: some View {
        editorCard(title: "Prompt") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tell Codex how to transform the transcript.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                TextEditor(text: $model.prompt)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .focused($focusedField, equals: .prompt)
                    .frame(minHeight: 160)
                    .background(
                        Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            }
        }
    }

    @ViewBuilder
    private var statusMessages: some View {
        if let discoveryErrorMessage = model.discoveryErrorMessage {
            messageBanner(discoveryErrorMessage, systemImage: "exclamationmark.triangle", color: .red) {
                Button("Retry") { Task { await model.refreshModels() } }
                    .controlSize(.small)
            }
        } else if model.selectedModelIsUnavailable {
            messageBanner(
                "This saved model is unavailable. Select another model before saving or using the action.",
                systemImage: "exclamationmark.triangle",
                color: .orange
            )
        } else if model.selectedReasoningEffortIsUnavailable {
            messageBanner(
                "This reasoning effort is unavailable for the selected model. Choose another effort before saving.",
                systemImage: "exclamationmark.triangle",
                color: .orange
            )
        }

        if let validationMessage = model.validationMessage {
            messageBanner(validationMessage, systemImage: "xmark.circle", color: .red)
        }
    }

    private var editorFooter: some View {
        HStack(spacing: 8) {
            Spacer()

            Button("Cancel") {
                focusedField = nil
                model.cancelEditing()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.bordered)

            Button("Save") {
                model.save()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func editorCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.72),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func fieldLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .medium))

            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func messageBanner<Actions: View>(
        _ message: String,
        systemImage: String,
        color: Color,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)

            Text(message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            actions()
        }
        .padding(10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func messageBanner(
        _ message: String,
        systemImage: String,
        color: Color
    ) -> some View {
        messageBanner(message, systemImage: systemImage, color: color) {
            EmptyView()
        }
    }
}
