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
        let rootAuthority = try WorkspaceFileSystemRootAuthority(rootURL: rootURL)
        let currentFileLocation: WorkspaceFileSystemLocation
        do {
            currentFileLocation = try rootAuthority.canonicalizedLocation(
                forFileURL: currentFileURL
            )
        } catch {
            throw CompletionWorkspaceProviderError.currentFileOutsideWorkspace
        }
        return try workspace(
            rootAuthority: rootAuthority,
            currentFileLocation: currentFileLocation,
            currentText: currentText,
            snapshot: snapshot
        )
    }

    /// Builds completion metadata through the same retained root authority as the installed
    /// workspace snapshot. Sibling contents are never reopened from a mutable root URL.
    public func workspace(
        rootAuthority: WorkspaceFileSystemRootAuthority,
        currentFileLocation: WorkspaceFileSystemLocation,
        currentText: String,
        snapshot: WorkspaceFileSnapshot
    ) throws -> CompletionWorkspace {
        guard currentFileLocation.rootAuthority == rootAuthority else {
            throw CompletionWorkspaceProviderError.currentFileOutsideWorkspace
        }
        let currentRelativePath = currentFileLocation.relativePath
        let markdownPaths = snapshot.entries
            .filter { $0.kind == .markdown || $0.kind == .mdx }
            .map(\.relativePath)
            .sorted()
        let imagePaths = snapshot.entries
            .filter { $0.kind == .image }
            .map(\.relativePath)
            .sorted()
        for relativePath in markdownPaths + imagePaths {
            guard (try? rootAuthority.location(relativePath: relativePath)) != nil else {
                throw CompletionWorkspaceProviderError.workspaceEntryEscapesRoot(relativePath)
            }
        }
        let frontmatterKeys = try siblingFrontmatterKeys(
            rootAuthority: rootAuthority,
            currentRelativePath: currentRelativePath,
            markdownPaths: markdownPaths
        )

        return CompletionWorkspace(
            currentFilePath: currentRelativePath,
            markdownFilePaths: markdownPaths,
            imageFilePaths: imagePaths,
            currentFileHeadingAnchors: headingAnchors(in: currentText),
            frontmatterKeys: frontmatterKeys,
            componentNames: FileKind(url: currentFileLocation.fileURL) == .mdx
                ? MDXImportParser.componentNames(in: currentText)
                : []
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
        rootAuthority: WorkspaceFileSystemRootAuthority,
        currentRelativePath: String,
        markdownPaths: [String]
    ) throws -> [String] {
        var keys: [String] = []
        var seen: Set<String> = []
        let fileStore = MarkdownFileStore()

        let siblingPaths = markdownPaths.lazy
            .filter { $0 != currentRelativePath }
            // Keep completion metadata refresh bounded in large content workspaces.
            .prefix(Self.siblingFrontmatterReadLimit)

        for relativePath in siblingPaths {
            guard let location = try? rootAuthority.location(relativePath: relativePath),
                  let text = try? fileStore.load(at: location).text
            else {
                continue
            }

            for key in frontmatterKeys(in: text) where !seen.contains(key) {
                seen.insert(key)
                keys.append(key)
            }
        }

        return keys
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
