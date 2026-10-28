import Foundation
import WorkspaceCore

enum IOSWorkspacePathAuthority {
    static func lastComponent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    static func parentSpelling(_ relativePath: String) -> String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }

    static func childSpelling(parent: String, name: String) -> String {
        if parent.isEmpty {
            return name
        }
        return parent + "/" + name
    }

    static func pathBytes(_ url: URL) -> [UInt8] {
        Array(url.path(percentEncoded: false).utf8)
    }

    /// `URL(fileURLWithPath:)` can NFC-normalize. This keeps the exact UTF-8 spelling.
    static func fileURL(path: String) -> URL {
        var components = URLComponents()
        components.scheme = "file"
        components.path = path.hasPrefix("/") ? path : "/" + path
        return components.url ?? URL(fileURLWithPath: path)
    }

    static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.isFileURL && rhs.isFileURL && pathBytes(lhs) == pathBytes(rhs)
    }

    static func joined(root: URL, relativePath: String) -> String {
        var rootPath = root.path(percentEncoded: false)
        if !rootPath.hasSuffix("/") {
            rootPath.append("/")
        }
        rootPath.append(relativePath)
        return rootPath
    }

    static func directoryContains(root: URL, file: URL, relativePath: String) -> Bool {
        guard root.isFileURL, file.isFileURL else { return false }
        guard WorkspaceRelativePath(spelling: relativePath) != nil else { return false }
        return Array(joined(root: root, relativePath: relativePath).utf8) == pathBytes(file)
    }

    static func isHiddenSpelling(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.hasPrefix(".") }
    }

    static func rejectsSymlinkTarget(_ target: String) -> Bool {
        if target.isEmpty || target.hasPrefix("/") || target.contains("\\") || target.utf8.contains(0) {
            return true
        }
        let parts = target.split(separator: "/", omittingEmptySubsequences: false)
        return parts.contains { $0 == ".." || $0.isEmpty }
    }

    /// One path component beside the document. Traversal, hidden names, and empty
    /// input stay on the default `assets` folder.
    static func normalizedAssetDirectory(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." || trimmed.hasPrefix(".") {
            return "assets"
        }
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.utf8.contains(0) {
            return "assets"
        }
        if trimmed.unicodeScalars.contains(where: { $0.value < 0x20 }) {
            return "assets"
        }
        return trimmed
    }

    /// Document-parent-relative asset leaf. This never climbs to the grant parent.
    static func assetPaths(
        documentRelativePath: String,
        preferredFilename: String,
        operationID: UUID,
        assetFolder: String = "assets"
    ) -> (rootRelative: String, markdownRelative: String)? {
        guard WorkspaceRelativePath(spelling: documentRelativePath) != nil else { return nil }
        guard let leaf = assetLeafName(preferredFilename) else { return nil }
        let folder = normalizedAssetDirectory(assetFolder)
        let parent = parentSpelling(documentRelativePath)
        let directory = childSpelling(parent: parent, name: folder)
        let rootRelative = childSpelling(parent: directory, name: leaf)
        let markdownRelative = childSpelling(parent: folder, name: leaf)
        guard rootRelative != documentRelativePath else { return nil }
        _ = operationID
        return (rootRelative, markdownRelative)
    }

    static func uniquedAssetPaths(
        documentRelativePath: String,
        preferredFilename: String,
        operationID: UUID,
        exists: (String) -> Bool,
        assetFolder: String = "assets"
    ) -> (rootRelative: String, markdownRelative: String)? {
        let folder = normalizedAssetDirectory(assetFolder)
        guard var paths = assetPaths(
            documentRelativePath: documentRelativePath,
            preferredFilename: preferredFilename,
            operationID: operationID,
            assetFolder: folder
        ) else {
            return nil
        }
        if !exists(paths.rootRelative) {
            return paths
        }
        let token = String(operationID.uuidString.prefix(8))
        let name = uniqueName(assetLeafName(preferredFilename) ?? preferredFilename, token: token)
        let parent = parentSpelling(documentRelativePath)
        let directory = childSpelling(parent: parent, name: folder)
        paths.rootRelative = childSpelling(parent: directory, name: name)
        paths.markdownRelative = childSpelling(parent: folder, name: name)
        if exists(paths.rootRelative) || paths.rootRelative == documentRelativePath {
            return nil
        }
        return paths
    }

    private static func assetLeafName(_ preferredFilename: String) -> String? {
        if preferredFilename.isEmpty || preferredFilename == "." || preferredFilename == ".." {
            return nil
        }
        if preferredFilename.contains("/") || preferredFilename.contains("\\") || preferredFilename.utf8.contains(0) {
            return nil
        }
        if preferredFilename.unicodeScalars.contains(where: { $0.value < 0x20 }) {
            return nil
        }
        let ext = (preferredFilename as NSString).pathExtension.lowercased()
        if ext == "md" || ext == "markdown" || ext == "mdx" {
            return nil
        }
        return preferredFilename
    }

    private static func uniqueName(_ name: String, token: String) -> String {
        let nsName = name as NSString
        let ext = nsName.pathExtension
        let base = nsName.deletingPathExtension
        if ext.isEmpty {
            return "\(base)-\(token)"
        }
        return "\(base)-\(token).\(ext)"
    }
}

/// The image-folder name settings may store. Anything that could leave the
/// document's parent is replaced with `assets`.
public enum IOSAssetDirectory {
    public static func normalized(_ name: String) -> String {
        IOSWorkspacePathAuthority.normalizedAssetDirectory(name)
    }
}
