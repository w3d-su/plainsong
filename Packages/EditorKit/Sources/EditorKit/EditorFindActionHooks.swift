import Foundation

/// Production App installs these so `STTextView` responder-chain selectors open the
/// find bar without EditorKit importing App. F0 spike still records fires locally.
@MainActor
public enum EditorFindActionHooks {
    public static var showFind: (() -> Void)?
    public static var findNext: (() -> Void)?
    public static var findPrevious: (() -> Void)?
    public static var useSelectionForFind: (() -> Void)?
    /// Escape delivered to the editor. Returns `true` when the find bar consumed it, so the
    /// editor can fall through to its own `cancelOperation:` behaviour when it did not.
    public static var cancelFind: (() -> Bool)?
}
