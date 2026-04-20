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

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func install() {
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 300, height: 380)
        popover.contentViewController = NSHostingController(
            rootView: MenuContentView(
                settingsStore: dependencies.settingsStore,
                dictationStore: dependencies.dictationStore
            )
        )

        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "mic.fill",
            accessibilityDescription: "Viska"
        )
        button.action = #selector(togglePopover(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
    }

    @objc
    nonisolated private func togglePopover(_ sender: NSStatusBarButton) {
        Task { @MainActor [weak self] in
            self?.togglePopoverOnMainActor()
        }
    }

    @objc
    nonisolated private func appDidBecomeActive(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.dependencies.dictationStore.refreshPermissionStatuses()
        }
    }

    private func togglePopoverOnMainActor() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(button)
            return
        }

        dependencies.dictationStore.refreshPermissionStatuses()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
