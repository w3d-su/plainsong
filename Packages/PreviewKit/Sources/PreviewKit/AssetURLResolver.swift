import Foundation

public enum AssetURLResolverError: Error, Equatable {
    case unsupportedScheme
    case emptyPath
    case pathEscapesRoot
}

public struct AssetURLResolver: Sendable {
    private let allowedRoot: URL
    private let allowedRootPath: String

    public init(allowedRoot: URL) {
        self.allowedRoot = allowedRoot.standardizedFileURL.resolvingSymlinksInPath()
        allowedRootPath = Self.normalizedDirectoryPath(self.allowedRoot.path(percentEncoded: false))
    }

    public func resolve(_ url: URL) throws -> URL {
        guard url.scheme == "asset" else {
            throw AssetURLResolverError.unsupportedScheme
        }

        let relativePath = try Self.relativePath(from: url)
        let candidate = allowedRoot
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidatePath = candidate.path(percentEncoded: false)

        guard candidatePath == allowedRootPath || candidatePath.hasPrefix("\(allowedRootPath)/") else {
            throw AssetURLResolverError.pathEscapesRoot
        }

        return candidate
    }

    private static func relativePath(from url: URL) throws -> String {
        let host = url.host(percentEncoded: false) ?? ""
        let path = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pieces = [host, path].filter { !$0.isEmpty }
        let relativePath = pieces.joined(separator: "/")

        guard !relativePath.isEmpty else {
            throw AssetURLResolverError.emptyPath
        }

        return relativePath
    }

    private static func normalizedDirectoryPath(_ path: String) -> String {
        guard path != "/" else { return path }
        var normalized = path
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
