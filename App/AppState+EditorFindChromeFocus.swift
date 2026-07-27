import AppKit
import EditorKit
import Foundation

/// Which find-bar control SwiftUI reports as focused, and in which window.
///
/// `AppState` is shared across the `WindowGroup` while every window's `EditorFindBar`
/// reports its own `FocusState`, so both directions need window scoping: a background
/// window may neither grant ⌘G / ⌘E eligibility in the key window nor clear the key
/// window's live report.
@MainActor
extension AppState {
    /// Whether the **key** window is the one reporting find-bar chrome focus.
    ///
    /// Every window's bar reports its own SwiftUI focus into shared `AppState`, so the report
    /// is only meaningful next to the window it came from: focus stranded in a background
    /// window must not make ⌘G / ⌘E eligible in the window the user is actually typing in.
    func hasKeyWindowFindChromeFocus() -> Bool {
        guard let report = editorFindHost.chromeFocus,
              let keyWindowNumber = editorFindHost.keyWindowNumberOverride
              ?? NSApp.keyWindow?.windowNumber
        else {
            return false
        }
        return report.windowNumber == keyWindowNumber
    }

    /// Records what one window's find bar reports about its own SwiftUI focus.
    ///
    /// **Every mutation is scoped to the reporting window.** A window may only overwrite or
    /// clear a report it owns: the report store is App-global, so an unconditional clear lets
    /// a background window closing or losing focus wipe the key window's live report and take
    /// ⌘G / ⌘E down with it. `nil` from a window that owns no report is a no-op.
    ///
    /// Setting requires a window number, because an untagged report cannot be compared
    /// against the key window and so could never be trusted anyway.
    func setEditorFindChromeFocus(_ focus: EditorFindChromeFocus?, inWindowNumber windowNumber: Int?) {
        guard let windowNumber else { return }
        let report: EditorFindChromeFocusReport? = focus.map {
            EditorFindChromeFocusReport(windowNumber: windowNumber, focus: $0)
        }
        if report == nil, editorFindHost.chromeFocus?.windowNumber != windowNumber {
            // Another window owns the current report; this window has nothing to clear.
            return
        }
        guard editorFindHost.chromeFocus != report else { return }
        editorFindHost.chromeFocus = report
        objectWillChange.send()
    }

    /// Drops the reported chrome focus regardless of which window reported it.
    ///
    /// Unlike a per-window report, this is an **App-scoped** intent: the bar itself is gone
    /// (closed, document switched, workspace closed), so no window's report can still be
    /// describing focus inside it.
    func clearEditorFindChromeFocus() {
        guard editorFindHost.chromeFocus != nil else { return }
        editorFindHost.chromeFocus = nil
        objectWillChange.send()
    }
}
