import XCTest
@testable import Viska

@MainActor
final class DictationStoreTests: XCTestCase {
    func testHoldModeStartsOnPressAndStopsOnRelease() async {
        let context = makeContext(mode: .holdToRecord)

        context.store.setReady()
        context.store.handleHotkeyEvent(.pressed)
        await waitForLifecycleEvent(.started, context: context)
        context.store.handleHotkeyEvent(.released)
        await waitForIdle(store: context.store)

        XCTAssertEqual(context.store.state, .idle)
        XCTAssertEqual(context.lifecycle.events, [.started, .stopped])
    }

    func testToggleModeStartsOnFirstActivationAndStopsOnSecond() async {
        let context = makeContext(mode: .toggleToRecord)

        context.store.setReady()
        context.store.handleHotkeyEvent(.toggle)
        await waitForLifecycleEvent(.started, context: context)
        context.store.handleHotkeyEvent(.toggle)
        await waitForIdle(store: context.store)

        XCTAssertEqual(context.store.state, .idle)
        XCTAssertEqual(context.lifecycle.events, [.started, .stopped])
    }

    func testEscapeCancelsRecording() async {
        let context = makeContext(mode: .holdToRecord)

        context.store.setReady()
        context.store.handleHotkeyEvent(.pressed)
        await waitForLifecycleEvent(.started, context: context)
        context.store.handleHotkeyEvent(.cancel)
        await waitForIdle(store: context.store)

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

    func testRecordingStartFailureAllowsNextHotkeyToRetry() async {
        let audioCaptureEngine = FakeAudioCaptureEngine(
            startErrors: [AudioCaptureEngine.Error.inputUnavailable]
        )
        let context = makeContext(
            mode: .holdToRecord,
            audioCaptureEngine: audioCaptureEngine
        )

        context.store.setReady()
        context.store.handleHotkeyEvent(.pressed)
        await waitForState(
            .failed(
                title: "Recording Failed",
                message: "Microphone capture failed to start. Try again."
            ),
            store: context.store
        )

        XCTAssertEqual(
            context.store.state,
            .failed(
                title: "Recording Failed",
                message: "Microphone capture failed to start. Try again."
            )
        )

        context.store.handleHotkeyEvent(.pressed)
        await waitForLifecycleEvent(.started, context: context)

        XCTAssertEqual(context.store.state, .recording(mode: .holdToRecord))
        XCTAssertEqual(audioCaptureEngine.startCaptureCallCount, 2)
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

    func testUnbindingActionKeepsItSavedAndRemovesItsRegistration() throws {
        let context = makeContext(mode: .holdToRecord)
        var action = makeAction(name: "Clean up", keyCode: 1)

        try context.store.saveDictationAction(action)
        XCTAssertEqual(context.hotkeyService.configuredRegistrations.count, 2)

        action.hotkey = nil
        try context.store.saveDictationAction(action)

        XCTAssertEqual(context.settingsStore.preferences.dictationActions, [action])
        XCTAssertEqual(
            context.hotkeyService.configuredRegistrations.map(\.descriptor),
            [context.settingsStore.preferences.hotkey]
        )
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
        await waitForLifecycleEvent(.started, context: context)
        context.store.handleHotkeyEvent(.released)

        await waitForIdle(store: context.store)

        XCTAssertEqual(context.store.lastTranscript, "hello world")
        XCTAssertEqual(context.store.transcriptionHistory.map(\.text), ["hello world"])
        XCTAssertEqual(context.store.state, .idle)

        context.store.handleHotkeyEvent(.pressed)
        await waitForLifecycleEvent(.started, context: context, count: 2)

        XCTAssertEqual(context.store.state, .recording(mode: .holdToRecord))
    }

    func testTranscriptionHistoryPersistsLatestTenNewestFirst() async throws {
        let historyStore = FakeTranscriptionHistoryStore()
        let audioCaptureEngine = FakeAudioCaptureEngine(recordedAudio: try Self.makeRecordedAudio())
        let context = makeContext(
            mode: .holdToRecord,
            transcriptionHistoryStore: historyStore,
            audioCaptureEngine: audioCaptureEngine,
            transcriptionClient: FakeTranscriptionClient(
                results: (1...11).map { TranscriptionResult(text: "transcript \($0)") }
            )
        )

        context.store.setReady()
        for recordingNumber in 1...11 {
            context.store.handleHotkeyEvent(.pressed)
            await waitForLifecycleEvent(.started, context: context, count: recordingNumber)
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
        await waitForLifecycleEvent(.started, context: context)
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
        await waitForLifecycleEvent(.started, context: context)
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

    func testApplyingUnboundActionToRecentCopiesProcessedTextWithoutChangingHistory() async {
        let item = TranscriptionHistoryItem(id: UUID(), text: "rough source", createdAt: Date())
        var action = makeAction(name: "Make it prompt ready", keyCode: 1)
        action.hotkey = nil
        let historyStore = FakeTranscriptionHistoryStore(loadedItems: [item])
        let processor = FakeTextProcessor(results: [.success("Polished result")])
        let clipboard = FakeClipboardService()
        let insertion = FakeTextInsertionService(outcome: .insertedDirectly)
        let context = makeContext(
            mode: .holdToRecord,
            actions: [action],
            transcriptionHistoryStore: historyStore,
            textProcessor: processor,
            textInsertionService: insertion,
            clipboardService: clipboard
        )

        context.store.setReady()
        context.store.applyDictationAction(id: action.id, toTranscriptID: item.id)
        await waitForIdle(store: context.store)

        XCTAssertEqual(processor.sourceTexts, ["rough source"])
        XCTAssertEqual(processor.actions, [action])
        XCTAssertEqual(clipboard.value, "Polished result")
        XCTAssertEqual(context.store.transcriptionHistory, [item])
        XCTAssertEqual(historyStore.savedItems, [])
        XCTAssertEqual(insertion.insertedTexts, [])
        XCTAssertEqual(context.store.recentActionFeedback(for: item.id), .copied)
    }

    func testApplyingActionToRecentFailureLeavesClipboardAndHistoryUnchanged() async {
        let item = TranscriptionHistoryItem(id: UUID(), text: "recoverable source", createdAt: Date())
        let action = makeAction(name: "Clean up", keyCode: 1)
        let historyStore = FakeTranscriptionHistoryStore(loadedItems: [item])
        let processor = FakeTextProcessor(results: [.failure(CodexAppServerClient.Error.invalidOutput)])
        let clipboard = FakeClipboardService()
        clipboard.setString("existing clipboard")
        let context = makeContext(
            mode: .holdToRecord,
            actions: [action],
            transcriptionHistoryStore: historyStore,
            textProcessor: processor,
            clipboardService: clipboard
        )

        context.store.setReady()
        context.store.applyDictationAction(id: action.id, toTranscriptID: item.id)
        await waitForState(
            .failed(title: "Processing Failed", message: "Codex returned an invalid result. Try again."),
            store: context.store
        )

        XCTAssertEqual(clipboard.value, "existing clipboard")
        XCTAssertEqual(context.store.transcriptionHistory, [item])
        XCTAssertEqual(historyStore.savedItems, [])
        XCTAssertEqual(
            context.store.recentActionFeedback(for: item.id),
            .failed(message: "Codex returned an invalid result. Try again.")
        )
    }

    func testCancellingRecentActionDoesNotDuplicateHistoryOrCopyLateOutput() async {
        let item = TranscriptionHistoryItem(id: UUID(), text: "original source", createdAt: Date())
        let action = makeAction(name: "Translate", keyCode: 1)
        let historyStore = FakeTranscriptionHistoryStore(loadedItems: [item])
        let processor = FakeTextProcessor(suspends: true)
        let clipboard = FakeClipboardService()
        let context = makeContext(
            mode: .holdToRecord,
            actions: [action],
            transcriptionHistoryStore: historyStore,
            textProcessor: processor,
            clipboardService: clipboard
        )

        context.store.setReady()
        context.store.applyDictationAction(id: action.id, toTranscriptID: item.id)
        await waitForState(.processing(actionName: "Translate"), store: context.store)
        context.store.handleHotkeyEvent(.cancel)
        await waitForIdle(store: context.store)
        processor.complete(with: .success("Late output"))
        await Task.yield()

        XCTAssertNil(clipboard.value)
        XCTAssertEqual(context.store.transcriptionHistory, [item])
        XCTAssertEqual(historyStore.savedItems, [])
        XCTAssertNil(context.store.recentActionFeedback)
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
        await waitForLifecycleEvent(.started, context: context)
        context.store.handleHotkeyEvent(.released)

        await waitForState(
            .failed(
                title: "Transcription Failed",
                message: "Transcription request failed: The network connection was lost."
            ),
            store: context.store
        )

        context.store.handleHotkeyEvent(.pressed)
        await waitForLifecycleEvent(.started, context: context, count: 2)

        XCTAssertEqual(context.store.state, .recording(mode: .holdToRecord))
    }

    func testEmptyRecordingFinalizationReturnsToIdleAndAllowsAnotherRecording() async {
        let context = makeContext(
            mode: .holdToRecord,
            audioCaptureEngine: FakeAudioCaptureEngine(stopError: AudioCaptureEngine.Error.nothingCaptured)
        )

        context.store.setReady()
        context.store.handleHotkeyEvent(.pressed)
        await waitForLifecycleEvent(.started, context: context)
        context.store.handleHotkeyEvent(.released)
        await waitForIdle(store: context.store)

        XCTAssertEqual(context.store.state, .idle)
        XCTAssertEqual(context.lifecycle.events, [.started])

        context.store.handleHotkeyEvent(.pressed)
        await waitForLifecycleEvent(.started, context: context, count: 2)

        XCTAssertEqual(context.store.state, .recording(mode: .holdToRecord))
    }

    func testOverlayShowsBeforeCaptureStartupAndReleaseCancelsPendingStart() async {
        let audioCaptureEngine = FakeAudioCaptureEngine(suspendsStart: true)
        let overlayController = RecordingOverlaySpy()
        let context = makeContext(
            mode: .holdToRecord,
            audioCaptureEngine: audioCaptureEngine,
            overlayController: overlayController
        )

        context.store.setReady()
        context.store.handleHotkeyEvent(.pressed)

        await waitForState(.recording(mode: .holdToRecord), store: context.store)
        await waitForCaptureStart(audioCaptureEngine)

        XCTAssertEqual(overlayController.showCallCount, 1)
        XCTAssertEqual(context.lifecycle.events, [])

        context.store.handleHotkeyEvent(.released)
        await waitForIdle(store: context.store)
        await waitForCaptureCancellation(audioCaptureEngine)

        XCTAssertEqual(overlayController.hideCallCount, 1)
        XCTAssertEqual(context.lifecycle.events, [])
        XCTAssertFalse(audioCaptureEngine.isCapturing)
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

    func testActionAppliesReplacementsBeforeProcessingAndStoresOnlyProcessedText() async throws {
        let action = makeAction(name: "Clean up", keyCode: 1)
        let processor = FakeTextProcessor(results: [.success("Finished text")])
        let insertion = FakeTextInsertionService(outcome: .insertedDirectly)
        let overlay = RecordingOverlaySpy()
        let context = makeContext(
            mode: .holdToRecord,
            wordReplacements: [WordReplacement(id: UUID(), trigger: "paper trail", replacement: "papertrail")],
            actions: [action],
            audioCaptureEngine: FakeAudioCaptureEngine(recordedAudio: try Self.makeRecordedAudio()),
            overlayController: overlay,
            transcriptionClient: FakeTranscriptionClient(result: TranscriptionResult(text: "Paper Trail, please")),
            textProcessor: processor,
            textInsertionService: insertion
        )

        context.store.setReady()
        context.store.handleHotkeyEvent(.pressed(route: .action(action)))
        await waitForLifecycleEvent(.started, context: context)
        context.store.handleHotkeyEvent(.released(route: .action(action)))
        await waitForIdle(store: context.store)

        XCTAssertEqual(processor.sourceTexts, ["papertrail, please"])
        XCTAssertEqual(processor.actions, [action])
        XCTAssertEqual(insertion.insertedTexts, ["Finished text"])
        XCTAssertEqual(context.store.transcriptionHistory.map(\.text), ["Finished text"])
        XCTAssertEqual(overlay.processingActionNames, ["Clean up"])
        XCTAssertEqual(overlay.showInsertingCallCount, 1)
    }

    func testActionIsSnapshottedWhenRecordingStarts() async throws {
        let original = makeAction(name: "Original", keyCode: 1, prompt: "Original prompt")
        var edited = original
        edited.name = "Edited"
        edited.prompt = "Edited prompt"
        let processor = FakeTextProcessor(results: [.success("Output")])
        let context = makeContext(
            mode: .holdToRecord,
            actions: [original],
            audioCaptureEngine: FakeAudioCaptureEngine(recordedAudio: try Self.makeRecordedAudio()),
            transcriptionClient: FakeTranscriptionClient(result: TranscriptionResult(text: "Source")),
            textProcessor: processor
        )

        context.store.setReady()
        context.store.handleHotkeyEvent(.pressed(route: .action(original)))
        await waitForLifecycleEvent(.started, context: context)
        try context.settingsStore.updateDictationActions([edited])
        context.store.handleHotkeyEvent(.released(route: .action(edited)))
        await waitForIdle(store: context.store)

        XCTAssertEqual(processor.actions, [original])
    }

    func testProcessingFailurePreservesSourceWithoutInsertionAndRemainsRetryable() async throws {
        let action = makeAction(name: "Clean up", keyCode: 1)
        let processor = FakeTextProcessor(results: [.failure(CodexAppServerClient.Error.invalidOutput)])
        let insertion = FakeTextInsertionService(outcome: .insertedDirectly)
        let context = makeContext(
            mode: .holdToRecord,
            actions: [action],
            audioCaptureEngine: FakeAudioCaptureEngine(recordedAudio: try Self.makeRecordedAudio()),
            transcriptionClient: FakeTranscriptionClient(result: TranscriptionResult(text: "Recover me")),
            textProcessor: processor,
            textInsertionService: insertion
        )

        context.store.setReady()
        context.store.handleHotkeyEvent(.pressed(route: .action(action)))
        await waitForLifecycleEvent(.started, context: context)
        context.store.handleHotkeyEvent(.released(route: .action(action)))
        await waitForState(
            .failed(title: "Processing Failed", message: "Codex returned an invalid result. Try again."),
            store: context.store
        )

        XCTAssertEqual(insertion.insertedTexts, [])
        XCTAssertEqual(context.store.transcriptionHistory.map(\.text), ["Recover me"])
        context.store.handleHotkeyEvent(.pressed)
        await waitForLifecycleEvent(.started, context: context, count: 2)
    }

    func testEscapeCancelsProcessingPreservesSourceAndIgnoresLateCompletion() async throws {
        let action = makeAction(name: "Translate", keyCode: 1)
        let processor = FakeTextProcessor(suspends: true)
        let insertion = FakeTextInsertionService(outcome: .insertedDirectly)
        let context = makeContext(
            mode: .holdToRecord,
            actions: [action],
            audioCaptureEngine: FakeAudioCaptureEngine(recordedAudio: try Self.makeRecordedAudio()),
            transcriptionClient: FakeTranscriptionClient(result: TranscriptionResult(text: "Källtext")),
            textProcessor: processor,
            textInsertionService: insertion
        )

        context.store.setReady()
        context.store.handleHotkeyEvent(.pressed(route: .action(action)))
        await waitForLifecycleEvent(.started, context: context)
        context.store.handleHotkeyEvent(.released(route: .action(action)))
        await waitForState(.processing(actionName: "Translate"), store: context.store)
        context.store.handleHotkeyEvent(.cancel)
        await waitForIdle(store: context.store)
        processor.complete(with: .success("Late output"))
        await Task.yield()

        XCTAssertEqual(context.store.transcriptionHistory.map(\.text), ["Källtext"])
        XCTAssertEqual(insertion.insertedTexts, [])
        XCTAssertEqual(context.store.state, .idle)
    }

    func testOtherRouteCannotStartOrStopConcurrentRecording() async {
        let action = makeAction(name: "Action", keyCode: 1)
        let audio = FakeAudioCaptureEngine()
        let context = makeContext(mode: .holdToRecord, actions: [action], audioCaptureEngine: audio)

        context.store.setReady()
        context.store.handleHotkeyEvent(.pressed(route: .action(action)))
        await waitForLifecycleEvent(.started, context: context)
        context.store.handleHotkeyEvent(.pressed(route: .plain))
        context.store.handleHotkeyEvent(.released(route: .plain))

        XCTAssertEqual(audio.startCaptureCallCount, 1)
        XCTAssertEqual(context.store.state, .recording(mode: .holdToRecord))
    }

    private func makeContext(
        mode: RecordingMode,
        wordReplacements: [WordReplacement] = [],
        actions: [DictationAction] = [],
        transcriptionHistoryStore: any TranscriptionHistoryStoring = FakeTranscriptionHistoryStore(),
        permissionCoordinator: (any PermissionCoordinating)? = nil,
        audioCaptureEngine: (any AudioCaptureControlling)? = nil,
        overlayController: (any RecordingOverlayControlling)? = nil,
        transcriptionClient: (any AudioTranscribing)? = nil,
        textProcessor: (any TextProcessing)? = nil,
        textInsertionService: (any TextInserting)? = nil,
        clipboardService: (any ClipboardControlling)? = nil
    ) -> StoreContext {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settingsStore = SettingsStore(userDefaults: defaults)
        settingsStore.updateRecordingMode(mode)
        settingsStore.updateWordReplacements(wordReplacements)
        try! settingsStore.updateDictationActions(actions)

        let hotkeyService = FakeGlobalHotkeyService()
        let lifecycle = DictationLifecycleSpy()
        let store = DictationStore(
            settingsStore: settingsStore,
            hotkeyService: hotkeyService,
            transcriptionHistoryStore: transcriptionHistoryStore,
            permissionCoordinator: permissionCoordinator,
            audioCaptureEngine: audioCaptureEngine,
            overlayController: overlayController,
            transcriptionClient: transcriptionClient,
            textProcessor: textProcessor,
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

    private func makeAction(
        name: String,
        keyCode: UInt32,
        prompt: String = "Transform."
    ) -> DictationAction {
        DictationAction(
            id: UUID(),
            name: name,
            hotkey: HotkeyDescriptor(keyCode: keyCode, modifiers: HotkeyDescriptor.requiredModifierFlags),
            model: "gpt-5.6-luna",
            prompt: prompt
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

    private func waitForLifecycleEvent(
        _ event: DictationLifecycleSpy.Event,
        context: StoreContext,
        count: Int = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<50 {
            if context.lifecycle.events.filter({ $0 == event }).count >= count {
                return
            }

            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Timed out waiting for lifecycle event \(event)", file: file, line: line)
    }

    private func waitForCaptureStart(
        _ audioCaptureEngine: FakeAudioCaptureEngine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<50 {
            if audioCaptureEngine.startCaptureCallCount > 0 {
                return
            }

            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Timed out waiting for capture startup", file: file, line: line)
    }

    private func waitForCaptureCancellation(
        _ audioCaptureEngine: FakeAudioCaptureEngine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<50 {
            if audioCaptureEngine.cancelCaptureCallCount > 0 {
                return
            }

            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Timed out waiting for capture cancellation", file: file, line: line)
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
    private let suspendsStart: Bool
    private var startErrors: [Swift.Error]
    private var startContinuation: CheckedContinuation<Void, Never>?
    private(set) var startCaptureCallCount = 0
    private(set) var cancelCaptureCallCount = 0
    private(set) var isCapturing = false

    init(
        recordedAudio: RecordedAudio? = nil,
        stopError: Swift.Error? = nil,
        startErrors: [Swift.Error] = [],
        suspendsStart: Bool = false
    ) {
        self.recordedAudio = recordedAudio
        self.stopError = stopError
        self.startErrors = startErrors
        self.suspendsStart = suspendsStart
    }

    func startCapture(levelHandler: @escaping ([Float]) -> Void) async throws {
        startCaptureCallCount += 1
        if !startErrors.isEmpty {
            throw startErrors.removeFirst()
        }

        if suspendsStart {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
            try Task.checkCancellation()
        }

        isCapturing = true
        levelHandler([Float](repeating: 0.5, count: AudioLevelAnalyzer.bandCount))
    }

    func stopCapture() async throws -> RecordedAudio {
        isCapturing = false
        if let stopError {
            throw stopError
        }

        guard let recordedAudio else {
            throw AudioCaptureEngine.Error.nothingCaptured
        }

        return recordedAudio
    }

    func cancelCapture() async {
        cancelCaptureCallCount += 1
        isCapturing = false
        startContinuation?.resume()
        startContinuation = nil
    }
}

@MainActor
private final class RecordingOverlaySpy: RecordingOverlayControlling {
    private(set) var showCallCount = 0
    private(set) var showTranscribingCallCount = 0
    private(set) var hideCallCount = 0
    private(set) var processingActionNames: [String] = []
    private(set) var showInsertingCallCount = 0
    private(set) var levels: [[Float]] = []

    func show() {
        showCallCount += 1
    }

    func update(levels: [Float]) {
        self.levels.append(levels)
    }

    func showTranscribing() {
        showTranscribingCallCount += 1
    }

    func showProcessing(actionName: String) {
        processingActionNames.append(actionName)
    }

    func showInserting() {
        showInsertingCallCount += 1
    }

    func hide() {
        hideCallCount += 1
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

private final class FakeTextProcessor: TextProcessing, @unchecked Sendable {
    private var results: [Result<String, Swift.Error>]
    private let suspends: Bool
    private var continuation: CheckedContinuation<String, Swift.Error>?
    private(set) var sourceTexts: [String] = []
    private(set) var actions: [DictationAction] = []

    init(results: [Result<String, Swift.Error>] = [], suspends: Bool = false) {
        self.results = results
        self.suspends = suspends
    }

    func process(sourceText: String, action: DictationAction) async throws -> String {
        sourceTexts.append(sourceText)
        actions.append(action)
        if suspends {
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        return try results.removeFirst().get()
    }

    func complete(with result: Result<String, Swift.Error>) {
        continuation?.resume(with: result)
        continuation = nil
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
    private(set) var configuredRegistrations: [DictationHotkeyRegistration] = []
    private(set) var configuredMode: RecordingMode?
    private(set) var configureCallCount = 0

    func configure(registrations: [DictationHotkeyRegistration], mode: RecordingMode) throws {
        configureCallCount += 1
        configuredRegistrations = registrations
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
