import XCTest
@testable import VoiceCompanion

@MainActor
final class TextInsertionServiceTests: XCTestCase {
    func testWritableFocusedElementReceivesTranscriptAtSelection() async {
        let element = FakeFocusedTextElement(value: "Hello world", selectedRange: NSRange(location: 6, length: 5), isWritable: true)
        let service = makeService(
            accessibilityStatus: .granted,
            element: element,
            pasteResult: false
        )

        let outcome = await service.insert("Martin")

        XCTAssertEqual(outcome, .insertedDirectly)
        XCTAssertEqual(element.value, "Hello Martin")
        XCTAssertEqual(element.selectedRange, NSRange(location: 12, length: 0))
    }

    func testFallsThroughToPasteWhenFocusedElementIsNotWritable() async {
        let element = FakeFocusedTextElement(value: "Hello world", selectedRange: NSRange(location: 6, length: 5), isWritable: false)
        let clipboard = FakeClipboardService()
        let service = makeService(
            accessibilityStatus: .granted,
            element: element,
            clipboard: clipboard,
            pasteResult: true
        )

        let outcome = await service.insert("Martin")

        XCTAssertEqual(outcome, .insertedViaPaste)
        XCTAssertEqual(clipboard.value, "Martin")
    }

    func testFallsBackToClipboardWhenInsertionCannotRun() async {
        let clipboard = FakeClipboardService()
        let service = makeService(
            accessibilityStatus: .denied,
            element: nil,
            clipboard: clipboard,
            accessibilityPromptResult: false,
            pasteResult: false
        )

        let outcome = await service.insert("Martin")

        XCTAssertEqual(outcome, .clipboardFallback(reason: .accessibilityDenied))
        XCTAssertEqual(clipboard.value, "Martin")
    }

    func testRequestsAccessibilityAndPastesWhenPromptSucceeds() async {
        let clipboard = FakeClipboardService()
        let permissions = FakePermissionCoordinator(
            accessibilityStatus: .denied,
            accessibilityPromptResult: true
        )
        let service = makeService(
            permissionCoordinator: permissions,
            element: nil,
            clipboard: clipboard,
            pasteResult: true
        )

        let outcome = await service.insert("Martin")

        XCTAssertEqual(outcome, .insertedViaPaste)
        XCTAssertEqual(clipboard.value, "Martin")
        XCTAssertEqual(permissions.requestedAccessibilityPrompts, [true])
    }

    private func makeService(
        accessibilityStatus: PermissionStatus = .granted,
        element: FakeFocusedTextElement?,
        clipboard: FakeClipboardService = FakeClipboardService(),
        accessibilityPromptResult: Bool? = nil,
        pasteResult: Bool
    ) -> TextInsertionService {
        let permissions = FakePermissionCoordinator(
            accessibilityStatus: accessibilityStatus,
            accessibilityPromptResult: accessibilityPromptResult ?? (accessibilityStatus == .granted)
        )

        return makeService(
            permissionCoordinator: permissions,
            element: element,
            clipboard: clipboard,
            pasteResult: pasteResult
        )
    }

    private func makeService(
        permissionCoordinator: FakePermissionCoordinator,
        element: FakeFocusedTextElement?,
        clipboard: FakeClipboardService = FakeClipboardService(),
        pasteResult: Bool
    ) -> TextInsertionService {
        TextInsertionService(
            permissionCoordinator: permissionCoordinator,
            focusedElementResolver: FakeFocusedElementResolver(element: element),
            clipboardService: clipboard,
            syntheticPasteService: FakeSyntheticPasteService(result: pasteResult)
        )
    }
}

@MainActor
private final class FakeFocusedTextElement: FocusedTextElement {
    let isWritable: Bool
    var value: String?
    var selectedRange: NSRange?

    init(value: String?, selectedRange: NSRange?, isWritable: Bool) {
        self.value = value
        self.selectedRange = selectedRange
        self.isWritable = isWritable
    }
}

private final class FakeFocusedElementResolver: FocusedElementResolving {
    let element: FakeFocusedTextElement?

    init(element: FakeFocusedTextElement?) {
        self.element = element
    }

    func focusedElement() -> (any FocusedTextElement)? {
        element
    }
}

@MainActor
private final class FakeClipboardService: ClipboardControlling {
    private(set) var value: String?

    func stringContents() -> String? {
        value
    }

    func setString(_ string: String) {
        value = string
    }
}

@MainActor
private final class FakeSyntheticPasteService: SyntheticPasting {
    let result: Bool

    init(result: Bool) {
        self.result = result
    }

    func pasteClipboardContents() -> Bool {
        result
    }
}

@MainActor
private final class FakePermissionCoordinator: PermissionCoordinating {
    private var accessibility: PermissionStatus
    private let accessibilityPromptResult: Bool
    private(set) var requestedAccessibilityPrompts: [Bool] = []

    init(accessibilityStatus: PermissionStatus, accessibilityPromptResult: Bool) {
        self.accessibility = accessibilityStatus
        self.accessibilityPromptResult = accessibilityPromptResult
    }

    func microphoneStatus() -> PermissionStatus {
        .granted
    }

    func requestMicrophonePermission() async -> Bool {
        true
    }

    func accessibilityStatus() -> PermissionStatus {
        accessibility
    }

    func requestAccessibilityPermission(prompt: Bool) -> Bool {
        requestedAccessibilityPrompts.append(prompt)

        if accessibilityPromptResult {
            accessibility = .granted
            return true
        }

        return false
    }
}
