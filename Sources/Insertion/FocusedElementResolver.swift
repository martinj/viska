import ApplicationServices
import Foundation

@MainActor
protocol FocusedTextElement: AnyObject {
    var isWritable: Bool { get }
    var value: String? { get }
    var selectedRange: NSRange? { get }
    func setValue(_ newValue: String) -> Bool
    func setSelectedRange(_ newValue: NSRange) -> Bool
}

@MainActor
protocol FocusedElementResolving: AnyObject {
    func focusedElement() -> (any FocusedTextElement)?
}

@MainActor
final class FocusedElementResolver: FocusedElementResolving {
    func focusedElement() -> (any FocusedTextElement)? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementReference: CFTypeRef?

        let status = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementReference
        )

        guard status == .success,
              let focusedElementReference else {
            return nil
        }

        let axElement = focusedElementReference as! AXUIElement
        return AXFocusedTextElement(element: axElement)
    }
}

@MainActor
private final class AXFocusedTextElement: FocusedTextElement {
    private let element: AXUIElement

    init(element: AXUIElement) {
        self.element = element
    }

    var isWritable: Bool {
        var isSettable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &isSettable
        )

        return status == .success && isSettable.boolValue
    }

    var value: String? {
        var rawValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &rawValue
        )

        guard status == .success else { return nil }
        return rawValue as? String
    }

    func setValue(_ newValue: String) -> Bool {
        AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            newValue as CFTypeRef
        ) == .success
    }

    var selectedRange: NSRange? {
        var rawValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rawValue
        )

        guard status == .success,
              let rawValue else {
            return nil
        }

        let rangeValue = rawValue as! AXValue
        guard AXValueGetType(rangeValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        AXValueGetValue(rangeValue, .cfRange, &range)
        return NSRange(location: range.location, length: range.length)
    }

    func setSelectedRange(_ newValue: NSRange) -> Bool {
        var range = CFRange(location: newValue.location, length: newValue.length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return false }

        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        ) == .success
    }
}
