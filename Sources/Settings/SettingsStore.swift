import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var preferences: AppPreferences

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let key = "viska.preferences"

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

    func updateDictationActions(_ dictationActions: [DictationAction]) throws {
        let updated = try preferences.sanitizedAndValidated(actions: dictationActions)
        guard preferences != updated else { return }

        preferences = updated
        persist()
    }

    func updateWordReplacements(_ wordReplacements: [WordReplacement]) {
        let sanitizedWordReplacements = Self.sanitize(wordReplacements)
        guard preferences.wordReplacements != sanitizedWordReplacements else { return }

        preferences.wordReplacements = sanitizedWordReplacements
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

    private static func sanitize(_ wordReplacements: [WordReplacement]) -> [WordReplacement] {
        wordReplacements.compactMap { rule in
            let trigger = rule.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty else { return nil }

            return WordReplacement(
                id: rule.id,
                trigger: trigger,
                replacement: rule.replacement
            )
        }
    }
}
