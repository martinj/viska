import AppKit
import SwiftUI

@MainActor
final class WordReplacementsWindowController: NSWindowController, NSWindowDelegate {
    private let model: WordReplacementsEditorModel

    init(settingsStore: SettingsStore) {
        self.model = WordReplacementsEditorModel(settingsStore: settingsStore)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Word Replacements"
        window.minSize = NSSize(width: 380, height: 260)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: WordReplacementsView(model: model)
        )
        window.center()

        super.init(window: window)

        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.pruneIncompleteRules()
    }
}
