import Foundation
import MarkdownCore

public enum CompletionWorkspaceProviderError: Error, Equatable {
    case currentFileOutsideWorkspace
    case workspaceEntryEscapesRoot(String)
}

public struct CompletionWorkspaceProvider: Sendable {
    public init() {}

    public func workspace(
        rootURL: URL,
        currentFileURL: URL,
        currentText: String,
        snapshot: WorkspaceFileSnapshot
    ) throws -> CompletionWorkspace {
        let currentRelativePath = try relativePath(for: currentFileURL, rootURL: rootURL)
        let markdownPaths = snapshot.entries
            .filter { $0.kind == .markdown || $0.kind == .mdx }
            .map(\.relativePath)
            .sorted()
        let imagePaths = snapshot.entries
            .filter { $0.kind == .image }
            .map(\.relativePath)
            .sorted()
        let frontmatterKeys = try siblingFrontmatterKeys(
            rootURL: rootURL,
            currentRelativePath: currentRelativePath,
            markdownPaths: markdownPaths
        )

        return CompletionWorkspace(
            currentFilePath: currentRelativePath,
            markdownFilePaths: markdownPaths,
            imageFilePaths: imagePaths,
            currentFileHeadingAnchors: headingAnchors(in: currentText),
            frontmatterKeys: frontmatterKeys,
            componentNames: FileKind(url: currentFileURL) == .mdx ? MDXImportParser.componentNames(in: currentText) : []
        )
    }

    public func workspace(
        rootURL: URL?,
        currentFileURL: URL?,
        currentText: String,
        tree: WorkspaceFileTree?
    ) throws -> CompletionWorkspace {
        guard let rootURL, let currentFileURL, let tree else {
            return CompletionWorkspace(
                currentFilePath: currentFileURL?.lastPathComponent,
                currentFileHeadingAnchors: headingAnchors(in: currentText),
                componentNames: currentFileURL
                    .flatMap(FileKind.init(url:)) == .mdx ? MDXImportParser.componentNames(in: currentText) : []
            )
        }

        return try workspace(
            rootURL: rootURL,
            currentFileURL: currentFileURL,
            currentText: currentText,
            snapshot: WorkspaceFileSnapshot(entries: snapshotEntries(in: tree.root))
        )
    }
}

private extension CompletionWorkspaceProvider {
    static let siblingFrontmatterReadLimit = 50

    func snapshotEntries(in node: WorkspaceFileNode) -> [WorkspaceFileSnapshot.Entry] {
        var entries: [WorkspaceFileSnapshot.Entry] = []
        for child in node.children {
            entries.append(WorkspaceFileSnapshot.Entry(
                relativePath: child.relativePath,
                kind: child.kind,
                identity: child.id,
                contentModificationDate: child.contentModificationDate
            ))
            entries.append(contentsOf: snapshotEntries(in: child))
        }
        return entries
    }

    func siblingFrontmatterKeys(
        rootURL: URL,
        currentRelativePath: String,
        markdownPaths: [String]
    ) throws -> [String] {
        var keys: [String] = []
        var seen: Set<String> = []

        try SecurityScopedAccess.withAccess(to: rootURL) {
            let siblingPaths = markdownPaths.lazy
                .filter { $0 != currentRelativePath }
                // Keep completion metadata refresh bounded in large content workspaces.
                .prefix(Self.siblingFrontmatterReadLimit)

            for relativePath in siblingPaths {
                let url = try containedURL(rootURL: rootURL, relativePath: relativePath)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    continue
                }

                for key in frontmatterKeys(in: text) where !seen.contains(key) {
                    seen.insert(key)
                    keys.append(key)
                }
            }
        }

        return keys
    }

    func relativePath(for fileURL: URL, rootURL: URL) throws -> String {
        let rootPath = normalizedDirectoryPath(rootURL)
        let filePath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)

        guard filePath.hasPrefix("\(rootPath)/") else {
            throw CompletionWorkspaceProviderError.currentFileOutsideWorkspace
        }

        return String(filePath.dropFirst(rootPath.count + 1))
    }

    func containedURL(rootURL: URL, relativePath: String) throws -> URL {
        guard !relativePath.split(separator: "/").contains("..") else {
            throw CompletionWorkspaceProviderError.workspaceEntryEscapesRoot(relativePath)
        }

        let url = rootURL.appendingPathComponent(relativePath, isDirectory: false)
        let rootPath = normalizedDirectoryPath(rootURL)
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        guard path.hasPrefix("\(rootPath)/") else {
            throw CompletionWorkspaceProviderError.workspaceEntryEscapesRoot(relativePath)
        }
        return url
    }

    func normalizedDirectoryPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    func headingAnchors(in text: String) -> [String] {
        var anchors: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let markerCount = line.prefix { $0 == "#" }.count
            guard (1 ... 6).contains(markerCount),
                  line.dropFirst(markerCount).first?.isWhitespace == true
            else {
                continue
            }

            let heading = line.dropFirst(markerCount).trimmingCharacters(in: .whitespaces)
            let anchor = slug(for: heading)
            if !anchor.isEmpty {
                anchors.append("#\(anchor)")
            }
        }
        return anchors
    }

    func slug(for heading: String) -> String {
        var result = ""
        var previousWasSeparator = false

        for scalar in heading.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "-" || scalar == "_" {
                if !result.isEmpty, !previousWasSeparator {
                    result.append("-")
                    previousWasSeparator = true
                }
            }
        }

        while result.hasSuffix("-") {
            result.removeLast()
        }
        return result
    }

    func frontmatterKeys(in text: String) -> [String] {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else {
            return []
        }

        var keys: [String] = []
        var isFirstLine = true
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if isFirstLine {
                isFirstLine = false
                continue
            }
            if line == "---" {
                break
            }
            guard !line.isEmpty,
                  !line.hasPrefix("#"),
                  let colon = line.firstIndex(of: ":")
            else {
                continue
            }

            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                keys.append(key)
            }
        }
        return keys
    }
}
