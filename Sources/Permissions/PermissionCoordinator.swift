import ApplicationServices
import AVFoundation
import Foundation

enum PermissionStatus: Equatable {
    case granted
    case denied
    case restricted
    case notDetermined
}

@MainActor
protocol PermissionCoordinating: AnyObject {
    func microphoneStatus() -> PermissionStatus
    func requestMicrophonePermission() async -> Bool
    func accessibilityStatus() -> PermissionStatus
    func requestAccessibilityPermission(prompt: Bool) -> Bool
}

@MainActor
final class PermissionCoordinator: PermissionCoordinating {
    private let microphoneStatusProvider: () -> AVAuthorizationStatus
    private let microphoneRequester: () async -> Bool
    private let accessibilityStatusProvider: () -> Bool
    private let accessibilityRequester: (Bool) -> Bool
    private var hasPromptedForAccessibility = false

    init(
        microphoneStatusProvider: @escaping () -> AVAuthorizationStatus = {
            AVCaptureDevice.authorizationStatus(for: .audio)
        },
        microphoneRequester: @escaping () async -> Bool = {
            await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        },
        accessibilityStatusProvider: @escaping () -> Bool = {
            AXIsProcessTrusted()
        },
        accessibilityRequester: @escaping (Bool) -> Bool = { prompt in
            let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
    ) {
        self.microphoneStatusProvider = microphoneStatusProvider
        self.microphoneRequester = microphoneRequester
        self.accessibilityStatusProvider = accessibilityStatusProvider
        self.accessibilityRequester = accessibilityRequester
    }

    func microphoneStatus() -> PermissionStatus {
        switch microphoneStatusProvider() {
        case .authorized:
            .granted
        case .denied:
            .denied
        case .restricted:
            .restricted
        case .notDetermined:
            .notDetermined
        @unknown default:
            .denied
        }
    }

    func requestMicrophonePermission() async -> Bool {
        await microphoneRequester()
    }

    func accessibilityStatus() -> PermissionStatus {
        accessibilityStatusProvider() ? .granted : .denied
    }

    func requestAccessibilityPermission(prompt: Bool) -> Bool {
        if accessibilityStatusProvider() {
            hasPromptedForAccessibility = false
            return true
        }

        let shouldPrompt = prompt && !hasPromptedForAccessibility
        if shouldPrompt {
            hasPromptedForAccessibility = true
        }

        return accessibilityRequester(shouldPrompt)
    }
}
