import Combine
import Foundation

@MainActor
protocol DictationLifecycleControlling: AnyObject {
    func recordingDidStart()
    func recordingDidStop()
    func recordingDidCancel()
}

struct RecentActionFeedback: Equatable {
    enum Phase: Equatable {
        case processing(actionName: String)
        case copied
        case failed(message: String)
    }

    let transcriptID: TranscriptionHistoryItem.ID
    let phase: Phase
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
    @Published private(set) var recentActionFeedback: RecentActionFeedback?

    private struct RecordingContext {
        let route: DictationRoute
        let mode: RecordingMode
        let wordReplacements: [WordReplacement]
    }

    private enum ProcessingDestination: Equatable {
        case insertion
        case clipboard(transcriptID: TranscriptionHistoryItem.ID)
    }

    private let settingsStore: SettingsStore
    private let hotkeyService: any GlobalHotkeyControlling
    private let transcriptionHistoryStore: any TranscriptionHistoryStoring
    private let permissionCoordinator: (any PermissionCoordinating)?
    private let audioCaptureEngine: (any AudioCaptureControlling)?
    private let overlayController: (any RecordingOverlayControlling)?
    private let codexStatusMonitor: CodexAuthStatusMonitor?
    private let transcriptionClient: (any AudioTranscribing)?
    private let textProcessor: (any TextProcessing)?
    private let textInsertionService: (any TextInserting)?
    private let clipboardService: (any ClipboardControlling)?
    private weak var lifecycle: DictationLifecycleControlling?
    private var preferencesCancellable: AnyCancellable?
    private var pendingStartTask: Task<Void, Never>?
    private var pendingStopTask: Task<Void, Never>?
    private var pendingTranscriptionTask: Task<Void, Never>?
    private var recordingStartID: UUID?
    private var activeContext: RecordingContext?
    private var processingID: UUID?
    private var processingSourceText: String?
    private var processingDestination: ProcessingDestination?
    private var recentActionFeedbackTask: Task<Void, Never>?
    private var suppressPreferenceReconfiguration = false

    init(
        settingsStore: SettingsStore,
        hotkeyService: any GlobalHotkeyControlling,
        transcriptionHistoryStore: any TranscriptionHistoryStoring = TranscriptionHistoryStore(),
        permissionCoordinator: (any PermissionCoordinating)? = nil,
        audioCaptureEngine: (any AudioCaptureControlling)? = nil,
        overlayController: (any RecordingOverlayControlling)? = nil,
        codexStatusMonitor: CodexAuthStatusMonitor? = nil,
        transcriptionClient: (any AudioTranscribing)? = nil,
        textProcessor: (any TextProcessing)? = nil,
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
        self.textProcessor = textProcessor
        self.textInsertionService = textInsertionService
        self.clipboardService = clipboardService
        self.lifecycle = lifecycle
        self.state = initialState
        self.transcriptionHistory = transcriptionHistoryStore.load()
        self.recentActionFeedback = nil

        hotkeyService.onEvent = { [weak self] event in self?.handleHotkeyEvent(event) }

        configureHotkeys(using: settingsStore.preferences)
        refreshPermissionStatuses()
        observePreferences()

        if codexStatusMonitor != nil {
            Task { [weak self] in await self?.refreshCodexAvailability() }
        }
    }

    func setReady() { state = .idle }
    func setUnavailable(title: String = "Unavailable", message: String) {
        state = .unavailable(title: title, message: message)
    }
    func setFailed(title: String, message: String) { state = .failed(title: title, message: message) }
    func enterTranscribing() { state = .transcribing }
    func enterInserting() { state = .inserting }
    func finishActiveWork() { state = .idle }

    func copyTranscript(id: TranscriptionHistoryItem.ID) {
        guard let item = transcriptionHistory.first(where: { $0.id == id }) else { return }
        clipboardService?.setString(item.text)
    }

