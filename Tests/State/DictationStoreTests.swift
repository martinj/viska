import XCTest
@testable import Viska

@MainActor
final class DictationStoreTests: XCTestCase {
    func testHoldModeStartsOnPressAndStopsOnRelease() {
        let context = makeContext(mode: .holdToRecord)

        context.store.setReady()
        context.store.handleHotkeyEvent(.pressed)
        context.store.handleHotkeyEvent(.released)

        XCTAssertEqual(context.store.state, .idle)
        XCTAssertEqual(context.lifecycle.events, [.started, .stopped])
    }

    func testToggleModeStartsOnFirstActivationAndStopsOnSecond() {
        let context = makeContext(mode: .toggleToRecord)

        context.store.setReady()
        context.store.handleHotkeyEvent(.toggle)
        context.store.handleHotkeyEvent(.toggle)

        XCTAssertEqual(context.store.state, .idle)
        XCTAssertEqual(context.lifecycle.events, [.started, .stopped])
    }

    func testEscapeCancelsRecording() {
        let context = makeContext(mode: .holdToRecord)

        context.store.setReady()
        context.store.handleHotkeyEvent(.pressed)
        context.store.handleHotkeyEvent(.cancel)

        XCTAssertEqual(context.store.state, .idle)
        XCTAssertEqual(context.lifecycle.events, [.started, .cancelled])
    }

    func testStartIsIgnoredWhileBusy() {
        let context = makeContext(mode: .holdToRecord)

        context.store.enterTranscribing()
        context.store.handleHotkeyEvent(.pressed)
        context.store.enterInserting()
        context.store.handleHotkeyEvent(.pressed)

        XCTAssertEqual(context.lifecycle.events, [])
        XCTAssertEqual(context.store.state, .inserting)
    }

    func testWordReplacementChangesDoNotReconfigureHotkey() {
        let context = makeContext(mode: .holdToRecord)

        XCTAssertEqual(context.hotkeyService.configureCallCount, 1)

        context.settingsStore.updateWordReplacements([
            WordReplacement(id: UUID(), trigger: "paper trail", replacement: "papertrail"),
        ])

        XCTAssertEqual(context.hotkeyService.configureCallCount, 1)

        context.settingsStore.updateHotkey(
            HotkeyDescriptor(
                keyCode: UInt32(36),
                modifiers: HotkeyDescriptor.requiredModifierFlags
            )
        )

        XCTAssertEqual(context.hotkeyService.configureCallCount, 2)

        context.settingsStore.updateRecordingMode(.toggleToRecord)

        XCTAssertEqual(context.hotkeyService.configureCallCount, 3)
    }

    func testClipboardFallbackReturnsToIdleAndAllowsAnotherRecording() async throws {
        let context = try makeContext(
            mode: .holdToRecord,
            audioCaptureEngine: FakeAudioCaptureEngine(recordedAudio: Self.makeRecordedAudio()),
            transcriptionClient: FakeTranscriptionClient(result: TranscriptionResult(text: "hello world")),
            textInsertionService: FakeTextInsertionService(outcome: .clipboardFallback(reason: .accessibilityDenied))
        )

        context.store.setReady()
        context.store.handleHotkeyEvent(.pressed)
        context.store.handleHotkeyEvent(.released)

        await waitForIdle(store: context.store)

        XCTAssertEqual(context.store.lastTranscript, "hello world")
        XCTAssertEqual(context.store.transcriptionHistory.map(\.text), ["hello world"])
        XCTAssertEqual(context.store.state, .idle)

        context.store.handleHotkeyEvent(.pressed)

        XCTAssertEqual(context.store.state, .recording(mode: .holdToRecord))
    }

    func testTranscriptionHistoryPersistsLatestTenNewestFirst() async throws {
        let historyStore = FakeTranscriptionHistoryStore()
        let context = try makeContext(
            mode: .holdToRecord,
            transcriptionHistoryStore: historyStore,
            audioCaptureEngine: FakeAudioCaptureEngine(recordedAudio: Self.makeRecordedAudio()),
            transcriptionClient: FakeTranscriptionClient(
                results: (1...11).map { TranscriptionResult(text: "transcript \($0)") }
            )
        )

        context.store.setReady()
        for _ in 1...11 {
            context.store.handleHotkeyEvent(.pressed)
            context.store.handleHotkeyEvent(.released)
            await waitForIdle(store: context.store)
        }

        XCTAssertEqual(
            context.store.transcriptionHistory.map(\.text),
            (2...11).reversed().map { "transcript \($0)" }
        )
        XCTAssertEqual(historyStore.savedItems.map(\.text), context.store.transcriptionHistory.map(\.text))
    }

