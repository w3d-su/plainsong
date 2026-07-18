import CryptoKit
import Darwin
import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

final class WorkspaceEditorImageThumbnailAdapter: EditorImageThumbnailLoading {
    private let provider: any WorkspaceImageThumbnailLoading

    init(provider: any WorkspaceImageThumbnailLoading) {
        self.provider = provider
    }

    func loadThumbnail(
        rootURL: URL,
        documentDirectoryRelativePath: String,
        source: String,
        maxPixelSize: Int
    ) async -> EditorImageThumbnailOutcome {
        let outcome = await provider.loadThumbnail(
            rootURL: rootURL,
            documentDirectoryRelativePath: documentDirectoryRelativePath,
            source: source,
            maxPixelSize: maxPixelSize
        )
        return Self.editorOutcome(from: outcome)
    }

    private static func editorOutcome(
        from outcome: WorkspaceImageThumbnailOutcome
    ) -> EditorImageThumbnailOutcome {
        switch outcome {
        case let .ready(thumbnail):
            .ready(EditorImageThumbnail(
                pngData: thumbnail.pngData,
                pixelWidth: thumbnail.pixelWidth,
                pixelHeight: thumbnail.pixelHeight,
                resolvedWorkspaceRelativePath: thumbnail.resolvedWorkspaceRelativePath,
                contentModificationDate: thumbnail.contentModificationDate
            ))
        case let .stayRaw(reason):
            .stayRaw(reason)
        case let .failed(failure):
            .failed(editorFailure(from: failure))
        }
    }

    private static func editorFailure(
        from failure: WorkspaceImageThumbnailFailure
    ) -> EditorImageThumbnailFailure {
        switch failure {
        case .missingFile:
            .missingFile
        case .unreadableFile:
            .unreadableFile
        case .decodeFailed:
            .decodeFailed
        case .emptyImage:
            .emptyImage
        }
    }
}

@MainActor
private final class WorkspaceImageAssetInsertionLease {
    private weak var appState: AppState?
    private var isActive = true

    init(appState: AppState) {
        self.appState = appState
        appState.workspaceImageAssetInsertionCount += 1
    }

    func release() {
        guard isActive else {
            return
        }
        isActive = false
        guard let appState else {
            return
        }
        precondition(appState.workspaceImageAssetInsertionCount > 0)
        appState.workspaceImageAssetInsertionCount -= 1
    }
}

@MainActor
extension AppState {
    func editorImageThumbnailConfiguration(
        for session: DocumentSession,
        presentation: MarkdownEditorDevelopmentPresentation
    ) -> EditorImageThumbnailConfiguration? {
        guard presentation == .inlineFoldRevealWithLinkFolding,
              shouldUseWYSIWYGPresentation,
              let rootURL = workspaceRootURL,
              let documentURL = session.fileURL,
              let documentRelativePath = try? WorkspaceRootContainment.relativePath(
                  for: documentURL,
                  rootURL: rootURL
              )
        else {
            return nil
        }

        return EditorImageThumbnailConfiguration(
            loader: editorImageThumbnailAdapter,
            rootURL: rootURL,
            documentDirectoryRelativePath: (documentRelativePath as NSString).deletingLastPathComponent,
            refreshProxy: editorImageThumbnailRefreshProxy
        )
    }

    func refreshEditorImageThumbnails(
        previousSnapshot: WorkspaceFileSnapshot?,
        currentSnapshot: WorkspaceFileSnapshot
    ) {
        guard let previousSnapshot else {
            return
        }
        editorImageThumbnailRefreshProxy.invalidateThumbnails(
            forWorkspaceRelativePaths: WorkspaceImageThumbnailRefreshPaths.changedRasterPaths(
                from: previousSnapshot,
                to: currentSnapshot
            )
        )
    }

