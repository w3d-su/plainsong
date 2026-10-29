import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    func prepareWorkspaceReloadCurrentDocumentDisposition(
        tree: WorkspaceFileTree,
        rootAuthority: WorkspaceFileSystemRootAuthority
    ) async throws -> PreparedWorkspaceReloadCurrentDocumentDisposition {
        let session = shownSession
        guard let fileURL = sessionStateURL(for: session) else {
            return .unrelated
        }

        let unanchoredWorkspaceLocation: WorkspaceFileSystemLocation? =
            if case let .proven(proof)? = unanchoredManagedSessionOwnershipProofs[
                ObjectIdentifier(session)
            ] {
                proof.installedWorkspaceLocation
            } else {
                nil
            }
        let retainedLocation = retainedAnchoredSessionLocation(for: session)
            ?? unanchoredWorkspaceLocation
        if let retainedLocation, retainedLocation.rootAuthority != rootAuthority {
            // A workspace-to-workspace switch deliberately retains the outgoing editor
            // session until its view is dismantled. If that exact A location is outside B,
            // it is unrelated to B's first snapshot and must not block selecting B's first
            // editable file. A lexical collision inside B remains fail-closed: only the
            // retained A authority may authorize I/O for that session URL.
            guard (try? rootAuthority.relativePath(
                forFileURL: retainedLocation.fileURL
            )) != nil else {
                return .unrelated
            }
            throw AppStateError.invalidSessionIdentity(fileURL)
        }
        let lexicalRelativePath: String
        if let retainedLocation {
            lexicalRelativePath = retainedLocation.relativePath
        } else {
            guard let relativePath = try? rootAuthority.relativePath(forFileURL: fileURL) else {
                return .unrelated
            }
            lexicalRelativePath = relativePath
        }
        let key = retainedLocation?.fileURL ?? fileURL
        let currentLocation = retainedLocation?.rootAuthority == rootAuthority
            ? retainedLocation
            : try rootAuthority.location(relativePath: lexicalRelativePath)

        if let exactNode = firstNode(in: tree.root, relativePath: lexicalRelativePath),
           exactNode.isEditableMarkdown
        {
            return .present(nodeID: exactNode.id)
        }

        let editableNodes = editableWorkspaceNodes(in: tree.root)
        let canonicalRelativePath = retainedLocation?.rootAuthority == rootAuthority
            ? retainedLocation?.relativePath
            : nil
        let matchingNodeID = await Task.detached(priority: .utility) { () -> WorkspaceFileNode.ID? in
            let targetRelativePath = canonicalRelativePath
                ?? (try? rootAuthority.canonicalizedLocation(forFileURL: fileURL).relativePath)
                ?? lexicalRelativePath
            for node in editableNodes {
                // Built through `location(relativePath:)`, never `appendingPathComponent`,
                // which silently decomposes precomposed Unicode (NFC) in `node.relativePath`
                // into decomposed form (NFD) before `canonicalizedLocation` ever sees it.
                guard
                    let candidateURL = try? rootAuthority.location(
                        relativePath: node.relativePath
                    ).fileURL,
                    let location = try? rootAuthority.canonicalizedLocation(
                        forFileURL: candidateURL
                    )
                else {
                    continue
                }
                if ExactSourceText.matches(location.relativePath, targetRelativePath) {
                    return node.id
                }
            }
            return nil
        }.value

        if let matchingNodeID {
            return .present(nodeID: matchingNodeID)
        }
        guard let currentLocation else {
            return .unrelated
        }
        let status = await Task.detached(priority: .utility) {
            WorkspaceNoFollowFileInspector.status(at: currentLocation)
        }.value
        switch status {
        case .missing:
            return .missing(session: session, key: key)
        case .regular:
            // Enumeration may legitimately skip an unreadable entry. Absence from the
            // snapshot alone is not proof that the current file disappeared.
            return .unrelated
        case .symbolicLink:
            throw WorkspaceAnchoredFileSystemError.symbolicLink
        case .notRegularFile:
            throw WorkspaceAnchoredFileSystemError.notRegularFile
        case .unreadable:
            throw WorkspaceAnchoredFileSystemError.unreadable
        }
    }

    func editableWorkspaceNodes(in root: WorkspaceFileNode) -> [WorkspaceFileNode] {
        var result: [WorkspaceFileNode] = []
        if root.isEditableMarkdown {
            result.append(root)
        }
        for child in root.children {
            result.append(contentsOf: editableWorkspaceNodes(in: child))
        }
        return result
    }
}

struct WorkspaceReloadCurrentSessionState: Equatable {
    let version: Int
    let fileURL: URL?
    let fileKind: FileKind
    let isDirty: Bool
    let stateURL: URL?
    let binding: AnchoredWorkspaceSessionFileBinding?
    let indeterminateWrite: WorkspaceIndeterminateFileWrite?
    let indeterminateContext: IndeterminateSessionWriteContext?
    let isDetached: Bool
    let pendingExternalText: String?
    let pendingExternalVersion: ObservedRetainedFileVersion?
    let lastKnownDiskHash: String?
    let lastKnownDiskModificationDate: Date?
    let externalChangeURL: URL?
    let missingFileURL: URL?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version
            && exactPathMatches(lhs.fileURL, rhs.fileURL)
            && lhs.fileKind == rhs.fileKind
            && lhs.isDirty == rhs.isDirty
            && exactPathMatches(lhs.stateURL, rhs.stateURL)
            && lhs.binding == rhs.binding
            && lhs.indeterminateWrite == rhs.indeterminateWrite
            && lhs.indeterminateContext == rhs.indeterminateContext
            && lhs.isDetached == rhs.isDetached
            && exactTextMatches(lhs.pendingExternalText, rhs.pendingExternalText)
            && lhs.pendingExternalVersion == rhs.pendingExternalVersion
            && lhs.lastKnownDiskHash == rhs.lastKnownDiskHash
            && lhs.lastKnownDiskModificationDate == rhs.lastKnownDiskModificationDate
            && exactPathMatches(lhs.externalChangeURL, rhs.externalChangeURL)
            && exactPathMatches(lhs.missingFileURL, rhs.missingFileURL)
    }

    private static func exactPathMatches(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        guard lhs.isFileURL, rhs.isFileURL else { return false }
        return lhs.path(percentEncoded: false).utf8.elementsEqual(
            rhs.path(percentEncoded: false).utf8
        )
    }

    private static func exactTextMatches(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            ExactSourceText.matches(lhs, rhs)
        case (nil, nil):
            true
        default:
            false
        }
    }
}