    func applyDictationAction(id actionID: DictationAction.ID, toTranscriptID transcriptID: TranscriptionHistoryItem.ID) {
        guard canStartRecording,
              pendingStartTask == nil,
              pendingStopTask == nil,
              let item = transcriptionHistory.first(where: { $0.id == transcriptID }),
              let action = settingsStore.preferences.dictationActions.first(where: { $0.id == actionID }) else {
            return
        }

        let operationID = beginProcessing(
            sourceText: item.text,
            action: action,
            destination: .clipboard(transcriptID: transcriptID)
        )
        pendingTranscriptionTask = Task { [weak self] in
            await self?.performProcessing(
                operationID: operationID,
                sourceText: item.text,
                action: action,
                destination: .clipboard(transcriptID: transcriptID)
            )
        }
    }

    func recentActionFeedback(for transcriptID: TranscriptionHistoryItem.ID) -> RecentActionFeedback.Phase? {
        guard recentActionFeedback?.transcriptID == transcriptID else { return nil }
        return recentActionFeedback?.phase
    }

    var canApplyActionToRecent: Bool {
        canStartRecording && pendingStartTask == nil && pendingStopTask == nil
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
            var updated = settingsStore.preferences
            updated.hotkey = descriptor
            try updated.validateDictationActions()
            try applyHotkeyConfiguration(updated) { settingsStore.updateHotkey(descriptor) }
            hotkeyErrorMessage = nil
        } catch {
            hotkeyErrorMessage = userMessage(for: error)
        }
    }

    func saveDictationAction(_ action: DictationAction) throws {
        var actions = settingsStore.preferences.dictationActions
        if let index = actions.firstIndex(where: { $0.id == action.id }) {
            actions[index] = action
        } else {
            actions.append(action)
        }
        let updated = try settingsStore.preferences.sanitizedAndValidated(actions: actions)
        try applyHotkeyConfiguration(updated) {
            try settingsStore.updateDictationActions(updated.dictationActions)
        }
        hotkeyErrorMessage = nil
    }

    func deleteDictationAction(id: UUID) throws {
        let actions = settingsStore.preferences.dictationActions.filter { $0.id != id }
        let updated = try settingsStore.preferences.sanitizedAndValidated(actions: actions)
        try applyHotkeyConfiguration(updated) {
            try settingsStore.updateDictationActions(updated.dictationActions)
        }
        hotkeyErrorMessage = nil
    }

    func userMessage(for error: Swift.Error) -> String {
        if let validationError = error as? DictationActionValidationError {
            return validationError.localizedDescription
        }
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

    func handleHotkeyEvent(_ event: GlobalHotkeyService.Event) {
        switch event.kind {
        case .pressed:
            guard let route = event.route else { return }
            startRecordingIfPossible(route: route)
        case .released:
            guard let route = event.route else { return }
            stopRecordingIfNeeded(route: route)
        case .toggle:
            guard let route = event.route else { return }
            toggleRecording(route: route)
        case .cancel:
            cancelActiveWorkIfNeeded()
        }
    }

    private func startRecordingIfPossible(route: DictationRoute) {
        guard canStartRecording, pendingStartTask == nil, pendingStopTask == nil else { return }
        refreshPermissionStatuses()
        if permissionCoordinator != nil,
           microphonePermissionStatus == .denied || microphonePermissionStatus == .restricted {
            setUnavailable(
                title: "Microphone Required",
                message: "Microphone permission is required before dictation can record."
            )
            return
        }
        launchRecordingStart(route: route)
    }

    private func stopRecordingIfNeeded(route: DictationRoute) {
        guard activeContext?.route.identifiesSameShortcut(as: route) == true else { return }
        if recordingStartID != nil {
            cancelPendingRecordingStart()
            return
        }
        guard case .recording = state, pendingStopTask == nil else { return }
        state = .transcribing
        overlayController?.showTranscribing()
        pendingStopTask = Task { [weak self] in await self?.finishRecording() }
    }

    private func cancelActiveWorkIfNeeded() {
        if processingID != nil, let sourceText = processingSourceText {
            let destination = processingDestination
            processingID = nil
            processingSourceText = nil
            processingDestination = nil
            pendingTranscriptionTask?.cancel()
            pendingTranscriptionTask = nil
            overlayController?.hide()
            switch destination {
            case .insertion:
                lastTranscript = sourceText
                appendHistoryItemIfNeeded(sourceText)
            case .clipboard:
                recentActionFeedback = nil
            case nil:
                break
            }
            activeContext = nil
            state = .idle
            return
        }
        if recordingStartID != nil {
            cancelPendingRecordingStart()
            return
        }
        guard case .recording = state else { return }
        overlayController?.hide()
        lastRecordedAudio = nil
        lastTranscript = nil
        activeContext = nil
        lifecycle?.recordingDidCancel()
        state = .idle
        beginCaptureCleanup()
    }

    private func toggleRecording(route: DictationRoute) {
        switch state {
        case .idle, .failed:
            startRecordingIfPossible(route: route)
        case .recording:
            stopRecordingIfNeeded(route: route)
        case .unavailable, .transcribing, .processing, .inserting:
            break
        }
    }

    private func transcribe(audio: RecordedAudio, client: any AudioTranscribing, context: RecordingContext) async {
        do {
            let result = try await client.transcribe(audio: audio)
            let sourceText = TranscriptReplacementEngine.apply(context.wordReplacements, to: result.text)
            switch context.route {
            case .plain:
                await insertAndStore(sourceText)
            case .action(let action):
                await process(sourceText: sourceText, action: action)
            }
        } catch is CancellationError {
            return
        } catch let error as TranscriptionClient.Error {
            overlayController?.hide()
            activeContext = nil
            switch error {
            case .missingAuthToken:
                setUnavailable(title: "Auth Token Missing", message: "Codex could not provide a ChatGPT token for transcription.")
            case .unsupportedAuthMethod:
                setUnavailable(title: "Unsupported Auth", message: "Codex is signed in with an unsupported auth method.")
            case .httpStatus(let status):
                setFailed(title: "Transcription Failed", message: "Transcription failed with HTTP \(status).")
            case .invalidResponse:
                setFailed(title: "Transcription Failed", message: "Transcription returned an invalid response.")
            case .requestFailed(let message):
                setFailed(title: "Transcription Failed", message: "Transcription request failed: \(message)")
            }
        } catch {
            overlayController?.hide()
            activeContext = nil
            setFailed(title: "Transcription Failed", message: "Transcription failed: \(error.localizedDescription)")
        }
    }

    private func process(sourceText: String, action: DictationAction) async {
        let operationID = beginProcessing(
            sourceText: sourceText,
            action: action,
            destination: .insertion
        )
        await performProcessing(
            operationID: operationID,
            sourceText: sourceText,
            action: action,
            destination: .insertion
        )
    }

    private func beginProcessing(
        sourceText: String,
        action: DictationAction,
        destination: ProcessingDestination
    ) -> UUID {
        recentActionFeedbackTask?.cancel()
        let operationID = UUID()
        processingID = operationID
        processingSourceText = sourceText
        processingDestination = destination
        state = .processing(actionName: action.name)
        switch destination {
        case .insertion:
            overlayController?.showProcessing(actionName: action.name)
        case .clipboard(let transcriptID):
            recentActionFeedback = RecentActionFeedback(
                transcriptID: transcriptID,
                phase: .processing(actionName: action.name)
            )
        }
        return operationID
    }

    private func performProcessing(
        operationID: UUID,
        sourceText: String,
        action: DictationAction,
        destination: ProcessingDestination
    ) async {
        guard let textProcessor else {
            completeProcessingFailure(
                operationID: operationID,
                sourceText: sourceText,
                destination: destination,
                message: "Codex processing is unavailable."
            )
            return
        }
        do {
            let processedText = try await textProcessor.process(sourceText: sourceText, action: action)
            guard processingID == operationID else { return }
            processingID = nil
            processingSourceText = nil
            processingDestination = nil
            pendingTranscriptionTask = nil
            switch destination {
            case .insertion:
                await insertAndStore(processedText)
            case .clipboard(let transcriptID):
                clipboardService?.setString(processedText)
                state = .idle
                showRecentActionCopied(transcriptID: transcriptID)
            }
        } catch {
            guard processingID == operationID else { return }
            completeProcessingFailure(
                operationID: operationID,
                sourceText: sourceText,
                destination: destination,
                message: processingFailureMessage(for: error)
            )
        }
    }

    private func completeProcessingFailure(
        operationID: UUID,
        sourceText: String,
        destination: ProcessingDestination,
        message: String
    ) {
        guard processingID == operationID else { return }
        processingID = nil
        processingSourceText = nil
        processingDestination = nil
        pendingTranscriptionTask = nil
        switch destination {
        case .insertion:
            failProcessing(sourceText: sourceText, message: message)
        case .clipboard(let transcriptID):
            recentActionFeedback = RecentActionFeedback(
                transcriptID: transcriptID,
                phase: .failed(message: message)
            )
            setFailed(title: "Processing Failed", message: message)
        }
    }

    private func showRecentActionCopied(transcriptID: TranscriptionHistoryItem.ID) {
        let feedback = RecentActionFeedback(transcriptID: transcriptID, phase: .copied)
        recentActionFeedback = feedback
        recentActionFeedbackTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            guard self?.recentActionFeedback == feedback else { return }
            self?.recentActionFeedback = nil
            self?.recentActionFeedbackTask = nil
        }
    }

    private func insertAndStore(_ text: String) async {
        lastTranscript = text
        appendHistoryItemIfNeeded(text)
        state = .inserting
        overlayController?.showInserting()
        if let textInsertionService { _ = await textInsertionService.insert(text) }
        overlayController?.hide()
        refreshPermissionStatuses()
        activeContext = nil
        state = .idle
    }

    private func failProcessing(sourceText: String, message: String) {
        overlayController?.hide()
        lastTranscript = sourceText
        appendHistoryItemIfNeeded(sourceText)
        activeContext = nil
        setFailed(title: "Processing Failed", message: message)
    }

    private func processingFailureMessage(for error: Swift.Error) -> String {
        guard let error = error as? CodexAppServerClient.Error else {
            return "Codex processing failed: \(error.localizedDescription)"
        }
        switch error {
        case .unavailableModel:
            return "The selected Codex model is no longer available. Edit the action and choose another model."
        case .unsupportedReasoningEffort:
            return "The selected reasoning effort is no longer available for this model. Edit the action and choose another effort."
        case .timedOut:
            return "Codex processing timed out. Try again."
        case .invalidOutput:
            return "Codex returned an invalid result. Try again."
        case .interrupted:
            return "Codex processing was cancelled."
        case .binaryMissing:
            return "Codex is not installed or could not be found."
        case .processLaunchFailed(let message), .transportFailure(let message), .turnFailed(let message):
            return "Codex processing failed: \(message)"
        case .rpcFailure(_, let message):
            return "Codex processing failed: \(message)"
        case .invalidResponse:
            return "Codex returned an invalid response. Try again."
        }
    }

    private func appendHistoryItemIfNeeded(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        transcriptionHistory.insert(TranscriptionHistoryItem(id: UUID(), text: text, createdAt: Date()), at: 0)
        transcriptionHistory = Array(transcriptionHistory.prefix(10))
        transcriptionHistoryStore.save(transcriptionHistory)
    }

    private func launchRecordingStart(route: DictationRoute) {
        let startID = UUID()
        let preferences = settingsStore.preferences
        let context = RecordingContext(
            route: route,
            mode: preferences.recordingMode,
            wordReplacements: preferences.wordReplacements
        )
        activeContext = context
        recordingStartID = startID
        pendingStartTask = Task { [weak self] in await self?.beginRecording(id: startID, context: context) }
    }

    private func beginRecording(id startID: UUID, context: RecordingContext) async {
        guard isCurrentRecordingStart(startID) else { return }
        let microphoneMessage = "Microphone permission is required before dictation can record."
        if let permissionCoordinator {
            refreshPermissionStatuses()
            switch microphonePermissionStatus {
            case .notDetermined:
                guard await permissionCoordinator.requestMicrophonePermission() else {
                    guard isCurrentRecordingStart(startID) else { return }
                    refreshPermissionStatuses()
                    activeContext = nil
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
                activeContext = nil
                setUnavailable(title: "Microphone Required", message: microphoneMessage)
                finishRecordingStart(id: startID)
                return
            }
        }
        guard isCurrentRecordingStart(startID) else { return }
        overlayController?.show()
        state = .recording(mode: context.mode)
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
            activeContext = nil
            state = .idle
            finishRecordingStart(id: startID)
        } catch {
            guard isCurrentRecordingStart(startID) else { return }
            overlayController?.hide()
            activeContext = nil
            setFailed(title: "Recording Failed", message: "Microphone capture failed to start. Try again.")
            finishRecordingStart(id: startID)
        }
    }

    private func finishRecording() async {
        defer { pendingStopTask = nil }
        do {
            lastRecordedAudio = try await audioCaptureEngine?.stopCapture()
            lifecycle?.recordingDidStop()
            if let transcriptionClient, let lastRecordedAudio, let activeContext {
                pendingTranscriptionTask?.cancel()
                pendingTranscriptionTask = Task { [weak self] in
                    await self?.transcribe(audio: lastRecordedAudio, client: transcriptionClient, context: activeContext)
                }
            } else {
                overlayController?.hide()
                activeContext = nil
                state = .idle
            }
        } catch AudioCaptureEngine.Error.nothingCaptured {
            overlayController?.hide()
            lastRecordedAudio = nil
            activeContext = nil
            state = .idle
        } catch {
            overlayController?.hide()
            activeContext = nil
            setFailed(title: "Recording Failed", message: "Recording could not be finalized.")
        }
    }

    private func cancelPendingRecordingStart() {
        recordingStartID = nil
        pendingStartTask?.cancel()
        pendingStartTask = nil
        overlayController?.hide()
        lastRecordedAudio = nil
        activeContext = nil
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
        case .unavailable, .recording, .transcribing, .processing, .inserting:
            false
        }
    }

    private func clearPermissionBlockerIfReady() {
        guard case .unavailable(let title, _) = state else { return }
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
                guard let self, !self.suppressPreferenceReconfiguration else { return }
                self.configureHotkeys(using: configuration)
            }
    }

    private func applyHotkeyConfiguration(_ preferences: AppPreferences, persist: () throws -> Void) throws {
        try hotkeyService.configure(
            registrations: Self.registrations(for: preferences),
            mode: preferences.recordingMode
        )
        suppressPreferenceReconfiguration = true
        defer { suppressPreferenceReconfiguration = false }
        try persist()
    }

    private func configureHotkeys(using preferences: AppPreferences) {
        configureHotkeys(using: HotkeyConfiguration(preferences: preferences))
    }

    private func configureHotkeys(using configuration: HotkeyConfiguration) {
        do {
            try hotkeyService.configure(registrations: configuration.registrations, mode: configuration.recordingMode)
            hotkeyErrorMessage = nil
        } catch {
            hotkeyErrorMessage = userMessage(for: error)
        }
    }

    private static func registrations(for preferences: AppPreferences) -> [DictationHotkeyRegistration] {
        [DictationHotkeyRegistration(descriptor: preferences.hotkey, route: .plain)]
            + preferences.dictationActions.compactMap { action in
                guard let hotkey = action.hotkey else { return nil }
                return DictationHotkeyRegistration(descriptor: hotkey, route: .action(action))
            }
    }
}

private struct HotkeyConfiguration: Equatable {
    let registrations: [DictationHotkeyRegistration]
    let recordingMode: RecordingMode

    init(preferences: AppPreferences) {
        registrations = [DictationHotkeyRegistration(descriptor: preferences.hotkey, route: .plain)]
            + preferences.dictationActions.compactMap { action in
                guard let hotkey = action.hotkey else { return nil }
                return DictationHotkeyRegistration(descriptor: hotkey, route: .action(action))
            }
        recordingMode = preferences.recordingMode
    }
}
