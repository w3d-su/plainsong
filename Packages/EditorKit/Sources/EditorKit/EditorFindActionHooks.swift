import AppKit
import Foundation

/// Production App installs these so `STTextView` responder-chain selectors open the
/// find bar without EditorKit importing App. F0 spike still records fires locally.
@MainActor
public enum EditorFindActionHooks {
    /// The argument is the text view's window, so the command reaches that window's façade
    /// instead of whichever window last wrote a process-wide `AppState`.
    public static var showFind: ((NSWindow?) -> Void)?
    public static var findNext: ((NSWindow?) -> Void)?
    public static var findPrevious: ((NSWindow?) -> Void)?
    public static var useSelectionForFind: ((NSWindow?) -> Void)?
    /// Escape delivered to the editor. Returns `true` when the find bar consumed it, so the
    /// editor can fall through to its own `cancelOperation:` behaviour when it did not.
    public static var cancelFind: ((NSWindow?) -> Bool)?
}
