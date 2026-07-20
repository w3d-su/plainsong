import AppKit

/// AppKit-side menu key-equivalent matching for shortcuts that SwiftUI may display
/// but fail to dispatch (notably ⇧⌘F while the system View menu also binds letter F).
enum PlainsongMenuKeyBinding {
    /// ANSI `F` key code (`kVK_ANSI_F`). Used so command-key matching stays stable under
    /// IME layouts (Zhuyin/Pinyin) that change character generation but not key codes.
    static let ansiFKeyCode: UInt16 = 3

    /// Exactly ⇧⌘F — no Option/Control. Caps Lock / Fn / numeric-pad bits are ignored.
    static func matchesFindInWorkspace(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let relevant = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard relevant == [.command, .shift] else { return false }
        if event.keyCode == ansiFKeyCode { return true }
        return event.charactersIgnoringModifiers?.lowercased() == "f"
    }
}
