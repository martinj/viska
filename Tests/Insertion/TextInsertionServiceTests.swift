import XCTest
@testable import Viska

@MainActor
final class TextInsertionServiceTests: XCTestCase {
    func testWritableFocusedElementReceivesTranscriptAtSelection() async {
        let element = FakeFocusedTextElement(value: "Hello world", selectedRange: NSRange(location: 6, length: 5), isWritable: true)
        let service = makeService(
            accessibilityStatus: .granted,
            element: element,
            pasteResult: false
        )

        let destination = service.captureDestination()
        let outcome = await service.insert("Martin", at: destination)

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

        let destination = service.captureDestination()
        let outcome = await service.insert("Martin", at: destination)

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

        let destination = service.captureDestination()
        let outcome = await service.insert("Martin", at: destination)

        XCTAssertEqual(outcome, .clipboardFallback(reason: .accessibilityDenied))
        XCTAssertEqual(clipboard.value, "Martin")
    }

    func testRequestsAccessibilityAndPastesWhenPromptSucceeds() async {
        let clipboard = FakeClipboardService()
        let element = FakeFocusedTextElement(
            value: nil,
            selectedRange: nil,
            isWritable: false
        )
        let permissions = FakePermissionCoordinator(
            accessibilityStatus: .denied,
            accessibilityPromptResult: true
        )
        let service = makeService(
            permissionCoordinator: permissions,
            element: element,
            clipboard: clipboard,
            pasteResult: true
        )

        let destination = service.captureDestination()
        let outcome = await service.insert("Martin", at: destination)

        XCTAssertEqual(outcome, .insertedViaPaste)
        XCTAssertEqual(clipboard.value, "Martin")
        XCTAssertEqual(permissions.requestedAccessibilityPrompts, [true])
    }

    func testFocusChangeWithinCapturedAppPastesIntoCurrentFocus() async {
        let capturedElement = FakeFocusedTextElement(
            value: nil,
            selectedRange: nil,
            isWritable: false
        )
        let currentElement = FakeFocusedTextElement(
            value: nil,
            selectedRange: nil,
            isWritable: false
        )
        let resolver = FakeFocusedElementResolver(element: capturedElement)
        let clipboard = FakeClipboardService()
        let pasteService = FakeSyntheticPasteService(result: true)
        let service = makeService(
            permissionCoordinator: FakePermissionCoordinator(
                accessibilityStatus: .granted,
                accessibilityPromptResult: true
            ),
            resolver: resolver,
            clipboard: clipboard,
            pasteService: pasteService,
            pidProvider: FakeFrontmostApplicationPIDProvider(pid: 42)
        )

        let destination = service.captureDestination()
        resolver.element = currentElement
        let outcome = await service.insert("Martin", at: destination)

        XCTAssertEqual(outcome, .insertedViaPaste)
        XCTAssertEqual(clipboard.value, "Martin")
        XCTAssertEqual(pasteService.pasteCallCount, 1)
    }

    func testDirectInsertFailureFallsThroughToPaste() async {
        let element = FakeFocusedTextElement(
            value: "Hello world",
            selectedRange: NSRange(location: 6, length: 5),
            isWritable: true,
            setValueSucceeds: false
        )
        let clipboard = FakeClipboardService()
        let service = makeService(
            accessibilityStatus: .granted,
            element: element,
            clipboard: clipboard,
            pasteResult: true
        )

        let destination = service.captureDestination()
        let outcome = await service.insert("Martin", at: destination)

        XCTAssertEqual(outcome, .insertedViaPaste)
        XCTAssertEqual(clipboard.value, "Martin")
        XCTAssertEqual(element.value, "Hello world")
    }

    func testCapturedElementReceivesTranscriptAfterFocusChanges() async {
        let capturedElement = FakeFocusedTextElement(
            value: "Original",
            selectedRange: NSRange(location: 8, length: 0),
            isWritable: true
        )
        let newlyFocusedElement = FakeFocusedTextElement(
            value: "Other",
            selectedRange: NSRange(location: 5, length: 0),
            isWritable: true
        )
        let resolver = FakeFocusedElementResolver(element: capturedElement)
        let clipboard = FakeClipboardService()
        let pasteService = FakeSyntheticPasteService(result: true)
        let pidProvider = FakeFrontmostApplicationPIDProvider(pid: 42)
        let service = makeService(
            permissionCoordinator: FakePermissionCoordinator(
                accessibilityStatus: .granted,
                accessibilityPromptResult: true
            ),
            resolver: resolver,
            clipboard: clipboard,
            pasteService: pasteService,
            pidProvider: pidProvider
        )

        let destination = service.captureDestination()
        resolver.element = newlyFocusedElement
        pidProvider.pid = 84
        let outcome = await service.insert(" transcript", at: destination)

        XCTAssertEqual(outcome, .insertedDirectly)
        XCTAssertEqual(capturedElement.value, "Original transcript")
        XCTAssertEqual(newlyFocusedElement.value, "Other")
        XCTAssertNil(clipboard.value)
        XCTAssertEqual(pasteService.pasteCallCount, 0)
    }

    func testAppChangeFallsBackToClipboardWithoutSyntheticPaste() async {
        let clipboard = FakeClipboardService()
        let pasteService = FakeSyntheticPasteService(result: true)
        let pidProvider = FakeFrontmostApplicationPIDProvider(pid: 42)
        let service = makeService(
            element: nil,
            clipboard: clipboard,
            pasteService: pasteService,
            pidProvider: pidProvider
        )

        let destination = service.captureDestination()
        pidProvider.pid = 84
        let outcome = await service.insert("Martin", at: destination)

        XCTAssertEqual(outcome, .clipboardFallback(reason: .frontmostApplicationChanged))
        XCTAssertEqual(clipboard.value, "Martin")
        XCTAssertEqual(pasteService.pasteCallCount, 0)
    }

