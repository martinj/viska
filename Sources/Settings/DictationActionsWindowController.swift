import AppKit
import SwiftUI

@MainActor
final class DictationActionsWindowController: NSWindowController {
    private let model: DictationActionsEditorModel

    init(
        settingsStore: SettingsStore,
        dictationStore: DictationStore,
        modelDiscoverer: any CodexModelDiscovering
    ) {
        model = DictationActionsEditorModel(
            settingsStore: settingsStore,
            dictationStore: dictationStore,
            modelDiscoverer: modelDiscoverer
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dictation Actions"
        window.minSize = NSSize(width: 740, height: 540)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: DictationActionsView(model: model))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        Task { await model.prepareForPresentation() }
    }
}
