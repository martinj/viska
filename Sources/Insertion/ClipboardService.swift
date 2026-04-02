import AppKit
import Foundation

@MainActor
protocol ClipboardControlling: AnyObject {
    func stringContents() -> String?
    func setString(_ string: String)
}

@MainActor
final class ClipboardService: ClipboardControlling {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func stringContents() -> String? {
        pasteboard.string(forType: .string)
    }

    func setString(_ string: String) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