    var editorImageAssetInserter: EditorImageAssetInserter? {
        let sessionIdentity = ObjectIdentifier(currentDocument)
        guard workspaceRootURL != nil,
              !hasWorkspaceMutationRecoveryLoadFailure,
              workspaceMutationNamespaceDepth == 0,
              workspaceMutationRecoveries.isEmpty,
              indeterminateSessionWrites[sessionIdentity] == nil,
              indeterminateSessionWriteContexts[sessionIdentity] == nil,
              !indeterminateWorkspaceMutationSessions.contains(sessionIdentity),
              let installedRootAuthority = workspaceSearchRootAuthority,
              let retainedProof = retainedEditorImageAssetDocumentProof(
                  for: currentDocument
              ),
              retainedProof.location.rootAuthority == installedRootAuthority,
              let retainedAuthority = editorImageAssetDocumentAuthorities[sessionIdentity],
              retainedAuthority.matches(
                  location: retainedProof.location,
                  identity: retainedProof.identity
              )
        else {
            return nil
        }

        // SwiftUI reads this property during body reevaluation. Capture only the exact cached
        // authority here; descriptor construction preceded the coherent read adopted as binding.
        return { [
            weak self,
            weak session = currentDocument,
            location = retainedAuthority.location,
            identity = retainedAuthority.identity,
            authority = retainedAuthority.authority
        ] assets in
            guard let session else {
                return EditorImageAssetInsertion(relativePaths: [])
            }
            return await self?.insertEditorImageAssetsIfWorkspaceMutationAllows(
                assets,
                session: session,
                location: location,
                identity: identity,
                documentAuthority: authority
            ) ?? EditorImageAssetInsertion(relativePaths: [])
        }
    }

    private func retainedEditorImageAssetDocumentProof(
        for session: DocumentSession
    ) -> (location: WorkspaceFileSystemLocation, identity: WorkspaceFileSystemIdentity)? {
        let sessionIdentity = ObjectIdentifier(session)
        if let binding = anchoredSessionFileBindings[sessionIdentity] {
            return (binding.location, binding.identity)
        }
        if case let .proven(proof)? = unanchoredManagedSessionOwnershipProofs[sessionIdentity],
           let installedLocation = proof.installedWorkspaceLocation
        {
            return (installedLocation, proof.identity)
        }
        return nil
    }

    /// Publishes only an authority captured before the coherent load that produced this binding.
    /// With no prepared authority, an exact existing cache may survive; otherwise insertion is
    /// fail-closed. A replacement may advance only through the cached parent lineage. Bootstrap
    /// is reserved for an initial binding or an explicitly preauthorized destination.
    func installEditorImageAssetDocumentAuthority(
        for session: DocumentSession,
        location: WorkspaceFileSystemLocation,
        identity: WorkspaceFileSystemIdentity,
        preparedAuthority: PreparedEditorImageAssetDocumentAuthority?,
        allowsBootstrapWithoutRetainedLineage: Bool
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        let retainedAuthority = editorImageAssetDocumentAuthorities[sessionIdentity]
        // A reusable session's exact cache owns the original namespace. A new observation may
        // reach the same inode through a replacement parent/hard link; never let that same-value
        // proof replace the older descriptor chain.
        if retainedAuthority?.matches(
            location: location,
            identity: identity
        ) == true {
            return
        }

        guard let preparedAuthority,
              preparedAuthority.matches(location: location, identity: identity)
        else {
            return
        }
        if let retainedAuthority {
            guard retainedAuthority.authority.hasSameRetainedParentLineage(
                as: preparedAuthority.authority
            ) else {
                // Keep the older chain as lineage evidence. It no longer matches the adopted
                // leaf proof, so the inserter getter remains unavailable.
                return
            }
        } else if !allowsBootstrapWithoutRetainedLineage {
            return
        }
        editorImageAssetDocumentAuthorities[sessionIdentity] =
            RetainedEditorImageAssetDocumentAuthority(preparedAuthority)
    }

    func discardEditorImageAssetDocumentAuthority(for session: DocumentSession) {
        editorImageAssetDocumentAuthorities[ObjectIdentifier(session)] = nil
    }

    func rebindEditorImageAssetDocumentAuthorityAfterSave(
        for session: DocumentSession,
        location: WorkspaceFileSystemLocation,
        replacing previousIdentity: WorkspaceFileSystemIdentity,
        with identity: WorkspaceFileSystemIdentity
    ) -> PreparedEditorImageAssetDocumentAuthority? {
        let sessionIdentity = ObjectIdentifier(session)
        guard identity != previousIdentity,
              let retainedAuthority = editorImageAssetDocumentAuthorities[sessionIdentity],
              retainedAuthority.matches(
                  location: location,
                  identity: previousIdentity
              )
        else {
            return nil
        }

        return try? SecurityScopedAccess.withAccess(to: location.securityScopedURL) {
            let authority = try retainedAuthority.authority.rebindDocument(
                expectedIdentity: identity
            )
            return PreparedEditorImageAssetDocumentAuthority(
                location: location,
                identity: identity,
                authority: authority
            )
        }
    }

