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
/// `F0 spike`. A successful physical `⌘F` (with a document open and the editor
/// focused) logs one notice line per fire. A disabled menu item still beeps and
/// produces **no** log line — that is how fire is distinguished from the beep.
@MainActor
public enum EditorFindSpike {
    private static let log = Logger(
        subsystem: "app.plainsong.editor",
        category: "EditorFindSpike"
    )

    /// Monotonic count of successful `plainsongShowFind:` deliveries (tests / diagnostics).
    public private(set) static var fireCount: UInt64 = 0

    /// Last time a find spike action was delivered.
    public private(set) static var lastFireDate: Date?

    public static func reset() {
        fireCount = 0
        lastFireDate = nil
    }

    /// Records a fire. Called only from the focused editor's responder-chain selector.
    public static func recordFire() {
        fireCount &+= 1
        lastFireDate = Date()
        // public so Console.app shows it without private-data redaction of the count.
        log.notice("F0 spike: plainsongShowFind fired (count=\(fireCount, privacy: .public))")
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
