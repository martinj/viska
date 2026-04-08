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
}
