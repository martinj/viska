import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let dependencies: AppDependencies
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var popoverContentCancellable: AnyCancellable?
    private var wordReplacementsWindowController: WordReplacementsWindowController?

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
        popover.contentViewController = NSHostingController(
            rootView: MenuContentView(
                settingsStore: dependencies.settingsStore,
                dictationStore: dependencies.dictationStore,
                openWordReplacements: { [weak self] in
                    self?.openWordReplacements()
                }
            )
        )
        updatePopoverContentSize()
        popoverContentCancellable = Publishers.CombineLatest3(
            dependencies.dictationStore.$transcriptionHistory,
            dependencies.dictationStore.$state,
            dependencies.dictationStore.$hotkeyErrorMessage
        )
            .sink { [weak self] history, state, hotkeyErrorMessage in
                self?.updatePopoverContentSize(
                    forHistoryCount: history.count,
                    state: state,
                    hotkeyErrorMessage: hotkeyErrorMessage
                )
            }

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
        updatePopoverContentSize()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func openWordReplacements() {
        if popover.isShown {
            popover.performClose(nil)
        }

        let controller: WordReplacementsWindowController
        if let existing = wordReplacementsWindowController {
            controller = existing
        } else {
            controller = WordReplacementsWindowController(
                settingsStore: dependencies.settingsStore
            )
            wordReplacementsWindowController = controller
        }

        controller.present()
    }

    private func updatePopoverContentSize() {
        let dictationStore = dependencies.dictationStore
        updatePopoverContentSize(
            forHistoryCount: dictationStore.transcriptionHistory.count,
            state: dictationStore.state,
            hotkeyErrorMessage: dictationStore.hotkeyErrorMessage
        )
    }

    private func updatePopoverContentSize(
        forHistoryCount historyCount: Int,
        state: DictationState,
        hotkeyErrorMessage: String?
    ) {
        popover.contentSize = MenuContentView.contentSize(
            forHistoryCount: historyCount,
            showsStatusDetail: MenuContentView.showsStatusDetail(for: state),
            showsHotkeyError: hotkeyErrorMessage != nil
        )
    }
}
