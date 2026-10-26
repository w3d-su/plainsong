import Foundation
import MarkdownCore

public enum CompletionWorkspaceProviderError: Error, Equatable {
    case currentFileOutsideWorkspace
    case workspaceEntryEscapesRoot(String)
}

/// Completion metadata that depends on the installed workspace capture and the current
/// file's location, but not on the current file's text.
public struct CompletionWorkspaceBase: Sendable, Equatable {
    public let currentFilePath: String
    public let currentFileKind: FileKind?
    public let markdownFilePaths: [String]
    public let imageFilePaths: [String]
    public let frontmatterKeys: [String]

    public init(
        currentFilePath: String,
        currentFileKind: FileKind?,
        markdownFilePaths: [String],
        imageFilePaths: [String],
        frontmatterKeys: [String]
    ) {
        self.currentFilePath = currentFilePath
        self.currentFileKind = currentFileKind
        self.markdownFilePaths = markdownFilePaths
        self.imageFilePaths = imageFilePaths
        self.frontmatterKeys = frontmatterKeys
    }
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
        try workspace(
            base: workspaceBase(
                rootAuthority: rootAuthority,
                currentFileLocation: currentFileLocation,
                snapshot: snapshot
            ),
            currentText: currentText
        )
    }

    /// The workspace-derived half of completion metadata: snapshot paths and the sibling
    /// frontmatter keys. It depends only on the installed capture and the current file's
    /// location, so callers cache it per capture and recompute only `workspace(base:...)`
    /// while the user types.
    public func workspaceBase(
        rootAuthority: WorkspaceFileSystemRootAuthority,
        currentFileLocation: WorkspaceFileSystemLocation,
        snapshot: WorkspaceFileSnapshot
    ) throws -> CompletionWorkspaceBase {
        guard currentFileLocation.rootAuthority == rootAuthority else {
            throw CompletionWorkspaceProviderError.currentFileOutsideWorkspace
        }
        let currentRelativePath = currentFileLocation.relativePath
        let markdownPaths = snapshot.entries
            .filter { $0.kind == .markdown || $0.kind == .mdx }
            .map(\.relativePath)
            .sorted(by: byteOrderedPath)
        let imagePaths = snapshot.entries
            .filter { $0.kind == .image }
            .map(\.relativePath)
            .sorted(by: byteOrderedPath)
        for relativePath in markdownPaths + imagePaths {
            guard (try? rootAuthority.location(relativePath: relativePath)) != nil else {
                throw CompletionWorkspaceProviderError.workspaceEntryEscapesRoot(relativePath)
            }
        }
        let frontmatterKeys = siblingFrontmatterKeys(
            rootAuthority: rootAuthority,
            currentRelativePath: currentRelativePath,
            markdownPaths: markdownPaths
        )

        return CompletionWorkspaceBase(
            currentFilePath: currentRelativePath,
            currentFileKind: FileKind(url: currentFileLocation.fileURL),
            markdownFilePaths: markdownPaths,
            imageFilePaths: imagePaths,
            frontmatterKeys: frontmatterKeys
        )
    }

    /// Combines a cached base with metadata derived from the current text only.
    public func workspace(base: CompletionWorkspaceBase, currentText: String) -> CompletionWorkspace {
        CompletionWorkspace(
            currentFilePath: base.currentFilePath,
            markdownFilePaths: base.markdownFilePaths,
            imageFilePaths: base.imageFilePaths,
            currentFileHeadingAnchors: headingAnchors(in: currentText),
            frontmatterKeys: base.frontmatterKeys,
            componentNames: base.currentFileKind == .mdx
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

extension CompletionWorkspaceProvider {
    /// Frontmatter sits at the start of a file; reading a bounded prefix keeps a typing pause
    /// from loading (and hashing) whole sibling documents. Keys after this many bytes of one
    /// sibling's frontmatter are not offered.
    static let siblingFrontmatterPrefixByteLimit = 32 * 1024

    /// Reads at most `siblingFrontmatterPrefixByteLimit` bytes through the anchored,
    /// no-follow descriptor walk. No digest is computed: completion only needs keys.
    static func frontmatterPrefixText(at location: WorkspaceFileSystemLocation) -> String? {
        guard FileKind(url: location.fileURL) != nil,
              let data = try? WorkspaceAnchoredFileSystem.read(
                  location,
                  maximumByteCount: siblingFrontmatterPrefixByteLimit
              ).data
        else {
            return nil
        }
        return decodedUTF8Prefix(
            data,
            mayEndInsideScalar: data.count >= siblingFrontmatterPrefixByteLimit
        )
    }

    /// A bounded read can stop inside a multi-byte scalar. Drop at most the three bytes of an
    /// incomplete trailing scalar; anything else that is not UTF-8 is rejected as before.
    static func decodedUTF8Prefix(_ data: Data, mayEndInsideScalar: Bool) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        guard mayEndInsideScalar else { return nil }
        for droppedByteCount in 1 ... 3 where data.count > droppedByteCount {
            if let text = String(data: data.dropLast(droppedByteCount), encoding: .utf8) {
                return text
            }
        }
        return nil
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
    ) -> [String] {
        var keys: [String] = []
        var seen: Set<String> = []
        let currentPathKey = WorkspacePathByteKey(currentRelativePath)

        let siblingPaths = markdownPaths.lazy
            .filter { WorkspacePathByteKey($0) != currentPathKey }
            // Keep completion metadata refresh bounded in large content workspaces.
            .prefix(Self.siblingFrontmatterReadLimit)

        // Every sibling shares the root's security scope: enter it once for the whole pass.
        SecurityScopedAccess.withAccess(to: rootAuthority.securityScopedURL) {
            for relativePath in siblingPaths {
                guard let location = try? rootAuthority.location(relativePath: relativePath),
                      let text = Self.frontmatterPrefixText(at: location)
                else {
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

    func byteOrderedPath(_ first: String, _ second: String) -> Bool {
        WorkspacePathByteKey(first) < WorkspacePathByteKey(second)
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
