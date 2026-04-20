import ApplicationServices
import AppKit
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
    func openMicrophoneSettings()
    func accessibilityStatus() -> PermissionStatus
    func requestAccessibilityPermission(prompt: Bool) -> Bool
    func openAccessibilitySettings()
}

@MainActor
final class PermissionCoordinator: PermissionCoordinating {
    private let microphoneStatusProvider: () -> AVAuthorizationStatus
    private let microphoneRequester: () async -> Bool
    private let accessibilityStatusProvider: () -> Bool
    private let accessibilityRequester: (Bool) -> Bool
    private let privacySettingsOpener: (URL) -> Void
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
        },
        privacySettingsOpener: @escaping (URL) -> Void = { url in
            NSWorkspace.shared.open(url)
        }
    ) {
        self.microphoneStatusProvider = microphoneStatusProvider
        self.microphoneRequester = microphoneRequester
        self.accessibilityStatusProvider = accessibilityStatusProvider
        self.accessibilityRequester = accessibilityRequester
        self.privacySettingsOpener = privacySettingsOpener
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

    func openMicrophoneSettings() {
        openPrivacyPane("Privacy_Microphone")
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

    func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }

        privacySettingsOpener(url)
    }
}