    func testTranscriptionHistorySkipsWhitespaceOnlyTranscripts() async throws {
        let historyStore = FakeTranscriptionHistoryStore()
        let context = try makeContext(
            mode: .holdToRecord,
            transcriptionHistoryStore: historyStore,
            audioCaptureEngine: FakeAudioCaptureEngine(recordedAudio: Self.makeRecordedAudio()),
            transcriptionClient: FakeTranscriptionClient(result: TranscriptionResult(text: " \n\t "))
        )

        context.store.setReady()
        context.store.handleHotkeyEvent(.pressed)
        context.store.handleHotkeyEvent(.released)

        await waitForIdle(store: context.store)

        XCTAssertEqual(context.store.lastTranscript, " \n\t ")
        XCTAssertEqual(context.store.transcriptionHistory, [])
        XCTAssertEqual(historyStore.savedItems, [])
    }

    func testTranscriptionAppliesWordReplacementsBeforeInsertionAndHistory() async throws {
        let historyStore = FakeTranscriptionHistoryStore()
        let textInsertionService = FakeTextInsertionService(outcome: .insertedDirectly)
        let context = try makeContext(
            mode: .holdToRecord,
            wordReplacements: [
                WordReplacement(id: UUID(), trigger: "paper trail", replacement: "papertrail"),
            ],
            transcriptionHistoryStore: historyStore,
            audioCaptureEngine: FakeAudioCaptureEngine(recordedAudio: Self.makeRecordedAudio()),
            transcriptionClient: FakeTranscriptionClient(result: TranscriptionResult(text: "Paper Trail, please")),
            textInsertionService: textInsertionService
        )

        context.store.setReady()
        context.store.handleHotkeyEvent(.pressed)
        context.store.handleHotkeyEvent(.released)

        await waitForIdle(store: context.store)

        XCTAssertEqual(context.store.lastTranscript, "papertrail, please")
        XCTAssertEqual(context.store.transcriptionHistory.map(\.text), ["papertrail, please"])
        XCTAssertEqual(historyStore.savedItems.map(\.text), ["papertrail, please"])
        XCTAssertEqual(textInsertionService.insertedTexts, ["papertrail, please"])
    }

    func testTranscriptionHistoryLoadsPersistedItemsAndCopiesTranscriptText() {
        let item = TranscriptionHistoryItem(id: UUID(), text: "saved transcript", createdAt: Date())
        let clipboard = FakeClipboardService()
        let context = makeContext(
            mode: .holdToRecord,
            transcriptionHistoryStore: FakeTranscriptionHistoryStore(loadedItems: [item]),
            clipboardService: clipboard
        )

        XCTAssertEqual(context.store.transcriptionHistory, [item])

        context.store.copyTranscript(id: item.id)

        XCTAssertEqual(clipboard.value, "saved transcript")
    }

    func testTranscriptionRequestFailureAllowsAnotherRecording() async throws {
        let context = try makeContext(
            mode: .holdToRecord,
            audioCaptureEngine: FakeAudioCaptureEngine(recordedAudio: Self.makeRecordedAudio()),
            transcriptionClient: FakeTranscriptionClient(
                error: TranscriptionClient.Error.requestFailed("The network connection was lost.")
            )
        )

        context.store.setReady()
        context.store.handleHotkeyEvent(.pressed)
        context.store.handleHotkeyEvent(.released)

        await waitForState(
            .failed(
                title: "Transcription Failed",
                message: "Transcription request failed: The network connection was lost."
            ),
            store: context.store
        )

        context.store.handleHotkeyEvent(.pressed)

        XCTAssertEqual(context.store.state, .recording(mode: .holdToRecord))
    }

    func testEmptyRecordingFinalizationReturnsToIdleAndAllowsAnotherRecording() {
        let context = makeContext(
            mode: .holdToRecord,
            audioCaptureEngine: FakeAudioCaptureEngine(stopError: AudioCaptureEngine.Error.nothingCaptured)
        )

        context.store.setReady()
        context.store.handleHotkeyEvent(.pressed)
        context.store.handleHotkeyEvent(.released)

        XCTAssertEqual(context.store.state, .idle)
        XCTAssertEqual(context.lifecycle.events, [.started])

        context.store.handleHotkeyEvent(.pressed)

        XCTAssertEqual(context.store.state, .recording(mode: .holdToRecord))
    }

