import EditorKit
import Foundation
import WorkspaceKit

/// Workspace-root forwarding façade (`docs/window-state-gates.md` §3.2, Windows PR B1). Each
/// property keeps the name, type, and access level it had as an `AppState` stored property.
/// Settable properties forward with `_modify` (see `AppState+WindowStateForwarding.swift`).
@MainActor
extension AppState {
    var workspaceSnapshot: WorkspaceFileSnapshot? {
        get { workspaceRootContext.workspaceSnapshot }
        _modify { yield &workspaceRootContext.workspaceSnapshot }
    }

    var workspaceSearchRootAuthority: WorkspaceFileSystemRootAuthority? {
        get { workspaceRootContext.workspaceSearchRootAuthority }
        _modify { yield &workspaceRootContext.workspaceSearchRootAuthority }
    }

    var workspaceInstalledCaptureGeneration: UInt64? {
        get { workspaceRootContext.workspaceInstalledCaptureGeneration }
        _modify { yield &workspaceRootContext.workspaceInstalledCaptureGeneration }
    }

    var workspaceGeneration: UInt64 {
        get { workspaceRootContext.workspaceGeneration }
        _modify { yield &workspaceRootContext.workspaceGeneration }
    }

    var workspaceReloadTask: Task<Void, Never>? {
        get { workspaceRootContext.workspaceReloadTask }
        _modify { yield &workspaceRootContext.workspaceReloadTask }
    }

    var workspaceReloadPostProofHook: (@MainActor () throws -> Void)? {
        get { workspaceRootContext.workspaceReloadPostProofHook }
        _modify { yield &workspaceRootContext.workspaceReloadPostProofHook }
    }

    var workspaceReloadPostLoadHook: (@MainActor () throws -> Void)? {
        get { workspaceRootContext.workspaceReloadPostLoadHook }
        _modify { yield &workspaceRootContext.workspaceReloadPostLoadHook }
    }

    var workspaceReloadPostPrepareHook: (@MainActor () throws -> Void)? {
        get { workspaceRootContext.workspaceReloadPostPrepareHook }
        _modify { yield &workspaceRootContext.workspaceReloadPostPrepareHook }
    }

    var workspaceAccess: SecurityScopedResourceAccess? {
        get { workspaceRootContext.workspaceAccess }
        _modify { yield &workspaceRootContext.workspaceAccess }
    }

    var workspaceWatcher: WorkspaceEventWatcher? {
        get { workspaceRootContext.workspaceWatcher }
        _modify { yield &workspaceRootContext.workspaceWatcher }
    }

    var workspaceMutationRefreshPending: Bool {
        get { workspaceRootContext.workspaceMutationRefreshPending }
        _modify { yield &workspaceRootContext.workspaceMutationRefreshPending }
    }

    var workspaceMutationExternalRefreshPending: Bool {
        get { workspaceRootContext.workspaceMutationExternalRefreshPending }
        _modify { yield &workspaceRootContext.workspaceMutationExternalRefreshPending }
    }

    var workspaceMutationRefreshRootAuthority: WorkspaceFileSystemRootAuthority? {
        get { workspaceRootContext.workspaceMutationRefreshRootAuthority }
        _modify { yield &workspaceRootContext.workspaceMutationRefreshRootAuthority }
    }

    var workspaceImageAssetInsertionCount: Int {
        get { workspaceRootContext.workspaceImageAssetInsertionCount }
        _modify { yield &workspaceRootContext.workspaceImageAssetInsertionCount }
    }

    var editorImageAssetDiscardEventHandler: EditorImageAssetDiscardEventHandler? {
        get { workspaceRootContext.editorImageAssetDiscardEventHandler }
        _modify { yield &workspaceRootContext.editorImageAssetDiscardEventHandler }
    }

    var editorImageThumbnailRefreshProxy: EditorImageThumbnailRefreshProxy {
        workspaceRootContext.editorImageThumbnailRefreshProxy
    }
}
