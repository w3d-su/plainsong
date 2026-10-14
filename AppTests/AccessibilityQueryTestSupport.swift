import AppKit
import ApplicationServices

/// Walks the hosted window's accessibility tree so layout tests can find and drive
/// SwiftUI controls the way VoiceOver does.
@MainActor
enum AccessibilityQuery {
    static func find(identifier: String?, label: String?, in window: NSWindow) -> AXUIElement? {
        var seen = Set<CFHashCode>()
        for root in roots(for: window) {
            if let found = search(root, identifier: identifier, label: label, seen: &seen, depth: 0) {
                return found
            }
        }
        return nil
    }

    static func summary(in window: NSWindow) -> String {
        var seen = Set<CFHashCode>()
        var lines: [String] = []
        for root in roots(for: window) {
            collect(root, seen: &seen, lines: &lines, depth: 0)
        }
        return "AX elements (\(lines.count)):\n" + lines.joined(separator: "\n")
    }

    static func value(of element: AXUIElement) -> String? {
        attribute(element, kAXValueAttribute) as? String
    }

    static func role(of element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute) as? String
    }

    static func numericValue(of element: AXUIElement) -> Double? {
        (attribute(element, kAXValueAttribute) as? NSNumber)?.doubleValue
    }

    static func valueDescription(of element: AXUIElement) -> String? {
        attribute(element, kAXValueDescriptionAttribute) as? String
    }

    static func minValue(of element: AXUIElement) -> Double? {
        (attribute(element, kAXMinValueAttribute) as? NSNumber)?.doubleValue
    }

    static func maxValue(of element: AXUIElement) -> Double? {
        (attribute(element, kAXMaxValueAttribute) as? NSNumber)?.doubleValue
    }

    static func performIncrement(on element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXIncrementAction as CFString) == .success
    }

    private static func roots(for window: NSWindow) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let windows = children(of: app, attribute: kAXWindowsAttribute)
        let title = window.title
        let titled = windows.filter { attribute($0, kAXTitleAttribute) as? String == title }
        var ordered = titled.isEmpty ? windows : titled
        if let focused = element(attribute(app, kAXFocusedWindowAttribute)) {
            ordered.insert(focused, at: 0)
        }
        return ordered
    }

    private static func search(
        _ element: AXUIElement, identifier: String?, label: String?, seen: inout Set<CFHashCode>, depth: Int
    ) -> AXUIElement? {
        guard depth < 30, seen.insert(CFHash(element)).inserted else { return nil }
        let identifierMatches = identifier == nil || attribute(element, kAXIdentifierAttribute) as? String == identifier
        let labelMatches = label == nil || attribute(element, kAXDescriptionAttribute) as? String == label
        if identifierMatches, labelMatches, identifier != nil || label != nil { return element }
        for child in children(of: element, attribute: kAXChildrenAttribute) {
            if let found = search(child, identifier: identifier, label: label, seen: &seen, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private static func collect(_ element: AXUIElement, seen: inout Set<CFHashCode>, lines: inout [String],
                                depth: Int)
    {
        guard depth < 30, lines.count < 40, seen.insert(CFHash(element)).inserted else { return }
        let role = attribute(element, kAXRoleAttribute) as? String
        let identifier = attribute(element, kAXIdentifierAttribute) as? String
        let label = attribute(element, kAXDescriptionAttribute) as? String
        if role != nil || identifier != nil || label != nil {
            lines.append("role=\(role ?? "-") id=\(identifier ?? "-") label=\(label ?? "-")")
        }
        for child in children(of: element, attribute: kAXChildrenAttribute) {
            collect(child, seen: &seen, lines: &lines, depth: depth + 1)
        }
    }

    private static func children(of element: AXUIElement, attribute name: String) -> [AXUIElement] {
        guard let raw = attribute(element, name) else { return [] }
        guard CFGetTypeID(raw) == CFArrayGetTypeID() else { return self.element(raw).map { [$0] } ?? [] }
        let array = unsafeBitCast(raw, to: CFArray.self)
        return (0 ..< CFArrayGetCount(array)).compactMap { index in
            let pointer = CFArrayGetValueAtIndex(array, index)
            guard let pointer else { return nil }
            let value = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
            return self.element(value)
        }
    }

    /// `as? AXUIElement` always succeeds for any CF value, so the type id selects real elements.
    private static func element(_ raw: CFTypeRef?) -> AXUIElement? {
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else { return nil }
        return raw
    }
}
