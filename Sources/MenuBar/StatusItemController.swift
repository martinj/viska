import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let dependencies: AppDependencies
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        super.init()
    }

    func install() {
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 300, height: 320)
        popover.contentViewController = NSHostingController(
            rootView: MenuContentView(
                settingsStore: dependencies.settingsStore,
                dictationStore: dependencies.dictationStore
            )
        )

        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "mic.fill",
            accessibilityDescription: "VoiceCompanion"
        )
        button.action = #selector(togglePopover(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc
    nonisolated private func togglePopover(_ sender: NSStatusBarButton) {
        Task { @MainActor [weak self] in
            self?.togglePopoverOnMainActor()
        }
    }

    private func togglePopoverOnMainActor() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(button)
            return
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
