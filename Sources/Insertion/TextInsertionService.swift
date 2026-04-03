import Foundation

enum TextInsertionOutcome: Equatable {
    case insertedDirectly
    case insertedViaPaste
    case clipboardFallback(reason: ClipboardFallbackReason)
}

enum ClipboardFallbackReason: Equatable {
    case accessibilityDenied
    case pasteFailed
}

@MainActor
protocol TextInserting: AnyObject {
    func insert(_ text: String) async -> TextInsertionOutcome
}

@MainActor
final class TextInsertionService: TextInserting {
    private let permissionCoordinator: any PermissionCoordinating
    private let focusedElementResolver: any FocusedElementResolving
    private let clipboardService: any ClipboardControlling
    private let syntheticPasteService: any SyntheticPasting

    init(
        permissionCoordinator: any PermissionCoordinating,
        focusedElementResolver: any FocusedElementResolving,
        clipboardService: any ClipboardControlling,
        syntheticPasteService: any SyntheticPasting
    ) {
        self.permissionCoordinator = permissionCoordinator
        self.focusedElementResolver = focusedElementResolver
        self.clipboardService = clipboardService
        self.syntheticPasteService = syntheticPasteService
    }

    func insert(_ text: String) async -> TextInsertionOutcome {
        let accessibilityGranted = ensureAccessibilityPermission()

        if accessibilityGranted, insertDirectly(text) {
            return .insertedDirectly
        }

        clipboardService.setString(text)

        if accessibilityGranted,
           syntheticPasteService.pasteClipboardContents() {
            return .insertedViaPaste
        }

        return .clipboardFallback(
            reason: accessibilityGranted ? .pasteFailed : .accessibilityDenied
        )
    }

    private func insertDirectly(_ text: String) -> Bool {
        guard let focusedElement = focusedElementResolver.focusedElement(),
              focusedElement.isWritable else {
            return false
        }

        let existingValue = focusedElement.value ?? ""
        let insertionRange = focusedElement.selectedRange ?? NSRange(location: existingValue.utf16.count, length: 0)

        guard let swiftRange = Range(insertionRange, in: existingValue) else {
            return false
        }

        let updatedValue = existingValue.replacingCharacters(in: swiftRange, with: text)
        guard focusedElement.setValue(updatedValue) else {
            return false
        }

        _ = focusedElement.setSelectedRange(NSRange(location: insertionRange.location + text.utf16.count, length: 0))
        return true
    }

    private func ensureAccessibilityPermission() -> Bool {
        if permissionCoordinator.accessibilityStatus() == .granted {
            return true
        }

        return permissionCoordinator.requestAccessibilityPermission(prompt: true)
    }
}
