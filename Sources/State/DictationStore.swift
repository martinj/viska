import Combine
import Foundation

@MainActor
protocol DictationLifecycleControlling: AnyObject {
    func recordingDidStart()
    func recordingDidStop()
    func recordingDidCancel()
}

@MainActor
final class DictationStore: ObservableObject {
    @Published private(set) var state: DictationState
    @Published private(set) var hotkeyErrorMessage: String?
    @Published private(set) var lastRecordedAudio: RecordedAudio?
    @Published private(set) var lastTranscript: String?

    private let settingsStore: SettingsStore
    private let hotkeyService: any GlobalHotkeyControlling
    private let permissionCoordinator: (any PermissionCoordinating)?
    private let audioCaptureEngine: (any AudioCaptureControlling)?
    private let overlayController: (any RecordingOverlayControlling)?
    private let codexStatusMonitor: CodexAuthStatusMonitor?
    private let transcriptionClient: (any AudioTranscribing)?
    private let textInsertionService: (any TextInserting)?
    private weak var lifecycle: DictationLifecycleControlling?
    private var preferencesCancellable: AnyCancellable?
    private var pendingStartTask: Task<Void, Never>?
    private var pendingTranscriptionTask: Task<Void, Never>?

    init(
        settingsStore: SettingsStore,
        hotkeyService: any GlobalHotkeyControlling,
        permissionCoordinator: (any PermissionCoordinating)? = nil,
        audioCaptureEngine: (any AudioCaptureControlling)? = nil,
        overlayController: (any RecordingOverlayControlling)? = nil,
        codexStatusMonitor: CodexAuthStatusMonitor? = nil,
        transcriptionClient: (any AudioTranscribing)? = nil,
        textInsertionService: (any TextInserting)? = nil,
        lifecycle: DictationLifecycleControlling? = nil,
        initialState: DictationState = .unavailable(title: "Checking Codex", message: "Codex setup is not ready yet.")
    ) {
        self.settingsStore = settingsStore
        self.hotkeyService = hotkeyService
        self.permissionCoordinator = permissionCoordinator
        self.audioCaptureEngine = audioCaptureEngine
        self.overlayController = overlayController
        self.codexStatusMonitor = codexStatusMonitor
        self.transcriptionClient = transcriptionClient
        self.textInsertionService = textInsertionService
        self.lifecycle = lifecycle
        self.state = initialState

        hotkeyService.onEvent = { [weak self] event in
            self?.handleHotkeyEvent(event)
        }

        configureHotkey(using: settingsStore.preferences)
        observePreferences()

        if codexStatusMonitor != nil {
            Task { [weak self] in
                await self?.refreshCodexAvailability()
            }
        }
    }

    func setReady() {
        state = .idle
    }

    func setUnavailable(title: String = "Unavailable", message: String) {
        state = .unavailable(title: title, message: message)
    }

    func enterTranscribing() {
        state = .transcribing
    }

    func enterInserting() {
        state = .inserting
    }

    func finishActiveWork() {
        state = .idle
    }

    func refreshCodexAvailability() async {
        guard let codexStatusMonitor else { return }

        let availability = await codexStatusMonitor.refresh()
        guard case .recording = state else {
            state = availability.isReady
                ? .idle
                : .unavailable(title: availability.title, message: availability.message)
            return
        }
    }

    func updateHotkey(_ descriptor: HotkeyDescriptor) {
        do {
            try descriptor.validate()

            var updatedPreferences = settingsStore.preferences
            updatedPreferences.hotkey = descriptor

            try hotkeyService.configure(
                descriptor: descriptor,
                mode: updatedPreferences.recordingMode
            )
            hotkeyErrorMessage = nil
            settingsStore.updateHotkey(descriptor)
        } catch {
            hotkeyErrorMessage = message(for: error)
        }
    }

    func handleHotkeyEvent(_ event: GlobalHotkeyService.Event) {
        switch event {
        case .pressed:
            startRecordingIfPossible()
        case .released:
            stopRecordingIfNeeded()
        case .toggle:
            toggleRecording()
        case .cancel:
            cancelRecordingIfNeeded()
        }
    }

    private func startRecordingIfPossible() {
        guard case .idle = state else { return }

        let microphoneMessage = "Microphone permission is required before dictation can record."

        if let permissionCoordinator {
            switch permissionCoordinator.microphoneStatus() {
            case .granted:
                performRecordingStart()
                return
            case .denied, .restricted:
                setUnavailable(title: "Microphone Required", message: microphoneMessage)
                return
            case .notDetermined:
                break
            }
        }

        if permissionCoordinator == nil {
            performRecordingStart()
            return
        }

        pendingStartTask?.cancel()
        pendingStartTask = Task { [weak self] in
            await self?.beginRecording()
        }
    }

