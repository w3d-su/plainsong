import Foundation
import WorkspaceCore

/// Directories the workspace scan does not descend into.
enum IOSWorkspaceScanPruning {
    /// A hidden directory is never shown unless hidden entries are on, so listing it is wasted
    /// work. That covers `.git`, `.build`, `.next` and `.astro`. Visible generated folders
    /// (`node_modules`, `build`, `dist`) are still listed: iOS has no "Show all files" toggle
    /// and no retained chain to an open document, so pruning them would hide files for good.
    static func skipsDirectory(_ relativePath: String, includesHiddenEntries: Bool) -> Bool {
        guard let name = relativePath.splitOnPathSeparator().last else { return false }
        return !includesHiddenEntries && name.hasPrefix(".")
    }
}
