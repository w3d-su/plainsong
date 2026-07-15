import Foundation

public enum WorkspaceRootContainmentError: Error, Equatable, Sendable {
    case emptyRelativePath
    case absolutePath(String)
    case traversal(String)
    case fileOutsideRoot
    case symlinkEscape(String)
}

/// Shared component-safe workspace-root containment rules.
///
/// Callers derive a contained URL immediately before opening a file. Every path is
/// standardized and symlink-resolved before the root-prefix check so escapes cannot hide
/// behind relative components or link chains.
public enum WorkspaceRootContainment {
    public static func normalizedRelativePath(_ path: String) throws -> String {
        guard !path.isEmpty else {
            throw WorkspaceRootContainmentError.emptyRelativePath
        }
        guard !path.hasPrefix("/") else {
            throw WorkspaceRootContainmentError.absolutePath(path)
        }
        guard !path.utf8.contains(0) else {
            throw WorkspaceRootContainmentError.traversal(path)
        }

        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                throw WorkspaceRootContainmentError.traversal(path)
            default:
                components.append(component)
            }
        }

        guard !components.isEmpty else {
            throw WorkspaceRootContainmentError.emptyRelativePath
        }
        return components.joined(separator: "/")
    }

    /// Resolves `relativePath` under `rootURL` after rejecting `..` and verifying the final
    /// symlink-resolved location remains inside the root.
    public static func containedURL(rootURL: URL, relativePath: String) throws -> URL {
        let normalizedPath = try normalizedRelativePath(relativePath)
        let root = resolvedRootURL(rootURL)
        let candidate = root.appendingPathComponent(normalizedPath, isDirectory: false)
            .standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath()

        guard isContained(resolvedCandidate, in: root) else {
            throw WorkspaceRootContainmentError.symlinkEscape(relativePath)
        }
        return resolvedCandidate
    }

    /// Resolves a document-relative Markdown image source against a base directory that is
    /// itself under the workspace root. Allows intermediate `..` only while the final
    /// symlink-resolved URL remains contained.
    public static func containedURL(
        rootURL: URL,
        baseDirectoryRelativePath: String,
        sourcePath: String
    ) throws -> (fileURL: URL, workspaceRelativePath: String) {
        let trimmedSource = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            throw WorkspaceRootContainmentError.emptyRelativePath
        }
        guard !trimmedSource.hasPrefix("/") else {
            throw WorkspaceRootContainmentError.absolutePath(trimmedSource)
        }

        let root = resolvedRootURL(rootURL)
        let baseDirectory = try baseDirectoryURL(
            rootURL: root,
            baseDirectoryRelativePath: baseDirectoryRelativePath
        )

        var components = baseDirectory.standardizedFileURL.pathComponents
        for component in trimmedSource.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard components.count > root.pathComponents.count else {
                    throw WorkspaceRootContainmentError.traversal(trimmedSource)
                }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }

        let candidate = URL(fileURLWithPath: NSString.path(withComponents: components))
            .standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        guard isContained(resolvedCandidate, in: root) else {
            throw WorkspaceRootContainmentError.symlinkEscape(trimmedSource)
        }

        let workspaceRelativePath = try relativePath(for: resolvedCandidate, rootURL: root)
        return (resolvedCandidate, workspaceRelativePath)
    }

    public static func relativePath(for fileURL: URL, rootURL: URL) throws -> String {
        let root = resolvedRootURL(rootURL)
        let resolvedFile = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        guard isContained(resolvedFile, in: root) else {
            throw WorkspaceRootContainmentError.fileOutsideRoot
        }

        let rootPath = normalizedDirectoryPath(root.path(percentEncoded: false))
        let filePath = normalizedDirectoryPath(resolvedFile.path(percentEncoded: false))
        if rootPath == "/" {
            return try normalizedRelativePath(String(filePath.dropFirst()))
        }
        return try normalizedRelativePath(String(filePath.dropFirst(rootPath.count + 1)))
    }

    public static func isContained(_ candidateURL: URL, in rootURL: URL) -> Bool {
        let rootPath = normalizedDirectoryPath(
            rootURL.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        )
        let candidatePath = normalizedDirectoryPath(
            candidateURL.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        )
        if rootPath == "/" {
            return candidatePath.hasPrefix("/")
        }
        return candidatePath == rootPath || candidatePath.hasPrefix("\(rootPath)/")
    }

    public static func resolvedRootURL(_ rootURL: URL) -> URL {
        rootURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    public static func normalizedDirectoryPath(_ path: String) -> String {
        guard path != "/" else { return path }
        var result = path
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private static func baseDirectoryURL(
        rootURL: URL,
        baseDirectoryRelativePath: String
    ) throws -> URL {
        let trimmed = baseDirectoryRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." {
            return rootURL
        }
        let normalized = try normalizedRelativePath(trimmed)
        let directory = rootURL.appendingPathComponent(normalized, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard isContained(directory, in: rootURL) else {
            throw WorkspaceRootContainmentError.symlinkEscape(trimmed)
        }
        return directory
    }
}
