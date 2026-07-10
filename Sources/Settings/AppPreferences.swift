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

    init(
        recordingMode: RecordingMode,
        hotkey: HotkeyDescriptor,
        wordReplacements: [WordReplacement]
    ) {
        self.recordingMode = recordingMode
        self.hotkey = hotkey
        self.wordReplacements = wordReplacements
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordingMode = try container.decode(RecordingMode.self, forKey: .recordingMode)
        hotkey = try container.decode(HotkeyDescriptor.self, forKey: .hotkey)
        wordReplacements = try container.decodeIfPresent([WordReplacement].self, forKey: .wordReplacements) ?? []
    }

    static let `default` = AppPreferences(
        recordingMode: .holdToRecord,
        hotkey: HotkeyDescriptor(
            keyCode: UInt32(49),
            modifiers: HotkeyDescriptor.requiredModifierFlags
        ),
        wordReplacements: []
    )
}
