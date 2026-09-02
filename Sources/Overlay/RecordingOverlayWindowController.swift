import AppKit
import SwiftUI

@MainActor
protocol RecordingOverlayControlling: AnyObject {
    func show()
    func update(levels: [Float])
    func showTranscribing()
    func showChoosing(_ presentation: PickerPresentation)
    func showProcessing(actionName: String)
    func showInserting()
    func hide()
}

@MainActor
final class RecordingOverlayWindowController: NSWindowController, RecordingOverlayControlling {
    private static let capsuleSize = NSSize(width: 240, height: 52)
    private static let pickerWidth: CGFloat = 420
    private let model = RecordingOverlayModel()

    init() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.capsuleSize),
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
        model.phase = .recording
        model.levels = [CGFloat](repeating: 0, count: AudioLevelAnalyzer.bandCount)
        present(size: Self.capsuleSize)
    }

    func update(levels: [Float]) {
        model.levels = levels.map { CGFloat(min(max($0, 0), 1)) }
    }

    func showTranscribing() {
        model.phase = .transcribing
        present(size: Self.capsuleSize)
    }

    func showChoosing(_ presentation: PickerPresentation) {
        model.phase = .choosing(presentation)
        present(size: NSSize(width: Self.pickerWidth, height: pickerHeight(for: presentation)))
    }

    func showProcessing(actionName: String) {
        model.phase = .processing(actionName: actionName)
        present(size: Self.capsuleSize)
    }

    func showInserting() {
        model.phase = .inserting
        present(size: Self.capsuleSize)
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func pickerHeight(for presentation: PickerPresentation) -> CGFloat {
        let headerHeight: CGFloat = presentation.errorMessage == nil ? 54 : 78
        let rowCount = 1 + presentation.actionNames.count
        return headerHeight + (CGFloat(rowCount) * 36) + 40
    }

    private func present(size: NSSize) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.midX - (size.width / 2),
            y: frame.minY + 40
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.orderFrontRegardless()
    }
}
