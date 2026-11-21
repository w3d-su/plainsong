import Foundation
import WorkspaceCore

/// Directories the workspace scan does not descend into.
enum IOSWorkspaceScanPruning {
    /// Generated, vendored and tool directories, lowercased. Mirrors
    /// `WorkspaceIgnoredDirectories.names` in WorkspaceKit, which this package cannot import.
    static let ignoredNames: Set<String> = [
        ".git",
        "node_modules",
        ".build",
        ".next",
        ".astro",
        "deriveddata",
        "dist",
        "build",
    ]

    /// A hidden directory is never shown unless hidden entries are on, so listing it is wasted
    /// work. An ignored directory is skipped unless "Show all files" is on, as on macOS.
    static func skipsDirectory(
        _ relativePath: String,
        includesHiddenEntries: Bool,
        includesAllFiles: Bool
    ) -> Bool {
        guard let name = relativePath.splitOnPathSeparator().last.map(String.init) else { return false }
        if !includesAllFiles, ignoredNames.contains(name.lowercased()) {
            return true
        }
        return !includesHiddenEntries && name.hasPrefix(".")
    }
}