    private func insertEditorImageAssets(
        _ assets: [EditorImageAsset],
        documentAuthority: EditorImageAssetDocumentAuthority
    ) async -> EditorImageAssetInsertion {
        let namespaceLease = WorkspaceImageAssetInsertionLease(appState: self)
        let assetFolderRelativePath = preferences.assetFolderRelativePath
        let discardEventHandler = editorImageAssetDiscardEventHandler

        do {
            let placement = try await Task.detached(priority: .userInitiated) {
                try SecurityScopedAccess.withAccess(
                    to: documentAuthority.location.securityScopedURL
                ) {
                    try placeEditorImageAssets(
                        assets: assets,
                        assetFolderRelativePath: assetFolderRelativePath,
                        documentAuthority: documentAuthority,
                        eventHandler: nil,
                        managesSecurityScope: false
                    )
                }
            }.value

            refreshWorkspaceAfterFileSystemChange()
            let cleanupSecurityScopedURL = placement.createdAssets.first?
                .directory.rootAuthority.securityScopedURL
                ?? placement.documentAuthority.location.securityScopedURL
            return EditorImageAssetInsertion(
                relativePaths: placement.relativePaths,
                validateBeforeCommit: { [weak self] in
                    let isValid = await Task.detached(priority: .userInitiated) {
                        do {
                            try SecurityScopedAccess.withAccess(
                                to: placement.documentAuthority.location.securityScopedURL
                            ) {
                                try validateEditorImageAssetPlacementForCommit(placement)
                            }
                            return true
                        } catch {
                            return false
                        }
                    }.value
                    if !isValid {
                        self?.present(
                            WorkspaceAnchoredFileSystemError.namespaceChanged,
                            title: "Image Location Changed"
                        )
                    }
                    return isValid
                },
                commit: {
                    namespaceLease.release()
                },
                discard: { [weak self] in
                    defer {
                        namespaceLease.release()
                    }
                    let outcome = await Task.detached(priority: .utility) {
                        discardEditorImageAssets(
                            placement.createdAssets,
                            rootURL: cleanupSecurityScopedURL,
                            eventHandler: discardEventHandler
                        )
                    }.value
                    if outcome.didChangeWorkspace {
                        self?.refreshWorkspaceAfterFileSystemChange()
                    }
                    if let issue = outcome.userFacingIssue {
                        self?.present(issue, title: "Image Cleanup Needs Attention")
                    }
                }
            )
        } catch {
            namespaceLease.release()
            if let rollbackError = error as? EditorImageAssetPlacementRollbackError,
               rollbackError.didChangeWorkspace
            {
                refreshWorkspaceAfterFileSystemChange()
            }
            present(error, title: "Could Not Insert Image")
            return EditorImageAssetInsertion(relativePaths: [])
        }
    }

    private func insertEditorImageAssetsIfWorkspaceMutationAllows(
        _ assets: [EditorImageAsset],
        session: DocumentSession,
        location: WorkspaceFileSystemLocation,
        identity: WorkspaceFileSystemIdentity,
        documentAuthority: EditorImageAssetDocumentAuthority
    ) async -> EditorImageAssetInsertion {
        let sessionIdentity = ObjectIdentifier(session)
        guard !hasWorkspaceMutationRecoveryLoadFailure,
              workspaceMutationNamespaceDepth == 0,
              workspaceMutationRecoveries.isEmpty,
              workspaceRootURL != nil,
              indeterminateSessionWrites[sessionIdentity] == nil,
              indeterminateSessionWriteContexts[sessionIdentity] == nil,
              !indeterminateWorkspaceMutationSessions.contains(sessionIdentity),
              let installedRootAuthority = workspaceSearchRootAuthority,
              location.rootAuthority == installedRootAuthority,
              let retainedProof = retainedEditorImageAssetDocumentProof(for: session),
              retainedProof.location == location,
              retainedProof.identity == identity,
              let retainedAuthority = editorImageAssetDocumentAuthorities[sessionIdentity],
              retainedAuthority.matches(location: location, identity: identity),
              retainedAuthority.authority === documentAuthority
        else {
            return EditorImageAssetInsertion(relativePaths: [])
        }
        return await insertEditorImageAssets(
            assets,
            documentAuthority: documentAuthority
        )
    }
}
