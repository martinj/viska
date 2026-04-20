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
        XCTAssertEqual(context.store.state, .idle)

        context.store.handleHotkeyEvent(.pressed)

        XCTAssertEqual(context.store.state, .recording(mode: .holdToRecord))
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

    private func makeContext(
        mode: RecordingMode,
        permissionCoordinator: (any PermissionCoordinating)? = nil,
        audioCaptureEngine: (any AudioCaptureControlling)? = nil,
        transcriptionClient: (any AudioTranscribing)? = nil,
        textInsertionService: (any TextInserting)? = nil
    ) -> StoreContext {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settingsStore = SettingsStore(userDefaults: defaults)
        settingsStore.updateRecordingMode(mode)

        let hotkeyService = FakeGlobalHotkeyService()
        let lifecycle = DictationLifecycleSpy()
        let store = DictationStore(
            settingsStore: settingsStore,
            hotkeyService: hotkeyService,
            permissionCoordinator: permissionCoordinator,
            audioCaptureEngine: audioCaptureEngine,
            transcriptionClient: transcriptionClient,
            textInsertionService: textInsertionService,
            lifecycle: lifecycle,
            initialState: .unavailable(title: "Setup required", message: "Setup required")
        )

        return StoreContext(
            store: store,
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
    private let result: Result<TranscriptionResult, Swift.Error>

    init(result: TranscriptionResult) {
        self.result = .success(result)
    }

    init(error: Swift.Error) {
        self.result = .failure(error)
    }

    func transcribe(audio: RecordedAudio) async throws -> TranscriptionResult {
        try result.get()
    }
}

@MainActor
private final class FakeTextInsertionService: TextInserting {
    private let outcome: TextInsertionOutcome

    init(outcome: TextInsertionOutcome) {
        self.outcome = outcome
    }

    func insert(_ text: String) async -> TextInsertionOutcome {
        outcome
    }
}

@MainActor
private final class FakePermissionCoordinator: PermissionCoordinating {
    private let currentMicrophoneStatus: PermissionStatus
    private let requestedPermissionResult: Bool
    private var permissionContinuation: CheckedContinuation<Bool, Never>?

    init(microphoneStatus: PermissionStatus, requestedPermissionResult: Bool = false) {
        self.currentMicrophoneStatus = microphoneStatus
        self.requestedPermissionResult = requestedPermissionResult
    }

    func microphoneStatus() -> PermissionStatus {
        currentMicrophoneStatus
    }

    func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            permissionContinuation = continuation
        }
    }

    func finishRequest() async {
        permissionContinuation?.resume(returning: requestedPermissionResult)
        permissionContinuation = nil
        await Task.yield()
    }

    func accessibilityStatus() -> PermissionStatus {
        .granted
    }

    func requestAccessibilityPermission(prompt: Bool) -> Bool {
        true
    }
}

@MainActor
private final class FakeGlobalHotkeyService: GlobalHotkeyControlling {
    var onEvent: ((GlobalHotkeyService.Event) -> Void)?
    private(set) var configuredDescriptor: HotkeyDescriptor?
    private(set) var configuredMode: RecordingMode?

    func configure(descriptor: HotkeyDescriptor, mode: RecordingMode) throws {
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
