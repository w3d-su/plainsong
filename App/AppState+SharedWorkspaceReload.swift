import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    /// Reconcile a participant's own filter, expansion, selection, document disposition,
    /// completion metadata, and search against the one installed root capture.
    func reconcileSharedWorkspaceWindow(context: WorkspaceRootContext, generation: UInt64) async throws {
        while true {
            guard workspaceRootContext === context, workspaceRootURL != nil,
                  context.workspaceGeneration == generation,
                  context.workspaceInstalledCaptureGeneration == generation,
                  let snapshot = context.workspaceSnapshot,
                  let authority = context.workspaceSearchRootAuthority
            else { throw CancellationError() }
            try Task.checkCancellation()
            let session = shownSession
            let state = workspaceReloadCurrentSessionState()
            let filter = showAllFiles
            let previousTree = workspaceTree
            var tree = WorkspaceFileTree.reconcile(
                previous: previousTree, snapshot: snapshot, options: .init(showAllFiles: filter)
            )
            let disposition = try await prepareWorkspaceReloadCurrentDocumentDisposition(
                tree: tree, rootAuthority: authority
            )
            guard workspaceRootContext === context, workspaceRootURL != nil,
                  context.workspaceGeneration == generation
            else { throw CancellationError() }
            guard shownSession === session, workspaceReloadCurrentSessionState() == state,
                  showAllFiles == filter, workspaceTree == previousTree
            else { continue }
            switch disposition {
            case let .present(nodeID):
                tree.selectNode(id: nodeID)
            case let .missing(session, key):
                markSessionDetachedFromMissingFile(session, url: key)
                tree.selectNode(id: nil)
            case .unrelated:
                break
            }
            workspaceTree = tree
            scheduleCompletionWorkspaceRefresh(workspaceGeneration: generation)
            resumePendingWorkspaceSearchFromUIIfNeeded()
            resumeWorkspaceSearchRefreshIntentIfNeeded(installedRootAuthority: authority)
            return
        }
    }
}
