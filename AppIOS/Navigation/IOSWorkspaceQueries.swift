import Foundation
import WorkspaceCore

extension [IOSWorkspaceEntry] {
    func depthFirstFirst(_ predicate: (IOSWorkspaceEntry) -> Bool) -> IOSWorkspaceEntry? {
        for entry in self {
            if predicate(entry) {
                return entry
            }
            if let match = entry.children.depthFirstFirst(predicate) {
                return match
            }
        }
        return nil
    }
}

/// Parent-directory location for a workspace-relative file location. The root
/// directory is reached as `relativePath == ""` — the parent of any top-level
/// entry. Preserves the location's byte spelling (contracts.md §4).
extension IOSFileLocation {
    var parentDirectoryLocation: IOSFileLocation? {
        guard !relativePath.isEmpty else { return nil }
        var trimmed = relativePath
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty else { return nil }
        let parentPath = (trimmed as NSString).deletingLastPathComponent
        return IOSFileLocation(
            workspaceID: workspaceID,
            accessGeneration: accessGeneration,
            relativePath: parentPath,
            fileURL: fileURL.deletingLastPathComponent(),
            resourceID: nil
        )
    }
}
