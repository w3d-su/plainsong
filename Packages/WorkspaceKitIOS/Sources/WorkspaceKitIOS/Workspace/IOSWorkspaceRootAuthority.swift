import Darwin
import Foundation
import WorkspaceCore

/// Proves a coordinated URL still belongs to the grant root. Literal prefix checks are not authority.
enum IOSWorkspaceRootAuthority {
    static func proveExisting(_ url: URL, root: URL) throws -> URL {
        let rootReal = try realPath(root)
        let fileReal = try realPath(url)
        guard isInside(root: rootReal, path: fileReal) else {
            throw IOSWorkspaceFailure.outsideGrant
        }
        return IOSWorkspacePathAuthority.fileURL(path: fileReal)
    }

    /// The leaf does not exist yet. Prove its parent, then the leaf name joined to that real parent.
    static func proveNewLeaf(_ url: URL, root: URL) throws -> URL {
        let name = url.lastPathComponent
        if name.isEmpty || name == "." || name == ".." || name.containsPathSeparator || name.utf8.contains(0) {
            throw IOSWorkspaceFailure.invalidPath
        }
        let parent = url.deletingLastPathComponent()
        let rootReal = try realPath(root)
        let parentReal = try realPath(parent)
        guard isInside(root: rootReal, path: parentReal) else {
            throw IOSWorkspaceFailure.outsideGrant
        }
        let leafReal = parentReal.hasTrailingPathSeparator ? parentReal + name : parentReal + "/" + name
        guard isInside(root: rootReal, path: leafReal) else {
            throw IOSWorkspaceFailure.outsideGrant
        }
        return IOSWorkspacePathAuthority.fileURL(path: leafReal)
    }

    private static func isInside(root: String, path: String) -> Bool {
        let rootBytes = Array(root.utf8)
        let pathBytes = Array(path.utf8)
        if pathBytes == rootBytes {
            return true
        }
        guard pathBytes.count > rootBytes.count else { return false }
        guard Array(pathBytes.prefix(rootBytes.count)) == rootBytes else { return false }
        return pathBytes[rootBytes.count] == UInt8(ascii: "/")
    }

    private static func realPath(_ url: URL) throws -> String {
        let path = url.path(percentEncoded: false)
        guard let cPath = path.cString(using: .utf8) else {
            throw IOSWorkspaceFailure.invalidPath
        }
        guard let resolved = realpath(cPath, nil) else {
            // Only an unresolvable path is a containment failure. A missing or unreadable
            // item is reported as such, so the caller does not ask for a new grant.
            switch errno {
            case ENOENT, ENOTDIR: throw IOSWorkspaceFailure.notFound
            case EACCES, EPERM: throw IOSWorkspaceFailure.permissionDenied
            default: throw IOSWorkspaceFailure.outsideGrant
            }
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
