import AVFoundation
import XCTest
@testable import Viska

@MainActor
final class PermissionCoordinatorTests: XCTestCase {
    func testMicrophoneStatusMapsAuthorizationStates() {
        let coordinator = PermissionCoordinator(
            microphoneStatusProvider: { .denied },
            microphoneRequester: { false },
            accessibilityStatusProvider: { false },
            accessibilityRequester: { _ in false }
        )

        XCTAssertEqual(coordinator.microphoneStatus(), .denied)
    }

    func testAccessibilityPromptDelegatesToProvider() {
        var prompted = false
        let coordinator = PermissionCoordinator(
            microphoneStatusProvider: { .authorized },
            microphoneRequester: { true },
            accessibilityStatusProvider: { false },
            accessibilityRequester: { prompt in
                prompted = prompt
                return true
            }
        )

        XCTAssertTrue(coordinator.requestAccessibilityPermission(prompt: true))
        XCTAssertTrue(prompted)
    }

    func testAccessibilityPromptRunsOnlyOnceWhileStillDenied() {
        var prompts: [Bool] = []
        let coordinator = PermissionCoordinator(
            microphoneStatusProvider: { .authorized },
            microphoneRequester: { true },
            accessibilityStatusProvider: { false },
            accessibilityRequester: { prompt in
                prompts.append(prompt)
                return false
            }
        )

        XCTAssertFalse(coordinator.requestAccessibilityPermission(prompt: true))
        XCTAssertFalse(coordinator.requestAccessibilityPermission(prompt: true))
        XCTAssertEqual(prompts, [true, false])
    }
}
