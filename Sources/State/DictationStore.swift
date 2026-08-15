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
    @Published private(set) var microphonePermissionStatus: PermissionStatus = .granted
    @Published private(set) var accessibilityPermissionStatus: PermissionStatus = .granted
    @Published private(set) var transcriptionHistory: [TranscriptionHistoryItem]

    private let settingsStore: SettingsStore
    private let hotkeyService: any GlobalHotkeyControlling
    private let transcriptionHistoryStore: any TranscriptionHistoryStoring
    private let permissionCoordinator: (any PermissionCoordinating)?
    private let audioCaptureEngine: (any AudioCaptureControlling)?
    private let overlayController: (any RecordingOverlayControlling)?
    private let codexStatusMonitor: CodexAuthStatusMonitor?
    private let transcriptionClient: (any AudioTranscribing)?
    private let textInsertionService: (any TextInserting)?
    private let clipboardService: (any ClipboardControlling)?
    private weak var lifecycle: DictationLifecycleControlling?
    private var preferencesCancellable: AnyCancellable?
    private var pendingStartTask: Task<Void, Never>?
    private var pendingStopTask: Task<Void, Never>?
    private var pendingTranscriptionTask: Task<Void, Never>?
    private var recordingStartID: UUID?

    init(
        settingsStore: SettingsStore,
        hotkeyService: any GlobalHotkeyControlling,
        transcriptionHistoryStore: any TranscriptionHistoryStoring = TranscriptionHistoryStore(),
        permissionCoordinator: (any PermissionCoordinating)? = nil,
        audioCaptureEngine: (any AudioCaptureControlling)? = nil,
        overlayController: (any RecordingOverlayControlling)? = nil,
        codexStatusMonitor: CodexAuthStatusMonitor? = nil,
        transcriptionClient: (any AudioTranscribing)? = nil,
        textInsertionService: (any TextInserting)? = nil,
        clipboardService: (any ClipboardControlling)? = nil,
        lifecycle: DictationLifecycleControlling? = nil,
        initialState: DictationState = .unavailable(title: "Checking Codex", message: "Codex setup is not ready yet.")
    ) {
        self.settingsStore = settingsStore
        self.hotkeyService = hotkeyService
        self.transcriptionHistoryStore = transcriptionHistoryStore
        self.permissionCoordinator = permissionCoordinator
        self.audioCaptureEngine = audioCaptureEngine
        self.overlayController = overlayController
        self.codexStatusMonitor = codexStatusMonitor
        self.transcriptionClient = transcriptionClient
        self.textInsertionService = textInsertionService
        self.clipboardService = clipboardService
        self.lifecycle = lifecycle
        self.state = initialState
        self.transcriptionHistory = transcriptionHistoryStore.load()

        hotkeyService.onEvent = { [weak self] event in
            self?.handleHotkeyEvent(event)
        }

        configureHotkey(using: settingsStore.preferences)
        refreshPermissionStatuses()
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

    func setFailed(title: String, message: String) {
        state = .failed(title: title, message: message)
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

    func copyTranscript(id: TranscriptionHistoryItem.ID) {
        guard let item = transcriptionHistory.first(where: { $0.id == id }) else { return }
        clipboardService?.setString(item.text)
    }

    func refreshPermissionStatuses() {
        guard let permissionCoordinator else {
            microphonePermissionStatus = .granted
            accessibilityPermissionStatus = .granted
            clearPermissionBlockerIfReady()
            return
        }

        microphonePermissionStatus = permissionCoordinator.microphoneStatus()
        accessibilityPermissionStatus = permissionCoordinator.accessibilityStatus()
        clearPermissionBlockerIfReady()
    }

    func requestMicrophonePermission() async {
        guard let permissionCoordinator else { return }

        refreshPermissionStatuses()
        switch microphonePermissionStatus {
        case .granted:
            return
        case .notDetermined:
            _ = await permissionCoordinator.requestMicrophonePermission()
        case .denied, .restricted:
            permissionCoordinator.openMicrophoneSettings()
        }

        refreshPermissionStatuses()
    }

    func requestAccessibilityPermission() {
        guard let permissionCoordinator else { return }

        refreshPermissionStatuses()
        guard accessibilityPermissionStatus != .granted else { return }

        if !permissionCoordinator.requestAccessibilityPermission(prompt: true) {
            permissionCoordinator.openAccessibilitySettings()
        }

        refreshPermissionStatuses()
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
        guard canStartRecording,
              pendingStartTask == nil,
              pendingStopTask == nil else { return }

        let microphoneMessage = "Microphone permission is required before dictation can record."
        refreshPermissionStatuses()

        if permissionCoordinator != nil {
            switch microphonePermissionStatus {
            case .granted:
                launchRecordingStart()
                return
            case .denied, .restricted:
                setUnavailable(title: "Microphone Required", message: microphoneMessage)
                return
            case .notDetermined:
                break
            }
        }

        if permissionCoordinator == nil {
            launchRecordingStart()
            return
        }

        launchRecordingStart()
    }

    private func stopRecordingIfNeeded() {
        if recordingStartID != nil {
            cancelPendingRecordingStart()
            return
        }

        guard case .recording = state, pendingStopTask == nil else { return }

        state = .transcribing
        overlayController?.showTranscribing()
        pendingStopTask = Task { [weak self] in
            await self?.finishRecording()
        }
    }

    private func cancelRecordingIfNeeded() {
        if recordingStartID != nil {
            cancelPendingRecordingStart()
            return
        }

        guard case .recording = state else { return }

        overlayController?.hide()
        lastRecordedAudio = nil
        lastTranscript = nil
        lifecycle?.recordingDidCancel()
        state = .idle
        beginCaptureCleanup()
    }

    private func toggleRecording() {
        switch state {
        case .idle, .failed:
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
            let processedText = TranscriptReplacementEngine.apply(
                settingsStore.preferences.wordReplacements,
                to: result.text
            )
            overlayController?.hide()
            lastTranscript = processedText
            appendHistoryItemIfNeeded(processedText)
            if let textInsertionService {
                state = .inserting
                let insertionOutcome = await textInsertionService.insert(processedText)
                switch insertionOutcome {
                case .insertedDirectly, .insertedViaPaste:
                    break
                case .clipboardFallback:
                    break
                }
            }
            refreshPermissionStatuses()
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
                setFailed(
                    title: "Transcription Failed",
                    message: "Transcription failed with HTTP \(status)."
                )
            case .invalidResponse:
                setFailed(
                    title: "Transcription Failed",
                    message: "Transcription returned an invalid response."
                )
            case .requestFailed(let message):
                setFailed(
                    title: "Transcription Failed",
                    message: "Transcription request failed: \(message)"
                )
            }
        } catch {
            overlayController?.hide()
            setFailed(
                title: "Transcription Failed",
                message: "Transcription failed: \(error.localizedDescription)"
            )
        }
    }

    private func appendHistoryItemIfNeeded(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        transcriptionHistory.insert(
            TranscriptionHistoryItem(id: UUID(), text: text, createdAt: Date()),
            at: 0
        )
        transcriptionHistory = Array(transcriptionHistory.prefix(10))
        transcriptionHistoryStore.save(transcriptionHistory)
    }

    private func launchRecordingStart() {
        let startID = UUID()
        recordingStartID = startID
        pendingStartTask = Task { [weak self] in
            await self?.beginRecording(id: startID)
        }
    }

    private func beginRecording(id startID: UUID) async {
        guard isCurrentRecordingStart(startID) else { return }

        let microphoneMessage = "Microphone permission is required before dictation can record."

        if let permissionCoordinator {
            refreshPermissionStatuses()
            switch microphonePermissionStatus {
            case .notDetermined:
                guard await permissionCoordinator.requestMicrophonePermission() else {
                    guard isCurrentRecordingStart(startID) else { return }
                    refreshPermissionStatuses()
                    setUnavailable(title: "Microphone Required", message: microphoneMessage)
                    finishRecordingStart(id: startID)
                    return
                }

                refreshPermissionStatuses()
                guard isCurrentRecordingStart(startID) else { return }
            case .granted:
                break
            case .denied, .restricted:
                guard isCurrentRecordingStart(startID) else { return }
                setUnavailable(title: "Microphone Required", message: microphoneMessage)
                finishRecordingStart(id: startID)
                return
            }
        }

        guard isCurrentRecordingStart(startID) else { return }
        overlayController?.show()
        state = .recording(mode: settingsStore.preferences.recordingMode)

        do {
            try await audioCaptureEngine?.startCapture { [weak self] levels in
                self?.overlayController?.update(levels: levels)
            }

            guard isCurrentRecordingStart(startID) else { return }
            finishRecordingStart(id: startID)
            lifecycle?.recordingDidStart()
        } catch is CancellationError {
            guard isCurrentRecordingStart(startID) else { return }
            overlayController?.hide()
            state = .idle
            finishRecordingStart(id: startID)
        } catch {
            guard isCurrentRecordingStart(startID) else { return }
            overlayController?.hide()
            setFailed(title: "Recording Failed", message: "Microphone capture failed to start. Try again.")
            finishRecordingStart(id: startID)
        }
    }

    private func finishRecording() async {
        defer {
            pendingStopTask = nil
        }

        do {
            lastRecordedAudio = try await audioCaptureEngine?.stopCapture()
            lifecycle?.recordingDidStop()

            if let transcriptionClient, let lastRecordedAudio {
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
            setFailed(title: "Recording Failed", message: "Recording could not be finalized.")
        }
    }

    private func cancelPendingRecordingStart() {
        recordingStartID = nil
        pendingStartTask?.cancel()
        pendingStartTask = nil
        overlayController?.hide()
        lastRecordedAudio = nil
        state = .idle
        beginCaptureCleanup()
    }

    private func beginCaptureCleanup() {
        pendingStartTask = Task { [weak self, audioCaptureEngine] in
            await audioCaptureEngine?.cancelCapture()
            self?.pendingStartTask = nil
        }
    }

    private func isCurrentRecordingStart(_ startID: UUID) -> Bool {
        recordingStartID == startID && !Task.isCancelled
    }

    private func finishRecordingStart(id startID: UUID) {
        guard recordingStartID == startID else { return }
        recordingStartID = nil
        pendingStartTask = nil
    }

    private var canStartRecording: Bool {
        switch state {
        case .idle, .failed:
            true
        case .unavailable, .recording, .transcribing, .inserting:
            false
        }
    }

    private func clearPermissionBlockerIfReady() {
        guard case .unavailable(let title, _) = state else {
            return
        }

        switch title {
        case "Microphone Required" where microphonePermissionStatus == .granted:
            state = .idle
        case "Accessibility Required" where accessibilityPermissionStatus == .granted:
            state = .idle
        default:
            break
        }
    }

    private func observePreferences() {
        preferencesCancellable = settingsStore.$preferences
            .map(HotkeyConfiguration.init(preferences:))
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] configuration in
                self?.configureHotkey(
                    descriptor: configuration.hotkey,
                    mode: configuration.recordingMode
                )
            }
    }

    private func configureHotkey(using preferences: AppPreferences) {
        configureHotkey(descriptor: preferences.hotkey, mode: preferences.recordingMode)
    }

    private func configureHotkey(descriptor: HotkeyDescriptor, mode: RecordingMode) {
        do {
            try hotkeyService.configure(
                descriptor: descriptor,
                mode: mode
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

private struct HotkeyConfiguration: Equatable {
    let hotkey: HotkeyDescriptor
    let recordingMode: RecordingMode

    init(preferences: AppPreferences) {
        self.hotkey = preferences.hotkey
        self.recordingMode = preferences.recordingMode
    }
}
