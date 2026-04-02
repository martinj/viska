import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var preferences: AppPreferences

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let key = "voice-companion.preferences"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        if let data = userDefaults.data(forKey: key),
           let decoded = try? decoder.decode(AppPreferences.self, from: data) {
            preferences = decoded
        } else {
            preferences = .default
        }
    }

    func updateRecordingMode(_ recordingMode: RecordingMode) {
        preferences.recordingMode = recordingMode
        persist()
    }

    func updateHotkey(_ hotkey: HotkeyDescriptor) {
        preferences.hotkey = hotkey
        persist()
    }

    func updatePreferences(_ preferences: AppPreferences) {
        self.preferences = preferences
        persist()
    }

    private func persist() {
        guard let data = try? encoder.encode(preferences) else { return }
        userDefaults.set(data, forKey: key)
    }
}
