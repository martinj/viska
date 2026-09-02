import Foundation

enum TextInsertionOutcome: Equatable {
    case insertedDirectly
    case insertedViaPaste
    case clipboardFallback(reason: ClipboardFallbackReason)
}

enum ClipboardFallbackReason: Equatable {
    case accessibilityDenied
    case frontmostApplicationChanged
    case pasteFailed
}

@MainActor
struct TextInsertionDestination {
    let focusedElement: (any FocusedTextElement)?
    let frontmostApplicationPID: pid_t?
}

@MainActor
protocol TextInserting: AnyObject {
    func captureDestination() -> TextInsertionDestination
    func insert(_ text: String, at destination: TextInsertionDestination) async -> TextInsertionOutcome
}

@MainActor
final class TextInsertionService: TextInserting {
    private let permissionCoordinator: any PermissionCoordinating
    private let focusedElementResolver: any FocusedElementResolving
    private let frontmostApplicationPIDProvider: any FrontmostApplicationPIDProviding
    private let clipboardService: any ClipboardControlling
    private let syntheticPasteService: any SyntheticPasting

    init(
        permissionCoordinator: any PermissionCoordinating,
        focusedElementResolver: any FocusedElementResolving,
        frontmostApplicationPIDProvider: any FrontmostApplicationPIDProviding = WorkspaceFrontmostApplicationPIDProvider(),
        clipboardService: any ClipboardControlling,
        syntheticPasteService: any SyntheticPasting
    ) {
        self.permissionCoordinator = permissionCoordinator
        self.focusedElementResolver = focusedElementResolver
        self.frontmostApplicationPIDProvider = frontmostApplicationPIDProvider
        self.clipboardService = clipboardService
        self.syntheticPasteService = syntheticPasteService
    }

    func captureDestination() -> TextInsertionDestination {
        let pidBeforeResolvingElement = frontmostApplicationPIDProvider.frontmostApplicationPID()
        let focusedElement = focusedElementResolver.focusedElement()
        let pidAfterResolvingElement = frontmostApplicationPIDProvider.frontmostApplicationPID()

        return TextInsertionDestination(
            focusedElement: focusedElement,
            frontmostApplicationPID: pidBeforeResolvingElement == pidAfterResolvingElement
                ? pidBeforeResolvingElement
                : nil
        )
    }

    func insert(_ text: String, at destination: TextInsertionDestination) async -> TextInsertionOutcome {
        let accessibilityGranted = ensureAccessibilityPermission()

        if accessibilityGranted,
           let focusedElement = destination.focusedElement,
           insertDirectly(text, into: focusedElement) {
            return .insertedDirectly
        }

        clipboardService.setString(text)

        guard accessibilityGranted else {
            return .clipboardFallback(reason: .accessibilityDenied)
        }

        guard let capturedPID = destination.frontmostApplicationPID,
              frontmostApplicationPIDProvider.frontmostApplicationPID() == capturedPID else {
            return .clipboardFallback(reason: .frontmostApplicationChanged)
        }

        if syntheticPasteService.pasteClipboardContents() {
            return .insertedViaPaste
        }

        return .clipboardFallback(reason: .pasteFailed)
    }

    private func insertDirectly(_ text: String, into focusedElement: any FocusedTextElement) -> Bool {
        guard focusedElement.isWritable else {
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
