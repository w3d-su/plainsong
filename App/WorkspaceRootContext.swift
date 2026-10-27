import EditorKit
import Foundation
import WorkspaceKit

/// Workspace-root state (`docs/window-state-gates.md` §3.2): one scan snapshot, root
/// authority, generation, security scope, watcher, deferred refresh, image-placement fence,
/// and thumbnail fan-out per root. Nothing here is published.
///
/// Windows PR B1: `AppState` owns the only instance and forwards every property under its
/// original name (`AppState+WorkspaceRootForwarding.swift`). Reference counting by the
/// windows that share a root is PR D1.
@MainActor
final class WorkspaceRootContext {
    /// Set by `AppState.init`; records an Export as HTML… context change. Until then a call
    /// goes to `UnwiredContainerHook`.
    var onExportHTMLContextChange: @MainActor (ExportHTMLStopReason, StaticString, UInt) -> Void = { _, fileID, line in
        UnwiredContainerHook.report("WorkspaceRootContext.onExportHTMLContextChange", fileID: fileID, line: line)
    }

    var workspaceSnapshot: WorkspaceFileSnapshot?
    var workspaceSearchRootAuthority: WorkspaceFileSystemRootAuthority?
    /// Generation that installed the current snapshot/authority pair. Search requires this to
    /// equal `workspaceGeneration` so a reload that has advanced generation cannot label an
    /// old capture as the new generation while the replacement scan is still in flight.
    var workspaceInstalledCaptureGeneration: UInt64?
    var workspaceGeneration: UInt64 = 0
    var workspaceReloadTask: Task<Void, Never>?
    /// Deterministic test seam at the final root-proof -> reload-activation boundary.
    var workspaceReloadPostProofHook: (@MainActor () throws -> Void)?
    /// Deterministic test seam after the authority-bound activation file is loaded.
    var workspaceReloadPostLoadHook: (@MainActor () throws -> Void)?
    /// Deterministic test seam after activation-file preparation but before the final root proof.
    var workspaceReloadPostPrepareHook: (@MainActor () throws -> Void)?
    var workspaceAccess: SecurityScopedResourceAccess? {
        didSet {
            if oldValue !== workspaceAccess { noteExportHTMLContextChange(.workspaceChanged) }
        }
    }

    var workspaceWatcher: WorkspaceEventWatcher?
    /// Watcher and App-owned namespace refreshes must not publish a tree captured while a
    /// rename/move/Trash transaction has temporarily staged or relocated entries.
    var workspaceMutationRefreshPending = false
    /// True only when a deferred refresh came from the ordinary watcher/App refresh path and
    /// therefore must replay external-change inspection after the namespace fence.
    var workspaceMutationExternalRefreshPending = false
    /// Retains the pre-mutation root proof so a watcher event deferred across the generation
    /// fence can still inspect every managed session, not only the current document.
    var workspaceMutationRefreshRootAuthority: WorkspaceFileSystemRootAuthority?
    /// Image placement performs filesystem work away from the main actor. A workspace mutation
    /// must not start while that placement owns the namespace.
    var workspaceImageAssetInsertionCount = 0
    /// Test seam for holding descriptor-relative image cleanup at a namespace boundary.
    var editorImageAssetDiscardEventHandler: EditorImageAssetDiscardEventHandler?
    let editorImageThumbnailRefreshProxy = EditorImageThumbnailRefreshProxy()

    deinit {
        workspaceReloadTask?.cancel()
        workspaceWatcher?.stop()
    }

    func noteExportHTMLContextChange(
        _ reason: ExportHTMLStopReason,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) {
        onExportHTMLContextChange(reason, fileID, line)
    }
}
