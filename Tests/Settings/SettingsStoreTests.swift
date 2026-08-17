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
        XCTAssertEqual(store.preferences.dictationActions, [])
    }

    func testMultipleDictationActionsRoundTripWithTrimmedFields() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let firstStore = SettingsStore(userDefaults: defaults)
        let actions = [
            makeAction(
                name: "  Clean up  ",
                keyCode: 1,
                model: "  gpt-5.6-luna ",
                reasoningEffort: "  high  ",
                prompt: "  Remove filler words.  "
            ),
            makeAction(name: "Translate", keyCode: 2, model: "gpt-5.6-terra", prompt: "Translate to English."),
        ]

        try firstStore.updateDictationActions(actions)
        let secondStore = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(secondStore.preferences.dictationActions[0].name, "Clean up")
        XCTAssertEqual(secondStore.preferences.dictationActions[0].model, "gpt-5.6-luna")
        XCTAssertEqual(secondStore.preferences.dictationActions[0].reasoningEffort, "high")
        XCTAssertEqual(secondStore.preferences.dictationActions[0].prompt, "Remove filler words.")
        XCTAssertEqual(secondStore.preferences.dictationActions[1], actions[1])
    }

    func testSavedActionWithoutReasoningEffortUsesModelDefault() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let actionID = UUID()
        let legacyPreferences: [String: Any] = [
            "recordingMode": RecordingMode.holdToRecord.rawValue,
            "hotkey": [
                "keyCode": UInt32(49),
                "modifiers": HotkeyDescriptor.requiredModifierFlags,
            ],
            "wordReplacements": [],
            "dictationActions": [[
                "id": actionID.uuidString,
                "name": "Clean up",
                "hotkey": [
                    "keyCode": UInt32(1),
                    "modifiers": HotkeyDescriptor.requiredModifierFlags,
                ],
                "model": "gpt-5.6-luna",
                "prompt": "Remove filler words.",
            ]],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: legacyPreferences), forKey: "viska.preferences")

        let store = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.preferences.dictationActions.count, 1)
        XCTAssertEqual(store.preferences.dictationActions[0].id, actionID)
        XCTAssertNil(store.preferences.dictationActions[0].reasoningEffort)
    }

    func testUnboundDictationActionPersistsAcrossInstances() throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let action = DictationAction(
            id: UUID(),
            name: "Inactive action",
            hotkey: nil,
            model: "gpt-5.6-luna",
            prompt: "Transform the text."
        )

        let firstStore = SettingsStore(userDefaults: defaults)
        try firstStore.updateDictationActions([action])
        let secondStore = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(secondStore.preferences.dictationActions, [action])
        XCTAssertNil(secondStore.preferences.dictationActions[0].hotkey)
    }

    func testDictationActionValidationRejectsMissingFields() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = SettingsStore(userDefaults: defaults)

        for action in [
            makeAction(name: " ", keyCode: 1),
            makeAction(name: "Action", keyCode: 1, model: " "),
            makeAction(name: "Action", keyCode: 1, prompt: "\n"),
        ] {
            XCTAssertThrowsError(try store.updateDictationActions([action]))
        }
        XCTAssertEqual(store.preferences.dictationActions, [])
    }

    func testDictationActionValidationRejectsDuplicateIDsAndShortcuts() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = SettingsStore(userDefaults: defaults)
        let first = makeAction(name: "First", keyCode: 1)
        var duplicateID = makeAction(name: "Second", keyCode: 2)
        duplicateID.id = first.id
        let duplicateShortcut = makeAction(name: "Second", keyCode: 1)
        let plainShortcut = DictationAction(
            id: UUID(),
            name: "Plain conflict",
            hotkey: store.preferences.hotkey,
            model: "gpt-5.6-luna",
            prompt: "Transform."
        )

        XCTAssertThrowsError(try store.updateDictationActions([first, duplicateID]))
        XCTAssertThrowsError(try store.updateDictationActions([first, duplicateShortcut]))
        XCTAssertThrowsError(try store.updateDictationActions([plainShortcut]))
        XCTAssertEqual(store.preferences.dictationActions, [])
    }

    private func makeAction(
        name: String,
        keyCode: UInt32,
        model: String = "gpt-5.6-luna",
        reasoningEffort: String? = nil,
        prompt: String = "Transform the text."
    ) -> DictationAction {
        DictationAction(
            id: UUID(),
            name: name,
            hotkey: HotkeyDescriptor(keyCode: keyCode, modifiers: HotkeyDescriptor.requiredModifierFlags),
            model: model,
            reasoningEffort: reasoningEffort,
            prompt: prompt
        )
    }
}
