import Foundation
import WorkspaceCore

/// Display comparison only; grants and provider access still authorize I/O.
/// A refresh request ID alone does not redraw the tree, and editor keystrokes
/// keep the same projection. Byte spellings remain distinct in the browser.
enum IOSShellWorkspaceProjection {
    static func matches(_ lhs: IOSWorkspaceSnapshot?, _ rhs: IOSWorkspaceSnapshot?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?):
            lhs.workspaceID == rhs.workspaceID && lhs.accessGeneration == rhs.accessGeneration &&
                matches(lhs.entries, rhs.entries)
        default: false
        }
    }

    private static func matches(_ lhs: [IOSWorkspaceEntry], _ rhs: [IOSWorkspaceEntry]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { lhs, rhs in
            lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.availability == rhs.availability &&
                lhs.location.workspaceID == rhs.location.workspaceID &&
                lhs.location.accessGeneration == rhs.location.accessGeneration &&
                lhs.location.relativePath.utf8.elementsEqual(rhs.location.relativePath.utf8) &&
                lhs.location.fileURL.absoluteString.utf8.elementsEqual(rhs.location.fileURL.absoluteString.utf8) &&
                lhs.location.resourceID == rhs.location.resourceID && matches(lhs.children, rhs.children)
        }
    }
}
