import Foundation

@MainActor
final class AppDependencies {
    let settingsStore: SettingsStore
    let hotkeyService: GlobalHotkeyService
    let permissionCoordinator: PermissionCoordinator
    let audioCaptureEngine: AudioCaptureEngine
    let recordingOverlayController: RecordingOverlayWindowController
    let codexProcessManager: CodexProcessManager
    let codexClient: CodexAppServerClient
    let codexStatusMonitor: CodexAuthStatusMonitor
    let transcriptionClient: TranscriptionClient
    let transcriptionHistoryStore: TranscriptionHistoryStore
    let focusedElementResolver: FocusedElementResolver
    let clipboardService: ClipboardService
    let syntheticPasteService: SyntheticPasteService
    let textInsertionService: TextInsertionService
    let dictationStore: DictationStore

    init(
        settingsStore: SettingsStore = SettingsStore(),
        hotkeyService: GlobalHotkeyService = GlobalHotkeyService(),
        permissionCoordinator: PermissionCoordinator = PermissionCoordinator(),
        audioCaptureEngine: AudioCaptureEngine = AudioCaptureEngine(),
        recordingOverlayController: RecordingOverlayWindowController = RecordingOverlayWindowController(),
        codexProcessManager: CodexProcessManager = CodexProcessManager()
    ) {
        self.settingsStore = settingsStore
        self.hotkeyService = hotkeyService
        self.permissionCoordinator = permissionCoordinator
        self.audioCaptureEngine = audioCaptureEngine
        self.recordingOverlayController = recordingOverlayController
        self.codexProcessManager = codexProcessManager
        self.codexClient = CodexAppServerClient(processManager: codexProcessManager)
        self.codexStatusMonitor = CodexAuthStatusMonitor(client: codexClient)
        self.transcriptionClient = TranscriptionClient(authProvider: codexClient)
        self.transcriptionHistoryStore = TranscriptionHistoryStore()
        self.focusedElementResolver = FocusedElementResolver()
        self.clipboardService = ClipboardService()
        self.syntheticPasteService = SyntheticPasteService()
        self.textInsertionService = TextInsertionService(
            permissionCoordinator: permissionCoordinator,
            focusedElementResolver: focusedElementResolver,
            clipboardService: clipboardService,
            syntheticPasteService: syntheticPasteService
        )
        self.dictationStore = DictationStore(
            settingsStore: settingsStore,
            hotkeyService: hotkeyService,
            transcriptionHistoryStore: transcriptionHistoryStore,
            permissionCoordinator: permissionCoordinator,
            audioCaptureEngine: audioCaptureEngine,
            overlayController: recordingOverlayController,
            codexStatusMonitor: codexStatusMonitor,
            transcriptionClient: transcriptionClient,
            textProcessor: codexClient,
            textInsertionService: textInsertionService,
            clipboardService: clipboardService,
            initialState: .unavailable(
                title: "Checking Codex",
                message: "Checking Codex app-server status…"
            )
        )
    }
}