    private func stopRecordingIfNeeded() {
        if pendingStartTask != nil {
            pendingStartTask?.cancel()
            pendingStartTask = nil
            return
        }

        guard case .recording = state else { return }

        do {
            lastRecordedAudio = try audioCaptureEngine?.stopCapture()
            lifecycle?.recordingDidStop()

            if let transcriptionClient, let lastRecordedAudio {
                state = .transcribing
                overlayController?.showTranscribing()
                pendingTranscriptionTask?.cancel()
                pendingTranscriptionTask = Task { [weak self] in
                    await self?.transcribe(audio: lastRecordedAudio, client: transcriptionClient)
                }
            } else {
                overlayController?.hide()
                state = .idle
            }
        } catch AudioCaptureEngine.Error.nothingCaptured {
            overlayController?.hide()
            lastRecordedAudio = nil
            state = .idle
        } catch {
            overlayController?.hide()
            setUnavailable(title: "Recording Failed", message: "Recording could not be finalized.")
        }
    }

    private func cancelRecordingIfNeeded() {
        guard case .recording = state else { return }

        pendingStartTask?.cancel()
        audioCaptureEngine?.cancelCapture()
        overlayController?.hide()
        lastRecordedAudio = nil
        lastTranscript = nil
        lifecycle?.recordingDidCancel()
        state = .idle
    }

    private func toggleRecording() {
        switch state {
        case .idle:
            startRecordingIfPossible()
        case .recording:
            stopRecordingIfNeeded()
        case .unavailable, .transcribing, .inserting:
            break
        }
    }

    private func transcribe(audio: RecordedAudio, client: any AudioTranscribing) async {
        do {
            let result = try await client.transcribe(audio: audio)
            overlayController?.hide()
            lastTranscript = result.text
            if let textInsertionService {
                state = .inserting
                let insertionOutcome = await textInsertionService.insert(result.text)
                switch insertionOutcome {
                case .insertedDirectly, .insertedViaPaste:
                    break
                case .clipboardFallback:
                    break
                }
            }
            state = .idle
        } catch let error as TranscriptionClient.Error {
            overlayController?.hide()
            switch error {
            case .missingAuthToken:
                setUnavailable(
                    title: "Auth Token Missing",
                    message: "Codex could not provide a ChatGPT token for transcription."
                )
            case .unsupportedAuthMethod:
                setUnavailable(
                    title: "Unsupported Auth",
                    message: "Codex is signed in with an unsupported auth method."
                )
            case .httpStatus(let status):
                setUnavailable(
                    title: "Transcription Failed",
                    message: "Transcription failed with HTTP \(status)."
                )
            case .invalidResponse:
                setUnavailable(
                    title: "Transcription Failed",
                    message: "Transcription returned an invalid response."
                )
            case .requestFailed(let message):
                setUnavailable(
                    title: "Transcription Failed",
                    message: "Transcription request failed: \(message)"
                )
            }
        } catch {
            overlayController?.hide()
            setUnavailable(
                title: "Transcription Failed",
                message: "Transcription failed: \(error.localizedDescription)"
            )
        }
    }

    private func beginRecording() async {
        defer {
            pendingStartTask = nil
        }

        guard !Task.isCancelled else { return }

        let microphoneMessage = "Microphone permission is required before dictation can record."

        if let permissionCoordinator {
            switch permissionCoordinator.microphoneStatus() {
            case .notDetermined:
                guard await permissionCoordinator.requestMicrophonePermission() else {
                    setUnavailable(title: "Microphone Required", message: microphoneMessage)
                    return
                }

                guard !Task.isCancelled else { return }
                performRecordingStart()
                return
            case .granted:
                performRecordingStart()
                return
            case .denied, .restricted:
                setUnavailable(title: "Microphone Required", message: microphoneMessage)
                return
            }
        }

        performRecordingStart()
    }

    private func performRecordingStart() {
        do {
            try audioCaptureEngine?.startCapture { [weak self] levels in
                self?.overlayController?.update(levels: levels)
            }
            overlayController?.show()
            let mode = settingsStore.preferences.recordingMode
            state = .recording(mode: mode)
            lifecycle?.recordingDidStart()
        } catch {
            setUnavailable(title: "Recording Failed", message: "Microphone capture failed to start.")
        }
    }

    private func observePreferences() {
        preferencesCancellable = settingsStore.$preferences
            .dropFirst()
            .sink { [weak self] preferences in
                self?.configureHotkey(using: preferences)
            }
    }

    private func configureHotkey(using preferences: AppPreferences) {
        do {
            try hotkeyService.configure(
                descriptor: preferences.hotkey,
                mode: preferences.recordingMode
            )
            hotkeyErrorMessage = nil
        } catch {
            hotkeyErrorMessage = message(for: error)
        }
    }

    private func message(for error: Swift.Error) -> String {
        if let error = error as? GlobalHotkeyService.Error {
            switch error {
            case .invalidDescriptor(let validationError):
                return HotkeyDescriptor.errorMessage(for: validationError)
            case .registrationConflict:
                return "That shortcut is already reserved by another app."
            case .registrationFailed(let status):
                return "Unable to register the shortcut (OSStatus \(status))."
            }
        }

        if let error = error as? HotkeyDescriptor.ValidationError {
            return HotkeyDescriptor.errorMessage(for: error)
        }

        return "Unable to update the global shortcut."
    }
}
