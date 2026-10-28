import AppKit

/// Wraps the delegate SwiftUI (or AppKit) already installed so `windowShouldClose` can
/// veto or defer a close without replacing the rest of scene teardown.
///
/// Hosted `NSHostingView` windows often have no SwiftUI delegate; WindowGroup does.
/// `install` keeps whichever delegate is current and forwards every other message to it.
@MainActor
final class WindowCloseInterceptor: NSObject, NSWindowDelegate {
    weak var forwarded: NSWindowDelegate?
    /// The next `windowShouldClose` returns false and stays closed until this is cleared.
    var vetoesClose = false
    /// The next `windowShouldClose` returns false once. The caller closes later.
    var defersClose = false

    static func install(on window: NSWindow) -> WindowCloseInterceptor {
        if let existing = window.delegate as? WindowCloseInterceptor {
            return existing
        }
        let interceptor = WindowCloseInterceptor()
        interceptor.forwarded = window.delegate
        window.delegate = interceptor
        objc_setAssociatedObject(window, &associationKey, interceptor, .OBJC_ASSOCIATION_RETAIN)
        return interceptor
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if vetoesClose { return false }
        if defersClose {
            defersClose = false
            return false
        }
        guard let forwarded, forwarded.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) else {
            return true
        }
        return forwarded.windowShouldClose?(sender) ?? true
    }

    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(NSWindowDelegate.windowShouldClose(_:)) { return true }
        if super.responds(to: selector) { return true }
        return forwarded?.responds(to: selector) ?? false
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if selector == #selector(NSWindowDelegate.windowShouldClose(_:)) { return nil }
        return forwarded
    }
}

private var associationKey: UInt8 = 0
