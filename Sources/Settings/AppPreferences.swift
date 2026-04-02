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

    static let `default` = AppPreferences(
        recordingMode: .holdToRecord,
        hotkey: HotkeyDescriptor(
            keyCode: UInt32(49),
            modifiers: HotkeyDescriptor.requiredModifierFlags
        )
    )
}