    func testReleaseCancelsPendingPermissionStart() async {
        let permissionCoordinator = FakePermissionCoordinator(
            microphoneStatus: .notDetermined,
            requestedPermissionResult: true
        )
        let audioCaptureEngine = FakeAudioCaptureEngine()
        let context = makeContext(
            mode: .holdToRecord,
            permissionCoordinator: permissionCoordinator,
            audioCaptureEngine: audioCaptureEngine
        )

        context.store.setReady()
        context.store.handleHotkeyEvent(.pressed)
        context.store.handleHotkeyEvent(.released)

        await permissionCoordinator.finishRequest()
        await Task.yield()

        XCTAssertEqual(context.store.state, .idle)
        XCTAssertEqual(context.lifecycle.events, [])
        XCTAssertEqual(audioCaptureEngine.startCaptureCallCount, 0)
    }

    func testMicrophoneSetupRequestsPermissionWithoutStartingRecording() async {
        let permissionCoordinator = FakePermissionCoordinator(
            microphoneStatus: .notDetermined,
            requestedPermissionResult: true
        )
        let audioCaptureEngine = FakeAudioCaptureEngine()
        let context = makeContext(
            mode: .holdToRecord,
            permissionCoordinator: permissionCoordinator,
            audioCaptureEngine: audioCaptureEngine
        )

        context.store.setReady()
        let requestTask = Task {
            await context.store.requestMicrophonePermission()
        }

        await waitForMicrophonePermissionRequest(permissionCoordinator)
        await permissionCoordinator.finishRequest()
        await requestTask.value

        XCTAssertEqual(context.store.microphonePermissionStatus, .granted)
        XCTAssertEqual(context.store.state, .idle)
        XCTAssertEqual(context.lifecycle.events, [])
        XCTAssertEqual(audioCaptureEngine.startCaptureCallCount, 0)
    }

    func testDeniedMicrophoneSetupOpensSettings() async {
        let permissionCoordinator = FakePermissionCoordinator(microphoneStatus: .denied)
        let context = makeContext(
            mode: .holdToRecord,
            permissionCoordinator: permissionCoordinator
        )

        await context.store.requestMicrophonePermission()

        XCTAssertTrue(permissionCoordinator.openedMicrophoneSettings)
        XCTAssertEqual(context.store.microphonePermissionStatus, .denied)
    }

    func testRefreshingGrantedMicrophoneClearsStaleMicrophoneBlocker() {
        let permissionCoordinator = FakePermissionCoordinator(microphoneStatus: .denied)
        let context = makeContext(
            mode: .holdToRecord,
            permissionCoordinator: permissionCoordinator
        )

        context.store.setUnavailable(
            title: "Microphone Required",
            message: "Microphone permission is required before dictation can record."
        )
        permissionCoordinator.updateMicrophoneStatus(.granted)

        context.store.refreshPermissionStatuses()

        XCTAssertEqual(context.store.microphonePermissionStatus, .granted)
        XCTAssertEqual(context.store.state, .idle)
    }

    func testRefreshingGrantedAccessibilityClearsStaleAccessibilityBlocker() {
        let permissionCoordinator = FakePermissionCoordinator(
            microphoneStatus: .granted,
            accessibilityStatus: .denied
        )
        let context = makeContext(
            mode: .holdToRecord,
            permissionCoordinator: permissionCoordinator
        )

        context.store.setUnavailable(
            title: "Accessibility Required",
            message: "Accessibility permission is required before text can be inserted."
        )
        permissionCoordinator.updateAccessibilityStatus(.granted)

        context.store.refreshPermissionStatuses()

        XCTAssertEqual(context.store.accessibilityPermissionStatus, .granted)
        XCTAssertEqual(context.store.state, .idle)
    }

    func testAccessibilitySetupRequestsPermissionWithoutStartingRecording() {
        let permissionCoordinator = FakePermissionCoordinator(
            microphoneStatus: .granted,
            accessibilityStatus: .denied,
            accessibilityPromptResult: true
        )
        let audioCaptureEngine = FakeAudioCaptureEngine()
        let context = makeContext(
            mode: .holdToRecord,
            permissionCoordinator: permissionCoordinator,
            audioCaptureEngine: audioCaptureEngine
        )

        context.store.setReady()
        context.store.requestAccessibilityPermission()

        XCTAssertEqual(permissionCoordinator.requestedAccessibilityPrompts, [true])
        XCTAssertEqual(context.store.accessibilityPermissionStatus, .granted)
        XCTAssertEqual(context.store.state, .idle)
        XCTAssertEqual(context.lifecycle.events, [])
        XCTAssertEqual(audioCaptureEngine.startCaptureCallCount, 0)
    }

