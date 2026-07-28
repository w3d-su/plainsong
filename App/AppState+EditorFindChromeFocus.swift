import AppKit
import EditorKit
import Foundation

/// Which find-bar control SwiftUI reports as focused, per window.
///
/// `AppState` is shared across the `WindowGroup` while every window's `EditorFindBar` keeps
/// and reports its **own** `FocusState`. A single shared slot cannot represent that: whichever
/// window wrote last owns it, and switching back to another window republishes nothing —
/// neither its focus nor its window number changed, so no `onChange` fires and the key
/// window's ⌘G / ⌘E stay dead. Each window therefore gets its own entry.
@MainActor
extension AppState {
    /// Whether the **key** window reports find-bar chrome focus of its own.
    ///
    /// Reads only the key window's entry: another window's focus is real, but it is not focus
    /// in the window the user is typing in, so it grants nothing here.
    func hasKeyWindowFindChromeFocus() -> Bool {
        guard let keyWindowNumber = editorFindHost.keyWindowNumberOverride
            ?? NSApp.keyWindow?.windowNumber
        else {
            return false
        }
        return editorFindHost.chromeFocusByWindow[keyWindowNumber] != nil
    }

    /// Records what one window's find bar reports about its own SwiftUI focus.
    ///
    /// Writes only that window's entry, in both directions: a background window can neither
    /// clear nor overwrite another window's live report. `nil` removes the entry.
    ///
    /// A report without a window number is dropped — it could never be matched against the
    /// key window, and it has no owner to scope a later clear to.
    func setEditorFindChromeFocus(_ focus: EditorFindChromeFocus?, inWindowNumber windowNumber: Int?) {
        guard let windowNumber else { return }
        guard editorFindHost.chromeFocusByWindow[windowNumber] != focus else { return }
        editorFindHost.chromeFocusByWindow[windowNumber] = focus
        objectWillChange.send()
    }

    /// Drops every window's reported chrome focus.
    ///
    /// Unlike a per-window report this is an **App-scoped** intent, used only where the bar
    /// is actually gone in every window — Escape / Done, the last document closing, and
    /// workspace close — because `isBarVisible` is shared. Switching between documents is
    /// deliberately **not** one of them: F4b keeps the bar open across a file switch, so the
    /// focus reports still describe live chrome.
    func clearEditorFindChromeFocus() {
        guard !editorFindHost.chromeFocusByWindow.isEmpty else { return }
        editorFindHost.chromeFocusByWindow.removeAll()
        objectWillChange.send()
    }
}
