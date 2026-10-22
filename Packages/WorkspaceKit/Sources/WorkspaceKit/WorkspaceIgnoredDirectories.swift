import Foundation

/// Generated, vendored and tool directories (`node_modules`, `dist`, `.next`, …) that a blog
/// workspace never edits. Search always skips paths through them; the Files scan skips them in
/// the default Markdown-only mode and enumerates them only when "Show all files" is on.
public enum WorkspaceIgnoredDirectories {
    /// Lowercased directory names, compared case-insensitively.
    public static let names: Set<String> = [
        ".git",
        "node_modules",
        ".build",
        ".next",
        ".astro",
        "deriveddata",
        "dist",
        "build",
    ]

    public static func contains(_ name: String) -> Bool {
        names.contains(name.lowercased())
    }
}

/// How a workspace scan treats `WorkspaceIgnoredDirectories`.
public enum WorkspaceScanPruning: Sendable, Equatable {
    /// Enumerate everything ("Show all files").
    case none
    /// Skip ignored directories and everything under them, except a directory on the way to a
    /// retained root-relative path (an open document must never vanish from the snapshot).
    case ignoredDirectories(retaining: Set<String>)

    /// Whether the scan skips the directory at root-relative `relativePath`.
    func skipsDirectory(named name: String, relativePath: String) -> Bool {
        guard case let .ignoredDirectories(retained) = self,
              WorkspaceIgnoredDirectories.contains(name)
        else {
            return false
        }
        let prefix = relativePath + "/"
        return !retained.contains { $0 == relativePath || $0.hasPrefix(prefix) }
    }
}
