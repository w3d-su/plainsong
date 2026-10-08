import Foundation

enum AssetAuthority {
    static func matches(_ lhs: PreviewAssetAccessContext?, _ rhs: PreviewAssetAccessContext?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            matches(lhs, rhs)
        default:
            false
        }
    }

    static func matches(_ lhs: PreviewAssetAccessContext, _ rhs: PreviewAssetAccessContext) -> Bool {
        lhs.rootToken == rhs.rootToken
            && lhs.grantIdentity == rhs.grantIdentity
            && lhs.accessGeneration == rhs.accessGeneration
            && directoryPath(lhs.allowedRoot) == directoryPath(rhs.allowedRoot)
    }

    static func directoryPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        guard path != "/" else { return path }
        while path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

struct AssetReadCapture: Sendable {
    let plainsongRootToken: String
    let access: PreviewAssetAccessContext
    let allowedRoot: URL
    let requestID: UUID
}

struct AssetReadCompletionPermission: Equatable {
    let acceptsDelivery: Bool
    let allowedRoot: URL?
}

enum AssetReadCompletionFence {
    /// LANE07_COMPLETION_FENCE: a finished read is delivered only when this
    /// capture is still the current root token, grant, and generation.
    static func permission(
        stopped: Bool,
        invalidated: Bool,
        captured: AssetReadCapture,
        currentToken: String,
        currentAccess: PreviewAssetAccessContext?,
        currentRoot: URL?
    ) -> AssetReadCompletionPermission {
        let current = !stopped
            && !invalidated
            && captured.plainsongRootToken == currentToken
            && AssetAuthority.matches(captured.access, currentAccess)
        return AssetReadCompletionPermission(
            acceptsDelivery: current,
            allowedRoot: current ? currentRoot : nil
        )
    }
}

enum AssetContainment {
    static func fileURL(_ url: URL, isContainedIn allowedRoot: URL) throws -> URL {
        let rootURL = allowedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = try resolvedFileURL(url.standardizedFileURL, depth: 0)
        let rootPath = AssetAuthority.directoryPath(rootURL)
        let candidatePath = candidate.path(percentEncoded: false)
        guard candidatePath == rootPath || candidatePath.hasPrefix("\(rootPath)/") else {
            throw AssetURLResolverError.pathEscapesRoot
        }
        return candidate
    }

    /// Follows a symlink even when its target does not exist yet. A dangling
    /// link is not treated as the in-root path it occupies.
    private static func resolvedFileURL(_ url: URL, depth: Int) throws -> URL {
        if depth > 8 {
            throw AssetURLResolverError.pathEscapesRoot
        }
        let path = url.path(percentEncoded: false)
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return url.resolvingSymlinksInPath()
        }
        let destinationURL = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination, isDirectory: false)
            : url.deletingLastPathComponent().appendingPathComponent(destination, isDirectory: false)
        return try resolvedFileURL(destinationURL.standardizedFileURL, depth: depth + 1)
    }
}
