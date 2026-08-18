import AppKit
import SwiftUI

@MainActor
protocol RecordingOverlayControlling: AnyObject {
    func show()
    func update(levels: [Float])
    func showTranscribing()
    func showProcessing(actionName: String)
    func showInserting()
    func hide()
}

@MainActor
final class RecordingOverlayWindowController: NSWindowController, RecordingOverlayControlling {
    private let model = RecordingOverlayModel()

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 52),
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

        model.phase = .recording
        model.levels = [CGFloat](repeating: 0, count: AudioLevelAnalyzer.bandCount)
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
    }

    func update(levels: [Float]) {
        model.levels = levels.map { CGFloat(min(max($0, 0), 1)) }
    }

    func showTranscribing() {
        model.phase = .transcribing
    }

    func showProcessing(actionName: String) {
        model.phase = .processing(actionName: actionName)
    }

    func showInserting() {
        model.phase = .inserting
    }

    func hide() {
        window?.orderOut(nil)
    }
}
