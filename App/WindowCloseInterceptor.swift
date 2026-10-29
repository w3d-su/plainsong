import AppKit

/// Wraps the delegate SwiftUI (or AppKit) already installed so `windowShouldClose` can
/// veto or defer a close without replacing the rest of scene teardown.
///
/// Hosted `NSHostingView` windows often have no SwiftUI delegate; WindowGroup does.
/// `install` keeps whichever delegate is current and forwards every other message to it.
///
/// `NSWindow` caches which delegate methods exist when the delegate is set, so the wrapped
/// delegate is held strongly while the window is open: a released one would turn a cached
/// selector into an unrecognized-selector crash. After `windowWillClose` is forwarded, the
/// window gets the wrapped delegate back and the interceptor lets it go, which breaks the
/// window → interceptor → delegate chain.
@MainActor
final class WindowCloseInterceptor: NSObject, NSWindowDelegate {
    private(set) var forwarded: NSWindowDelegate?
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

    func windowWillClose(_ notification: Notification) {
        if forwarded?.responds(to: #selector(NSWindowDelegate.windowWillClose(_:))) == true {
            forwarded?.windowWillClose?(notification)
        }
        guard let window = notification.object as? NSWindow else { return }
        // Not during this notification: swapping the delegate re-registers its notification
        // observers, and the wrapped delegate must not see this close twice.
        Task { @MainActor [weak window] in
            if let window, window.delegate === self {
                window.delegate = self.forwarded
                objc_setAssociatedObject(window, &associationKey, nil, .OBJC_ASSOCIATION_RETAIN)
            }
            self.forwarded = nil
        }
    }

    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(NSWindowDelegate.windowShouldClose(_:)) { return true }
        if super.responds(to: selector) { return true }
        return forwarded?.responds(to: selector) ?? false
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if selector == #selector(NSWindowDelegate.windowShouldClose(_:)) { return nil }
        // `forwarded` stays alive until the window has its own delegate back, so a selector
        // `responds(to:)` vouched for always has a receiver.
        return forwarded
    }
}

/// Only its address is used.
private nonisolated(unsafe) var associationKey: UInt8 = 0
