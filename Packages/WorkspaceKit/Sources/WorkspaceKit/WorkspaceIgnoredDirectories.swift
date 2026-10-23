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
    /// Skip ignored directories and everything under them, except the chain of directories
    /// down to a retained root-relative path and that path itself (an open document must
    /// never vanish from the snapshot). Nothing else inside an ignored directory is scanned.
    case ignoredDirectories(retaining: Set<String>)

    /// Whether the scan skips the entry at root-relative `relativePath` and, for a
    /// directory, everything under it.
    func skipsEntry(named name: String, relativePath: String, isDirectory: Bool) -> Bool {
        guard case let .ignoredDirectories(retained) = self else { return false }
        let isIgnoredDirectory = isDirectory && WorkspaceIgnoredDirectories.contains(name)
        // An entry can sit under an ignored directory only when a retained path kept that
        // directory, so without retained paths the entry's own name decides.
        guard isIgnoredDirectory || (!retained.isEmpty && Self.hasIgnoredAncestor(relativePath)) else {
            return false
        }
        let descendantPrefix = relativePath + "/"
        return !retained.contains { $0 == relativePath || $0.hasPrefix(descendantPrefix) }
    }

    private static func hasIgnoredAncestor(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").dropLast().contains {
            WorkspaceIgnoredDirectories.contains(String($0))
        }
    }
}
