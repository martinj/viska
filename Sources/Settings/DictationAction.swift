import Foundation

struct DictationAction: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var hotkey: HotkeyDescriptor?
    var model: String
    var reasoningEffort: String?
    var prompt: String

    init(
        id: UUID,
        name: String,
        hotkey: HotkeyDescriptor?,
        model: String,
        reasoningEffort: String? = nil,
        prompt: String
    ) {
        self.id = id
        self.name = name
        self.hotkey = hotkey
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.prompt = prompt
    }

    func sanitized() -> DictationAction {
        let sanitizedReasoningEffort = reasoningEffort?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return DictationAction(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            hotkey: hotkey,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            reasoningEffort: sanitizedReasoningEffort?.isEmpty == false ? sanitizedReasoningEffort : nil,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

enum DictationRoute: Equatable, Sendable {
    case plain
    case action(DictationAction)

    var actionName: String? {
        guard case .action(let action) = self else { return nil }
        return action.name
    }

    func identifiesSameShortcut(as other: DictationRoute) -> Bool {
        switch (self, other) {
        case (.plain, .plain):
            true
        case (.action(let lhs), .action(let rhs)):
            lhs.id == rhs.id
        case (.plain, .action), (.action, .plain):
            false
        }
    }
}

enum DictationActionValidationError: LocalizedError, Equatable {
    case missingName
    case missingModel
    case missingPrompt
    case invalidHotkey(HotkeyDescriptor.ValidationError)
    case duplicateID
    case duplicateShortcut

    var errorDescription: String? {
        switch self {
        case .missingName:
            "Enter an action name."
        case .missingModel:
            "Select an available Codex model."
        case .missingPrompt:
            "Enter an action prompt."
        case .invalidHotkey(let error):
            HotkeyDescriptor.errorMessage(for: error)
        case .duplicateID:
            "This action duplicates an existing action."
        case .duplicateShortcut:
            "That shortcut is already used by plain dictation or another action."
        }
    }
}
