import Foundation
import MarkdownCore

/// WorkspaceKit owns folder workspaces (agent.md §5): file tree model, FSEvents
/// watching, security-scoped bookmarks, and atomic saves. All file access must go
/// through the security-scope helpers added in M3.
public enum WorkspaceKitInfo {
    public static let version = "0.1.0"
}
