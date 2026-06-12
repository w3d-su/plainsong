import AppKit
import MarkdownCore

/// EditorKit owns the AppKit text editor (STTextView / TextKit 2, from M1) and all
/// editing behaviors (agent.md §6). Concrete editor types must not leak out of this
/// package — App and MarkdownCore never see them.
public enum EditorKitInfo {
    public static let version = "0.1.0"
}
