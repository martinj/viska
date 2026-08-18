import Foundation

enum RecordingMode: String, Codable, CaseIterable, Identifiable {
    case holdToRecord
    case toggleToRecord

    var id: String { rawValue }

    var title: String {
        switch self {
        case .holdToRecord:
            "Hold"
        case .toggleToRecord:
            "Toggle"
        }
    }
}

struct AppPreferences: Codable, Equatable {
    var recordingMode: RecordingMode
    var hotkey: HotkeyDescriptor
    var wordReplacements: [WordReplacement]
    var dictationActions: [DictationAction]

    init(
        recordingMode: RecordingMode,
        hotkey: HotkeyDescriptor,
        wordReplacements: [WordReplacement],
        dictationActions: [DictationAction] = []
    ) {
        self.recordingMode = recordingMode
        self.hotkey = hotkey
        self.wordReplacements = wordReplacements
        self.dictationActions = dictationActions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordingMode = try container.decode(RecordingMode.self, forKey: .recordingMode)
        hotkey = try container.decode(HotkeyDescriptor.self, forKey: .hotkey)
        wordReplacements = try container.decodeIfPresent([WordReplacement].self, forKey: .wordReplacements) ?? []
        dictationActions = try container.decodeIfPresent([DictationAction].self, forKey: .dictationActions) ?? []

        do {
            try validateDictationActions()
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: error.localizedDescription)
            )
        }
    }

    func sanitizedAndValidated(actions: [DictationAction]) throws -> AppPreferences {
        var updated = self
        updated.dictationActions = actions.map { $0.sanitized() }
        try updated.validateDictationActions()
        return updated
    }

    func validateDictationActions() throws {
        var ids = Set<UUID>()
        var shortcuts: Set<HotkeyDescriptor> = [hotkey]

        for action in dictationActions {
            let sanitized = action.sanitized()
            guard !sanitized.name.isEmpty else { throw DictationActionValidationError.missingName }
            guard !sanitized.model.isEmpty else { throw DictationActionValidationError.missingModel }
            guard !sanitized.prompt.isEmpty else { throw DictationActionValidationError.missingPrompt }

            guard ids.insert(sanitized.id).inserted else {
                throw DictationActionValidationError.duplicateID
            }

            if let hotkey = sanitized.hotkey {
                do {
                    try hotkey.validate()
                } catch let error as HotkeyDescriptor.ValidationError {
                    throw DictationActionValidationError.invalidHotkey(error)
                }

                guard shortcuts.insert(hotkey).inserted else {
                    throw DictationActionValidationError.duplicateShortcut
                }
            }
        }
    }

    static let `default` = AppPreferences(
        recordingMode: .holdToRecord,
        hotkey: HotkeyDescriptor(
            keyCode: UInt32(49),
            modifiers: HotkeyDescriptor.requiredModifierFlags
        ),
        wordReplacements: [],
        dictationActions: []
    )
}