    func testAccessibilitySetupOpensSettingsWhenPromptDoesNotGrant() {
        let permissionCoordinator = FakePermissionCoordinator(
            microphoneStatus: .granted,
            accessibilityStatus: .denied,
            accessibilityPromptResult: false
        )
        let context = makeContext(
            mode: .holdToRecord,
            permissionCoordinator: permissionCoordinator
        )

        context.store.requestAccessibilityPermission()

        XCTAssertEqual(permissionCoordinator.requestedAccessibilityPrompts, [true])
        XCTAssertTrue(permissionCoordinator.openedAccessibilitySettings)
        XCTAssertEqual(context.store.accessibilityPermissionStatus, .denied)
    }

    private func makeContext(
        mode: RecordingMode,
        wordReplacements: [WordReplacement] = [],
        transcriptionHistoryStore: any TranscriptionHistoryStoring = FakeTranscriptionHistoryStore(),
        permissionCoordinator: (any PermissionCoordinating)? = nil,
        audioCaptureEngine: (any AudioCaptureControlling)? = nil,
        transcriptionClient: (any AudioTranscribing)? = nil,
        textInsertionService: (any TextInserting)? = nil,
        clipboardService: (any ClipboardControlling)? = nil
    ) -> StoreContext {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settingsStore = SettingsStore(userDefaults: defaults)
        settingsStore.updateRecordingMode(mode)
        settingsStore.updateWordReplacements(wordReplacements)

        let hotkeyService = FakeGlobalHotkeyService()
        let lifecycle = DictationLifecycleSpy()
        let store = DictationStore(
            settingsStore: settingsStore,
            hotkeyService: hotkeyService,
            transcriptionHistoryStore: transcriptionHistoryStore,
            permissionCoordinator: permissionCoordinator,
            audioCaptureEngine: audioCaptureEngine,
            transcriptionClient: transcriptionClient,
            textInsertionService: textInsertionService,
            clipboardService: clipboardService,
            lifecycle: lifecycle,
            initialState: .unavailable(title: "Setup required", message: "Setup required")
        )

        return StoreContext(
            store: store,
            settingsStore: settingsStore,
            hotkeyService: hotkeyService,
            lifecycle: lifecycle
        )
    }

    private func waitForIdle(
        store: DictationStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await waitForState(.idle, store: store, file: file, line: line)
    }

