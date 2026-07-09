import XCTest
@testable import Viska

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testDefaultsToHoldModeOnFirstLaunch() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let store = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.preferences, .default)
    }

    func testRecordingModePersistsAcrossInstances() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let firstStore = SettingsStore(userDefaults: defaults)
        firstStore.updateRecordingMode(.toggleToRecord)

        let secondStore = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(secondStore.preferences.recordingMode, .toggleToRecord)
    }

    func testWordReplacementsPersistAcrossInstances() {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let replacements = [
            WordReplacement(id: UUID(), trigger: "  paper trail  ", replacement: "papertrail"),
            WordReplacement(id: UUID(), trigger: " \n\t ", replacement: "ignored"),
            WordReplacement(id: UUID(), trigger: "remove me", replacement: ""),
        ]
        let expectedReplacements = [
            WordReplacement(id: replacements[0].id, trigger: "paper trail", replacement: "papertrail"),
            WordReplacement(id: replacements[2].id, trigger: "remove me", replacement: ""),
        ]

        let firstStore = SettingsStore(userDefaults: defaults)
        firstStore.updateWordReplacements(replacements)

        let secondStore = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(secondStore.preferences.wordReplacements, expectedReplacements)
    }

    func testLegacyPreferencesDecodeWithoutWordReplacements() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let legacyPreferences: [String: Any] = [
            "recordingMode": RecordingMode.toggleToRecord.rawValue,
            "hotkey": [
                "keyCode": UInt32(49),
                "modifiers": HotkeyDescriptor.requiredModifierFlags,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyPreferences)
        defaults.set(data, forKey: "viska.preferences")

        let store = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.preferences.recordingMode, .toggleToRecord)
        XCTAssertEqual(store.preferences.wordReplacements, [])
    }
}
