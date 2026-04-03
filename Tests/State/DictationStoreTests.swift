import XCTest
@testable import VoiceCompanion

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

    private func makeContext(
        mode: RecordingMode,
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
        for _ in 0..<50 {
            if store.state == .idle {
                return
            }

            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Timed out waiting for store to return to idle", file: file, line: line)
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
    private let recordedAudio: RecordedAudio
    private(set) var isCapturing = false

    init(recordedAudio: RecordedAudio) {
        self.recordedAudio = recordedAudio
    }

    func startCapture(levelHandler: @escaping ([Float]) -> Void) throws {
        isCapturing = true
        levelHandler([Float](repeating: 0.5, count: AudioLevelAnalyzer.bandCount))
    }

    func stopCapture() throws -> RecordedAudio {
        isCapturing = false
        return recordedAudio
    }

    func cancelCapture() {
        isCapturing = false
    }
}

private final class FakeTranscriptionClient: AudioTranscribing, @unchecked Sendable {
    private let result: TranscriptionResult

    init(result: TranscriptionResult) {
        self.result = result
    }

    func transcribe(audio: RecordedAudio) async throws -> TranscriptionResult {
        result
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
