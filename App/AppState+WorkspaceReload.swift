import Foundation
import WorkspaceKit

@MainActor
extension AppState {
    func scheduleWorkspaceReload(
        root: URL,
        selectFirstIfNeeded: Bool,
        errorTitle: String,
        handlesExternalChanges: Bool = false
    ) {
        let normalizedRoot = root.standardizedFileURL
        let generation = advanceWorkspaceGeneration()
        workspaceReloadTask?.cancel()

        workspaceReloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await applyWorkspaceReload(
                    root: normalizedRoot,
                    generation: generation,
                    selectFirstIfNeeded: selectFirstIfNeeded
                )
                guard isCurrentWorkspaceReload(root: normalizedRoot, generation: generation) else {
                    return
                }
                if handlesExternalChanges {
                    handleCurrentDocumentExternalChange()
                }
            } catch is CancellationError {
                // A newer reload, workspace switch, or close invalidated this scan.
            } catch {
                guard isCurrentWorkspaceReload(root: normalizedRoot, generation: generation) else {
                    return
                }
                present(error, title: errorTitle)
            }
        }
    }

    /// Direct callers receive their own generation so a slower scan cannot apply stale state.
    func reloadWorkspaceTree(root: URL, selectFirstIfNeeded: Bool) async throws {
        let normalizedRoot = root.standardizedFileURL
        let generation = advanceWorkspaceGeneration()
        try await applyWorkspaceReload(
            root: normalizedRoot,
            generation: generation,
            selectFirstIfNeeded: selectFirstIfNeeded
        )
    }

    func advanceWorkspaceGeneration() -> UInt64 {
        precondition(workspaceGeneration < .max, "Workspace generation exhausted")
        workspaceGeneration += 1
        return workspaceGeneration
    }

    private func applyWorkspaceReload(
        root: URL,
        generation: UInt64,
        selectFirstIfNeeded: Bool
    ) async throws {
        try Task.checkCancellation()
        let snapshot = try await directoryScanner.snapshot(root: root)
        try Task.checkCancellation()
        guard isCurrentWorkspaceReload(root: root, generation: generation) else {
            throw CancellationError()
        }

        var tree = WorkspaceFileTree.reconcile(
            previous: workspaceTree,
            snapshot: snapshot,
            options: .init(showAllFiles: showAllFiles)
        )

        if !selectFirstIfNeeded,
           let currentDocumentNode = nodeForCurrentDocument(in: tree, root: root)
        {
            tree.selectNode(id: currentDocumentNode.id)
        } else if tree.selectedNode == nil || selectFirstIfNeeded {
            tree.selectNode(id: firstEditableNode(in: tree.root)?.id)
        }

        guard isCurrentWorkspaceReload(root: root, generation: generation) else {
            throw CancellationError()
        }
        workspaceSnapshot = snapshot
        workspaceTree = tree
        scheduleCompletionWorkspaceRefresh(workspaceGeneration: generation)

        if let selectedNode = tree.selectedNode, selectedNode.isEditableMarkdown {
            try activateFileSession(
                url: root.appendingPathComponent(selectedNode.relativePath, isDirectory: false)
            )
        }
    }

    private func isCurrentWorkspaceReload(root: URL, generation: UInt64) -> Bool {
        !Task.isCancelled
            && workspaceGeneration == generation
            && workspaceRootURL?.standardizedFileURL == root.standardizedFileURL
    }
}
