import AppKit
import SwiftUI

@MainActor
protocol RecordingOverlayControlling: AnyObject {
    func show()
    func update(level: Float)
    func hide()
}

@MainActor
final class RecordingOverlayWindowController: NSWindowController, RecordingOverlayControlling {
    private let model = RecordingOverlayModel()

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true

        let hostingView = NSHostingView(rootView: RecordingOverlayView(model: model))
        panel.contentView = hostingView

        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        guard let window, let screen = NSScreen.main else { return }

        let size = window.frame.size
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.midX - (size.width / 2),
            y: frame.minY + 40
        )

        model.level = 0
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
    }

    func update(level: Float) {
        model.level = CGFloat(min(max(level, 0), 1))
    }

    func hide() {
        window?.orderOut(nil)
    }
}
