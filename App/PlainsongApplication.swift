import AppKit
import ObjectiveC

/// Installs a `sendEvent(_:)` hook so ⇧⌘F is handled before menu key-equivalent matching.
///
/// SwiftUI `@main` does not honor `NSPrincipalClass` here, and SwiftUI's delegate adaptor does
/// not always expose the concrete delegate type on `NSApp.delegate`. Swizzle `sendEvent` and
/// resolve `AppState` via `PlainsongAppServices`.
enum PlainsongApplicationSendEventHook {
    private static let lock = NSLock()
    private static var didInstall = false

    static func installIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !didInstall else { return }
        didInstall = true

        let originalSelector = #selector(NSApplication.sendEvent(_:))
        let swizzledSelector = #selector(NSApplication.plainsong_sendEvent(_:))
        guard let originalMethod = class_getInstanceMethod(NSApplication.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(NSApplication.self, swizzledSelector)
        else {
            assertionFailure("Failed to locate NSApplication.sendEvent for ⇧⌘F hook")
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }
}

extension NSApplication {
    /// Swizzled `sendEvent(_:)`. After exchange, calling this selector runs AppKit's original.
    @objc func plainsong_sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           PlainsongMenuKeyBinding.matchesFindInWorkspace(event)
        {
            let handled = MainActor.assumeIsolated {
                PlainsongFindInWorkspaceKeyAction.performIfAvailable()
            }
            if handled {
                return
            }
        }
        plainsong_sendEvent(event)
    }
}

/// Shared action used by the sendEvent hook (and tests).
enum PlainsongFindInWorkspaceKeyAction {
    /// - Returns: `true` when Search focus was requested and the key should be consumed.
    @MainActor
    @discardableResult
    static func performIfAvailable() -> Bool {
        guard let appState = PlainsongAppServices.appState,
              appState.canUseWorkspaceSearch
        else {
            return false
        }
        appState.focusWorkspaceSearch()
        return true
    }
}