    private func waitForState(
        _ expectedState: DictationState,
        store: DictationStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<50 {
            if store.state == expectedState {
                return
            }

            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Timed out waiting for store state \(expectedState)", file: file, line: line)
    }

    private func waitForMicrophonePermissionRequest(
        _ permissionCoordinator: FakePermissionCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<50 {
            if permissionCoordinator.requestMicrophonePermissionCallCount > 0 {
                return
            }

            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Timed out waiting for microphone permission request", file: file, line: line)
    }


    private static func makeRecordedAudio() throws -> RecordedAudio {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try Data("audio".utf8).write(to: fileURL)
        return RecordedAudio(fileURL: fileURL, sampleRate: 16_000, sampleCount: 2_000)
    }
}

private struct StoreContext {
    let store: DictationStore
    let settingsStore: SettingsStore
    let hotkeyService: FakeGlobalHotkeyService
    let lifecycle: DictationLifecycleSpy
}

@MainActor
private final class FakeAudioCaptureEngine: AudioCaptureControlling {
    private let recordedAudio: RecordedAudio?
    private let stopError: Swift.Error?
    private(set) var startCaptureCallCount = 0
    private(set) var isCapturing = false

    init(recordedAudio: RecordedAudio? = nil, stopError: Swift.Error? = nil) {
        self.recordedAudio = recordedAudio
        self.stopError = stopError
    }

    func startCapture(levelHandler: @escaping ([Float]) -> Void) throws {
        startCaptureCallCount += 1
        isCapturing = true
        levelHandler([Float](repeating: 0.5, count: AudioLevelAnalyzer.bandCount))
    }

    func stopCapture() throws -> RecordedAudio {
        isCapturing = false
        if let stopError {
            throw stopError
        }

        guard let recordedAudio else {
            throw AudioCaptureEngine.Error.nothingCaptured
        }

        return recordedAudio
    }

    func cancelCapture() {
        isCapturing = false
    }
}

private final class FakeTranscriptionClient: AudioTranscribing, @unchecked Sendable {
    private var results: [Result<TranscriptionResult, Swift.Error>]

    init(result: TranscriptionResult) {
        self.results = [.success(result)]
    }

    init(results: [TranscriptionResult]) {
        self.results = results.map { .success($0) }
    }

    init(error: Swift.Error) {
        self.results = [.failure(error)]
    }

    func transcribe(audio: RecordedAudio) async throws -> TranscriptionResult {
        if results.count > 1 {
            return try results.removeFirst().get()
        }

        return try results[0].get()
    }
}

private final class FakeTranscriptionHistoryStore: TranscriptionHistoryStoring {
    private let loadedItems: [TranscriptionHistoryItem]
    private(set) var savedItems: [TranscriptionHistoryItem] = []

    init(loadedItems: [TranscriptionHistoryItem] = []) {
        self.loadedItems = loadedItems
    }

    func load() -> [TranscriptionHistoryItem] {
        loadedItems
    }

    func save(_ items: [TranscriptionHistoryItem]) {
        savedItems = items
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
private final class FakeTextInsertionService: TextInserting {
    private let outcome: TextInsertionOutcome
    private(set) var insertedTexts: [String] = []

    init(outcome: TextInsertionOutcome) {
        self.outcome = outcome
    }

    func insert(_ text: String) async -> TextInsertionOutcome {
        insertedTexts.append(text)
        return outcome
    }
}

@MainActor
private final class FakePermissionCoordinator: PermissionCoordinating {
    private var currentMicrophoneStatus: PermissionStatus
    private var currentAccessibilityStatus: PermissionStatus
    private let requestedPermissionResult: Bool
    private let accessibilityPromptResult: Bool
    private var permissionContinuation: CheckedContinuation<Bool, Never>?
    private(set) var requestMicrophonePermissionCallCount = 0
    private(set) var requestedAccessibilityPrompts: [Bool] = []
    private(set) var openedMicrophoneSettings = false
    private(set) var openedAccessibilitySettings = false

    init(
        microphoneStatus: PermissionStatus,
        requestedPermissionResult: Bool = false,
        accessibilityStatus: PermissionStatus = .granted,
        accessibilityPromptResult: Bool = true
    ) {
        self.currentMicrophoneStatus = microphoneStatus
        self.requestedPermissionResult = requestedPermissionResult
        self.currentAccessibilityStatus = accessibilityStatus
        self.accessibilityPromptResult = accessibilityPromptResult
    }

    func microphoneStatus() -> PermissionStatus {
        currentMicrophoneStatus
    }

    func requestMicrophonePermission() async -> Bool {
        requestMicrophonePermissionCallCount += 1
        return await withCheckedContinuation { continuation in
            permissionContinuation = continuation
        }
    }

    func openMicrophoneSettings() {
        openedMicrophoneSettings = true
    }

    func updateMicrophoneStatus(_ status: PermissionStatus) {
        currentMicrophoneStatus = status
    }

    func finishRequest() async {
        permissionContinuation?.resume(returning: requestedPermissionResult)
        permissionContinuation = nil
        if requestedPermissionResult {
            currentMicrophoneStatus = .granted
        } else {
            currentMicrophoneStatus = .denied
        }
        await Task.yield()
    }

    func accessibilityStatus() -> PermissionStatus {
        currentAccessibilityStatus
    }

    func updateAccessibilityStatus(_ status: PermissionStatus) {
        currentAccessibilityStatus = status
    }

    func requestAccessibilityPermission(prompt: Bool) -> Bool {
        requestedAccessibilityPrompts.append(prompt)
        if accessibilityPromptResult {
            currentAccessibilityStatus = .granted
            return true
        }

        return false
    }

    func openAccessibilitySettings() {
        openedAccessibilitySettings = true
    }
}

@MainActor
private final class FakeGlobalHotkeyService: GlobalHotkeyControlling {
    var onEvent: ((GlobalHotkeyService.Event) -> Void)?
    private(set) var configuredDescriptor: HotkeyDescriptor?
    private(set) var configuredMode: RecordingMode?
    private(set) var configureCallCount = 0

    func configure(descriptor: HotkeyDescriptor, mode: RecordingMode) throws {
        configureCallCount += 1
        configuredDescriptor = descriptor
        configuredMode = mode
    }
}

@MainActor
private final class DictationLifecycleSpy: DictationLifecycleControlling {
    enum Event: Equatable {
        case started
        case stopped
        case cancelled
    }

    private(set) var events: [Event] = []

    func recordingDidStart() {
        events.append(.started)
    }

    func recordingDidStop() {
        events.append(.stopped)
    }

    func recordingDidCancel() {
        events.append(.cancelled)
    }
}
