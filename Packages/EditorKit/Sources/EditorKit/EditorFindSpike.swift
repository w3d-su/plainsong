import AppKit
import STTextView

/// Counts `plainsongShowFind:` deliveries to the focused editor, so tests can prove a
/// SwiftUI `⌘F` menu item reaches the editor through the responder chain (the F0 spike;
/// the production find bar is `EditorFindActionHooks` + App's `EditorFindCommandDelivery`).
@MainActor
public enum EditorFindSpike {
    /// Monotonic count of successful `plainsongShowFind:` deliveries (tests / diagnostics).
    public private(set) static var fireCount: UInt64 = 0

    /// Last time a find spike action was delivered to an editor.
    public private(set) static var lastFireDate: Date?

    /// Window number of the text view that last received `plainsongShowFind:`.
    public private(set) static var lastOriginatingWindowNumber: Int?

    public static func reset() {
        fireCount = 0
        lastFireDate = nil
        lastOriginatingWindowNumber = nil
    }

    /// Records a fire. Called only from the focused editor's responder-chain selector.
    public static func recordFire(window: NSWindow? = nil) {
        fireCount &+= 1
        lastFireDate = Date()
        lastOriginatingWindowNumber = window?.windowNumber
    }
}

@MainActor
public extension STTextView {
    /// Find commands delivered through the AppKit responder chain (same shape as Format).
    /// Production App installs `EditorFindActionHooks` from `PlainsongApp` init.
    @objc func plainsongShowFind(_: Any?) {
        EditorFindSpike.recordFire(window: window)
        EditorFindActionHooks.showFind?(window)
    }

    @objc func plainsongFindNext(_: Any?) {
        EditorFindActionHooks.findNext?(window)
    }

    @objc func plainsongFindPrevious(_: Any?) {
        EditorFindActionHooks.findPrevious?(window)
    }

    @objc func plainsongUseSelectionForFind(_: Any?) {
        EditorFindActionHooks.useSelectionForFind?(window)
    }
}
