import AppKit
import Carbon.HIToolbox
import Foundation

struct HotkeyDescriptor: Codable, Equatable {
    enum ValidationError: Error, Equatable {
        case missingModifier
        case unsupportedKey
    }

    static let validModifierMask = UInt32(cmdKey | controlKey | optionKey | shiftKey)
    static let requiredModifierFlags = UInt32(controlKey | optionKey)

    var keyCode: UInt32
    var modifiers: UInt32

    func validate() throws {
        if modifiers & Self.validModifierMask == 0 {
            throw ValidationError.missingModifier
        }

        if keyCode == UInt32(kVK_Escape) {
            throw ValidationError.unsupportedKey
        }
    }

    var displayString: String {
        "\(modifierSymbols)\(keyLabel)"
    }

    var modifierSymbols: String {
        var output = ""

        if modifiers & UInt32(controlKey) != 0 {
            output += "⌃"
        }
        if modifiers & UInt32(optionKey) != 0 {
            output += "⌥"
        }
        if modifiers & UInt32(shiftKey) != 0 {
            output += "⇧"
        }
        if modifiers & UInt32(cmdKey) != 0 {
            output += "⌘"
        }

        return output
    }

    var keyLabel: String {
        switch keyCode {
        case UInt32(kVK_Space):
            "Space"
        case UInt32(kVK_Return):
            "Return"
        case UInt32(kVK_Tab):
            "Tab"
        default:
            Self.keyCodeLabels[keyCode] ?? "Key \(keyCode)"
        }
    }

    static func from(event: NSEvent) -> HotkeyDescriptor? {
        guard !modifierOnlyKeyCodes.contains(UInt32(event.keyCode)) else {
            return nil
        }

        let modifiers = carbonModifierFlags(from: event.modifierFlags)
        return HotkeyDescriptor(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    static func carbonModifierFlags(from modifierFlags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0

        if modifierFlags.contains(.command) {
            result |= UInt32(cmdKey)
        }
        if modifierFlags.contains(.option) {
            result |= UInt32(optionKey)
        }
        if modifierFlags.contains(.control) {
            result |= UInt32(controlKey)
        }
        if modifierFlags.contains(.shift) {
            result |= UInt32(shiftKey)
        }

        return result
    }

    static func errorMessage(for error: ValidationError) -> String {
        switch error {
        case .missingModifier:
            "Choose a shortcut with at least one modifier key."
        case .unsupportedKey:
            "That key is reserved. Choose a different shortcut."
        }
    }

    private static let modifierOnlyKeyCodes: Set<UInt32> = [
        UInt32(kVK_Command),
        UInt32(kVK_RightCommand),
        UInt32(kVK_Shift),
        UInt32(kVK_RightShift),
        UInt32(kVK_Option),
        UInt32(kVK_RightOption),
        UInt32(kVK_Control),
        UInt32(kVK_RightControl),
        UInt32(kVK_Function),
        UInt32(kVK_CapsLock),
    ]

    private static let keyCodeLabels: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 50: "`",
    ]
}
