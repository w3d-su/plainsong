import Foundation
import WorkspaceKit

/// One Files list's deferred selection open (R22).
///
/// `List(selection:)` applies arrow-key and click selection through NavigationAuthority
/// inside its own view update, so the binding setter must not synchronously publish
/// through `AppState` ("Publishing changes from within view updates"). The setter records
/// the pick here and opens it on the next main-actor turn.
///
/// Held in `@State` as a reference type: mutating these properties must not trigger a
/// SwiftUI update, so they are plain `var`s, not published.
@MainActor
final class FilesSelectionDeferral {
    /// The newest pick not yet applied to `AppState`; the List binding reads it so the
    /// next arrow press advances from the just-chosen row before the deferred open runs.
    var pendingID: WorkspaceFileNode.ID?
    /// Total picks handed to the deferral. `applied` tracks the newest pick that ran.
    var issued = 0
    var applied = 0
    /// The deferred open driving `pendingID`. The tracker outlives the view (per-view
    /// `@State`), so `cancelPendingOpen` must stop it when the navigator unmounts.
    private var openTask: Task<Void, Never>?

    #if DEBUG
        /// Latest live deferral, so hosted tests can observe the retry seam.
        weak static var latestDebugInstance: FilesSelectionDeferral?
        /// Every `selectWorkspaceNode` attempt: (picked node, whether it landed). The
        /// held-reload test reads it instead of timing the 25 ms poll.
        private(set) var openAttempts: [(id: WorkspaceFileNode.ID, landed: Bool)] = []
    #endif

    init() {
        #if DEBUG
            Self.latestDebugInstance = self
        #endif
    }

    /// Open `nodeID` on the next main-actor turn.
    ///
    /// The one-turn delay lands inside a workspace-reload window often enough to matter
    /// (measured 4/5 runs, 29b): `selectWorkspaceNode` refuses while the installed capture
    /// generation lags the workspace generation, and the pick would be dropped. Retry only
    /// while the refusal is that lag — a missing or non-Markdown node, or any refusal
    /// outside the lag, ends the loop immediately, as does a newer applied pick, the
    /// picked document or workspace root changing under the pick, or cancellation.
    ///
    /// `onDroppedPick` runs only when this pick is still the newest and never landed: the
    /// view forces the List's selection back to the tree's selection so the dropped row is
    /// not left highlighted.
    func open(
        id nodeID: WorkspaceFileNode.ID,
        requestingEditorFocus: Bool,
        appState: AppState,
        onDroppedPick: @escaping @MainActor () -> Void
    ) {
        issued += 1
        let sequence = issued
        pendingID = nodeID
        let pickedDocument = appState.currentDocument
        let pickedRoot = appState.workspaceRootURL
        openTask = Task { @MainActor [weak self] in
            guard let self, sequence > applied else { return }
            applied = sequence
            var landed = false
            for _ in 0 ..< 200 {
                appState.selectWorkspaceNode(id: nodeID, requestingEditorFocus: requestingEditorFocus)
                landed = appState.workspaceTree?.selectedNodeID == nodeID
                #if DEBUG
                    openAttempts.append((id: nodeID, landed: landed))
                #endif
                if landed { break }
                let nodeStillPickable =
                    appState.workspaceTree?.node(id: nodeID)?.isEditableMarkdown == true
                let captureLagging = appState.workspaceInstalledCaptureGeneration
                    != appState.workspaceGeneration
                guard nodeStillPickable, captureLagging else { break }
                try? await Task.sleep(nanoseconds: 25_000_000)
                guard !Task.isCancelled,
                      applied == sequence,
                      appState.currentDocument === pickedDocument,
                      appState.workspaceRootURL == pickedRoot
                else { break }
            }
            guard sequence == issued, !Task.isCancelled else { return }
            pendingID = nil
            if !landed { onDroppedPick() }
        }
    }

    /// Stop the pending open and forget its row (the view is gone; nothing reverts).
    func cancelPendingOpen() {
        openTask?.cancel()
        openTask = nil
        pendingID = nil
    }
}
