import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    func applyWorkspaceReload(
        root: URL,
        capture: WorkspaceDirectorySnapshotCapture,
        generation: UInt64,
        selectFirstIfNeeded: Bool
    ) async throws {
        try Task.checkCancellation()
        let snapshot = capture.snapshot
        try Task.checkCancellation()
        guard isCurrentWorkspaceReload(root: root, generation: generation) else {
            throw CancellationError()
        }

        // Off-main proof that the currently selected root spelling still names the captured
        // physical root. Reject stale captures rather than installing authority A while the
        // mutable selected spelling now opens B (and auto-activation would follow B).
        try await proveSelectedRootStillNamesCapture(
            selectedRoot: root,
            rootAuthority: capture.rootAuthority
        )
        try Task.checkCancellation()
        guard isCurrentWorkspaceReload(root: root, generation: generation) else {
            throw CancellationError()
        }

        let currentDocumentAtPreparation = shownSession
        let currentDocumentStateAtPreparation = workspaceReloadCurrentSessionState()

        var tree = WorkspaceFileTree.reconcile(
            previous: workspaceTree,
            snapshot: snapshot,
            options: .init(showAllFiles: showAllFiles)
        )
        let currentDocumentDisposition = try await prepareWorkspaceReloadCurrentDocumentDisposition(
            tree: tree,
            rootAuthority: capture.rootAuthority
        )

        if selectFirstIfNeeded {
            tree.selectNode(id: firstEditableNode(in: tree.root)?.id)
        } else {
            switch currentDocumentDisposition {
            case let .present(nodeID):
                tree.selectNode(id: nodeID)
            case .missing:
                tree.selectNode(id: nil)
            case .unrelated:
                if tree.selectedNode == nil, sharedWorkspaceFacades.count == 1 {
                    tree.selectNode(id: firstEditableNode(in: tree.root)?.id)
                }
            }
        }

        guard isCurrentWorkspaceReload(root: root, generation: generation) else {
            throw CancellationError()
        }

        let preparedFile = try await prepareWorkspaceReloadFile(
            selectedNode: tree.selectedNode,
            rootAuthority: capture.rootAuthority,
            selectedRoot: root,
            generation: generation
        )
        try workspaceReloadPostPrepareHook?()

        // The activation load may suspend. Re-prove the selected spelling immediately before
        // the uninterrupted App-state commit so a root moved/replaced during that load is
        // rejected instead of publishing capture A under a spelling that now names B.
        try await proveSelectedRootStillNamesCapture(
            selectedRoot: root,
            rootAuthority: capture.rootAuthority
        )

        guard isCurrentWorkspaceReload(root: root, generation: generation) else {
            throw CancellationError()
        }
        guard shownSession === currentDocumentAtPreparation,
              workspaceReloadCurrentSessionState() == currentDocumentStateAtPreparation
        else {
            // User/session lifecycle work won the suspension. Do not apply a tree selection,
            // missing-file disposition, or activation prepared for the superseded document.
            throw WorkspaceReloadRetry.documentStateChanged
        }

        // Cache and retirement state can change while the final root proof suspends. Re-derive the
        // activation source now, then commit it without another suspension so a stale cached or
        // retired source can neither be resurrected nor trip a commit precondition.
        let preparedActivation = try preparedFile.map { preparedFile in
            try prepareAnchoredFileSessionActivation(
                file: preparedFile.file,
                at: preparedFile.location,
                metadata: preparedFile.metadata,
                sha256Digest: preparedFile.sha256Digest,
                preparedImageAssetAuthority: preparedFile.preparedImageAssetAuthority
            )
        }

        // Every throwing filesystem and cache validation is complete. From here through capture
        // installation there is no suspension or throwing operation, so activation and the
        // snapshot/authority/tree become visible as one main-actor transaction.
        if case let .missing(session, key) = currentDocumentDisposition {
            markSessionDetachedFromMissingFile(session, url: key)
        }
        if let preparedActivation {
            commitAnchoredFileSessionActivation(preparedActivation)
        }
        let previousSnapshot = workspaceSnapshot
        workspaceSnapshot = snapshot
        workspaceSearchRootAuthority = capture.rootAuthority
        workspaceInstalledCaptureGeneration = generation
        refreshEditorImageThumbnails(
            previousSnapshot: previousSnapshot,
            currentSnapshot: snapshot
        )
        workspaceTree = tree
        scheduleCompletionWorkspaceRefresh(workspaceGeneration: generation)
        // A newer explicit pre-authority query is resumed first and clears any older retained
        // refresh intent. A merely non-empty inactive field has neither mechanism and stays idle.
        resumePendingWorkspaceSearchFromUIIfNeeded()
        resumeWorkspaceSearchRefreshIntentIfNeeded(
            installedRootAuthority: capture.rootAuthority
        )
        let context = workspaceRootContext
        for peer in context.facades where peer !== self {
            try await peer.reconcileSharedWorkspaceWindow(context: context, generation: generation)
        }
    }

    func resumeWorkspaceSearchRefreshIntentIfNeeded(
        installedRootAuthority: WorkspaceFileSystemRootAuthority
    ) {
        guard let intent = workspaceSearchRefreshIntent else { return }
        guard exactFileURLSpellingMatches(intent.rootURL, installedRootAuthority.originalRootURL),
              intent.rootExpectation == installedRootAuthority.directoryMutationExpectation,
              workspaceSearchAuthorityMatchesCurrentRoot(installedRootAuthority)
        else {
            workspaceSearchRefreshIntent = nil
            return
        }

        workspaceSearchRefreshIntent = nil
        startWorkspaceSearch(intent.query, cancellingPendingEditorNavigation: false)
    }

    func prepareWorkspaceReloadFile(
        selectedNode: WorkspaceFileNode?,
        rootAuthority: WorkspaceFileSystemRootAuthority,
        selectedRoot: URL,
        generation: UInt64
    ) async throws -> PreparedWorkspaceReloadFile? {
        guard let selectedNode, selectedNode.isEditableMarkdown else { return nil }

        // This is the exact post-proof/pre-activation boundary. The production hook is nil;
        // tests replace the selected spelling here to prove the anchored activation fails
        // without installing any part of this capture.
        try workspaceReloadPostProofHook?()
        try Task.checkCancellation()
        guard isCurrentWorkspaceReload(root: selectedRoot, generation: generation) else {
            throw CancellationError()
        }

        // Activation paths use the captured authority's canonical spelling, never a retargeted
        // selected symlink that slipped past a failed proof. The candidate URL is built through
        // `location(relativePath:)`, never `appendingPathComponent`, which silently decomposes
        // precomposed Unicode (NFC) in the leaf into decomposed form (NFD) via CoreFoundation's
        // file-system-representation bridging before `canonicalizedLocation` ever sees it.
        let preparedFile = try await prepareAnchoredWorkspaceReloadFile(
            rootAuthority: rootAuthority,
            candidateURL: rootAuthority.location(
                relativePath: selectedNode.relativePath
            ).fileURL
        )
        try workspaceReloadPostLoadHook?()
        try Task.checkCancellation()
        guard isCurrentWorkspaceReload(root: selectedRoot, generation: generation) else {
            throw CancellationError()
        }
        return preparedFile
    }
}

enum WorkspaceReloadRetry: Error {
    case documentStateChanged
}

enum PreparedWorkspaceReloadCurrentDocumentDisposition {
    case present(nodeID: WorkspaceFileNode.ID)
    case missing(session: DocumentSession, key: URL)
    case unrelated
}
