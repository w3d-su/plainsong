import AppKit
import os
import STTextView

/// Minimal F0 spike: proves a SwiftUI `⌘F` menu item can reach the focused editor
/// through the same responder-chain shape as Format commands.
///
/// Production find-bar UI is PR C. This type records that the action fired so an
/// owner physical-keyboard run can close F0 without building the bar.
///
/// **Owner observation (no debugger):** open Console.app → start streaming for the
/// Plainsong process → filter subsystem `app.plainsong.editor` or message text
/// `F0 spike`. Expected sequence for a successful delivery:
/// 1. `F0 spike: menu/key equivalent invoked performShowFind`
/// 2. `F0 spike: sendAction(plainsongShowFind:) delivered=true`
/// 3. `F0 spike: plainsongShowFind fired (count=N)`
///
/// If (1) appears but `delivered=false` and no (3), the menu route works but no
/// editor was first responder. If nothing appears, the key equivalent never fired
/// (often: no open document → Find… disabled → system beep only).
@MainActor
public enum EditorFindSpike {
    private static let log = Logger(
        subsystem: "app.plainsong.editor",
        category: "EditorFindSpike"
    )

    /// Monotonic count of successful `plainsongShowFind:` deliveries (tests / diagnostics).
    public private(set) static var fireCount: UInt64 = 0

    /// Last time a find spike action was delivered to an editor.
    public private(set) static var lastFireDate: Date?

    public static func reset() {
        fireCount = 0
        lastFireDate = nil
    }

    /// Records a fire. Called only from the focused editor's responder-chain selector.
    public static func recordFire() {
        fireCount &+= 1
        lastFireDate = Date()
        log.notice("F0 spike: plainsongShowFind fired (count=\(fireCount, privacy: .public))")
        // Also print so Xcode debug console shows it without Console.app filtering.
        print("F0 spike: plainsongShowFind fired (count=\(fireCount))")
    }

    /// Dispatches show-find like Format: `NSApp.sendAction` → first responder editor.
    public static func performShowFind() {
        log.notice("F0 spike: menu/key equivalent invoked performShowFind")
        print("F0 spike: menu/key equivalent invoked performShowFind")
        let delivered = NSApp.sendAction(
            #selector(STTextView.plainsongShowFind(_:)),
            to: nil,
            from: nil
        )
        log.notice(
            "F0 spike: sendAction(plainsongShowFind:) delivered=\(delivered, privacy: .public)"
        )
        print("F0 spike: sendAction(plainsongShowFind:) delivered=\(delivered)")
    }
}

@MainActor
extension STTextView {
    /// F0 spike selector. Production PR C will open / re-focus the find bar here.
    @objc func plainsongShowFind(_: Any?) {
        EditorFindSpike.recordFire()
    }
}