    func testAppChangeDuringCaptureMakesPasteFallbackUnsafe() async {
        let clipboard = FakeClipboardService()
        let pasteService = FakeSyntheticPasteService(result: true)
        let pidProvider = FakeFrontmostApplicationPIDProvider(pid: 42)
        let resolver = FakeFocusedElementResolver(element: nil) {
            pidProvider.pid = 84
        }
        let service = makeService(
            permissionCoordinator: FakePermissionCoordinator(
                accessibilityStatus: .granted,
                accessibilityPromptResult: true
            ),
            resolver: resolver,
            clipboard: clipboard,
            pasteService: pasteService,
            pidProvider: pidProvider
        )

        let destination = service.captureDestination()
        pidProvider.pid = 42
        let outcome = await service.insert("Martin", at: destination)

        XCTAssertEqual(outcome, .clipboardFallback(reason: .frontmostApplicationChanged))
        XCTAssertEqual(clipboard.value, "Martin")
        XCTAssertEqual(pasteService.pasteCallCount, 0)
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
        makeService(
            permissionCoordinator: permissionCoordinator,
            resolver: FakeFocusedElementResolver(element: element),
            clipboard: clipboard,
            pasteService: FakeSyntheticPasteService(result: pasteResult),
            pidProvider: FakeFrontmostApplicationPIDProvider(pid: 42)
        )
    }

    private func makeService(
        accessibilityStatus: PermissionStatus = .granted,
        resolver: FakeFocusedElementResolver,
        clipboard: FakeClipboardService = FakeClipboardService(),
        pasteResult: Bool,
        pidProvider: FakeFrontmostApplicationPIDProvider = FakeFrontmostApplicationPIDProvider(pid: 42)
    ) -> TextInsertionService {
        makeService(
            permissionCoordinator: FakePermissionCoordinator(
                accessibilityStatus: accessibilityStatus,
                accessibilityPromptResult: accessibilityStatus == .granted
            ),
            resolver: resolver,
            clipboard: clipboard,
            pasteService: FakeSyntheticPasteService(result: pasteResult),
            pidProvider: pidProvider
        )
    }

    private func makeService(
        accessibilityStatus: PermissionStatus = .granted,
        element: FakeFocusedTextElement?,
        clipboard: FakeClipboardService = FakeClipboardService(),
        pasteService: FakeSyntheticPasteService,
        pidProvider: FakeFrontmostApplicationPIDProvider
    ) -> TextInsertionService {
        makeService(
            permissionCoordinator: FakePermissionCoordinator(
                accessibilityStatus: accessibilityStatus,
                accessibilityPromptResult: accessibilityStatus == .granted
            ),
            resolver: FakeFocusedElementResolver(element: element),
            clipboard: clipboard,
            pasteService: pasteService,
            pidProvider: pidProvider
        )
    }

    private func makeService(
        permissionCoordinator: FakePermissionCoordinator,
        resolver: FakeFocusedElementResolver,
        clipboard: FakeClipboardService,
        pasteService: FakeSyntheticPasteService,
        pidProvider: FakeFrontmostApplicationPIDProvider
    ) -> TextInsertionService {
        TextInsertionService(
            permissionCoordinator: permissionCoordinator,
            focusedElementResolver: resolver,
            frontmostApplicationPIDProvider: pidProvider,
            clipboardService: clipboard,
            syntheticPasteService: pasteService
        )
    }
}

@MainActor
private final class FakeFocusedTextElement: FocusedTextElement {
    let isWritable: Bool
    var value: String?
    var selectedRange: NSRange?
    private let setValueSucceeds: Bool
    private let setSelectedRangeSucceeds: Bool

    init(
        value: String?,
        selectedRange: NSRange?,
        isWritable: Bool,
        setValueSucceeds: Bool = true,
        setSelectedRangeSucceeds: Bool = true
    ) {
        self.value = value
        self.selectedRange = selectedRange
        self.isWritable = isWritable
        self.setValueSucceeds = setValueSucceeds
        self.setSelectedRangeSucceeds = setSelectedRangeSucceeds
    }

    func setValue(_ newValue: String) -> Bool {
        guard setValueSucceeds else { return false }
        value = newValue
        return true
    }

    func setSelectedRange(_ newValue: NSRange) -> Bool {
        guard setSelectedRangeSucceeds else { return false }
        selectedRange = newValue
        return true
    }
}

@MainActor
private final class FakeFocusedElementResolver: FocusedElementResolving {
    var element: FakeFocusedTextElement?
    private let onResolve: () -> Void

    init(element: FakeFocusedTextElement?, onResolve: @escaping () -> Void = {}) {
        self.element = element
        self.onResolve = onResolve
    }

    func focusedElement() -> (any FocusedTextElement)? {
        onResolve()
        return element
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
    private(set) var pasteCallCount = 0

    init(result: Bool) {
        self.result = result
    }

    func pasteClipboardContents() -> Bool {
        pasteCallCount += 1
        return result
    }
}

@MainActor
private final class FakeFrontmostApplicationPIDProvider: FrontmostApplicationPIDProviding {
    var pid: pid_t?

    init(pid: pid_t?) {
        self.pid = pid
    }

    func frontmostApplicationPID() -> pid_t? {
        pid
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

    func openMicrophoneSettings() {}

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

    func openAccessibilitySettings() {}
}
