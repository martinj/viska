import ApplicationServices
import Carbon.HIToolbox
import Foundation

@MainActor
protocol SyntheticPasting: AnyObject {
    func pasteClipboardContents() -> Bool
}

@MainActor
final class SyntheticPasteService: SyntheticPasting {
    func pasteClipboardContents() -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
        return true
    }
}
