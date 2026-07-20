import AppKit

/// AppKit-side matching for ⇧⌘F (Find in Workspace).
///
/// SwiftUI may display the shortcut on the menu while still failing to fire the action
/// when the system View menu also binds letter F (Enter Full Screen). Matching is shared
/// by the `NSApplication.sendEvent` hook and unit tests.
enum PlainsongMenuKeyBinding {
    /// ANSI `F` key code (`kVK_ANSI_F`). Stable under IME layouts that change characters
    /// but not physical key codes (Zhuyin/Pinyin).
    static let ansiFKeyCode: UInt16 = 3

    /// ⇧⌘F for Find in Workspace.
    ///
    /// Requires Command+Shift and F. **Does not reject Option** — live key logging under
    /// Zhuyin / System Events showed `option=true` on both plain IME keyDowns and ⇧⌘F
    /// (rawFlags included `NSEvent.ModifierFlags.option`), which previously made a strict
    /// `== [.command, .shift]` check always fail. Control is still rejected so ⌃⌘F
    /// (Full Screen shape) is not claimed. Format Table is ⌥⌘F without Shift, so it stays
    /// distinct.
    static func matchesFindInWorkspace(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command), flags.contains(.shift) else { return false }
        guard !flags.contains(.control) else { return false }
        if event.keyCode == ansiFKeyCode {
            return true
        }
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        return chars == "f"
    }
}
