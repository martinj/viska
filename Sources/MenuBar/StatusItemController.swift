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
        popover.animates = true
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
        MainActor.assumeIsolated {
            if popover.isShown {
                popover.performClose(sender)
                return
            }

            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
