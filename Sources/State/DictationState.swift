import Foundation

enum DictationState: Equatable {
    case unavailable(title: String, message: String)
    case failed(title: String, message: String)
    case idle
    case recording(mode: RecordingMode)
    case transcribing
    case inserting

    var statusTitle: String {
        switch self {
        case .unavailable(let title, _):
            title
        case .failed(let title, _):
            title
        case .idle:
            "Ready"
        case .recording:
            "Recording"
        case .transcribing:
            "Transcribing"
        case .inserting:
            "Inserting"
        }
    }

    var detail: String {
        switch self {
        case .unavailable(_, let message):
            message
        case .failed(_, let message):
            message
        case .idle:
            "Global dictation is armed and waiting for the configured shortcut."
        case .recording(let mode):
            switch mode {
            case .holdToRecord:
                "Release the shortcut or press Esc to stop."
            case .toggleToRecord:
                "Press the shortcut again or press Esc to stop."
            }
        case .transcribing:
            "Audio capture has stopped and transcription is in flight."
        case .inserting:
            "The transcript is being inserted into the focused app."
        }
    }
}
