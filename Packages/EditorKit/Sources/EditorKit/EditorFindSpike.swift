import AppKit
import STTextView

/// Minimal F0 spike: proves a SwiftUI `⌘F` menu item can reach the focused editor
/// through the same responder-chain shape as Format commands.
///
/// Production find-bar UI is PR C. This type only records that the action fired so an
/// owner physical-keyboard run can close F0 without building the bar.
@MainActor
public enum EditorFindSpike {
    /// Monotonic count of successful `plainsongShowFind:` deliveries.
    public private(set) static var fireCount: UInt64 = 0

    /// Last time a find spike action was delivered (for owner smoke diagnostics).
    public private(set) static var lastFireDate: Date?

    public static func reset() {
        fireCount = 0
        lastFireDate = nil
    }

    /// Records a fire. Called only from the focused editor's responder-chain selector.
    public static func recordFire() {
        fireCount &+= 1
        lastFireDate = Date()
    }

    /// Dispatches show-find like Format: `NSApp.sendAction` → first responder editor.
    public static func performShowFind() {
        NSApp.sendAction(#selector(STTextView.plainsongShowFind(_:)), to: nil, from: nil)
    }
}

@MainActor
extension STTextView {
    /// F0 spike selector. Production PR C will open / re-focus the find bar here.
    @objc func plainsongShowFind(_: Any?) {
        EditorFindSpike.recordFire()
    }
}
