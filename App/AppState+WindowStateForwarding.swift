import AppKit
import Combine
import EditorKit
import MarkdownCore
import WorkspaceKit

/// Window-scoped forwarding façade (`docs/window-state-gates.md` §3.2, Windows PR B1). Each
/// property keeps the name, type, and access level it had as an `AppState` stored property,
/// so no consumer changes in B1. The `private(set)` ones (`layoutMode`,
/// `wysiwygFallbackMessage`, `editorFocusRequestID`) are forwarded in `AppState.swift`.
///
/// Settable properties forward with `_modify`, so `map[key] = …` and `value.field = …`
/// mutate the container's storage in place (no copy of the collection or struct) and the
/// container's `didSet` and `@Published` run exactly once per mutation, as before.
@MainActor
extension AppState {
    var shownSession: DocumentSession {
        get { windowState.shownSession }
        set { windowState.shownSession = newValue }
    }

    var workspaceRootURL: URL? {
        get { windowState.workspaceRootURL }
        _modify { yield &windowState.workspaceRootURL }
    }

    var workspaceTree: WorkspaceFileTree? {
        get { windowState.workspaceTree }
        _modify { yield &windowState.workspaceTree }
    }

    var workspaceSearchState: WorkspaceSearchState {
        get { windowState.workspaceSearchState }
        _modify { yield &windowState.workspaceSearchState }
    }

    var workspaceSearchUI: WorkspaceSearchUIState {
        get { windowState.workspaceSearchUI }
        _modify { yield &windowState.workspaceSearchUI }
    }

    var workspaceSearchFocusKeyEpoch: UInt64 {
        get { windowState.workspaceSearchFocusKeyEpoch }
        _modify { yield &windowState.workspaceSearchFocusKeyEpoch }
    }

    var workspaceSearchFocusKeyWindowCheck: ((NSWindow) -> Bool)? {
        get { windowState.workspaceSearchFocusKeyWindowCheck }
        _modify { yield &windowState.workspaceSearchFocusKeyWindowCheck }
    }

    var workspaceSidebarHiddenWindows: NSHashTable<NSWindow> {
        windowState.workspaceSidebarHiddenWindows
    }

    var editorFindHost: EditorFindHost {
        windowState.editorFindHost
    }

    var editorNavigationCommand: EditorNavigationCommand? {
        get { windowState.editorNavigationCommand }
        _modify { yield &windowState.editorNavigationCommand }
    }

    var showAllFiles: Bool {
        get { windowState.showAllFiles }
        _modify { yield &windowState.showAllFiles }
    }

    var completionWorkspace: CompletionWorkspace {
        get { windowState.completionWorkspace }
        _modify { yield &windowState.completionWorkspace }
    }

    var presentedError: UserVisibleError? {
        get { windowState.presentedError }
        _modify { yield &windowState.presentedError }
    }

    var exportHTMLStatus: ExportHTMLStatus? {
        get { windowState.exportHTMLStatus }
        _modify { yield &windowState.exportHTMLStatus }
    }

    var externalChangePrompt: ExternalChangePrompt? {
        get { windowState.externalChangePrompt }
        _modify { yield &windowState.externalChangePrompt }
    }

    var missingFilePrompt: MissingFilePrompt? {
        get { windowState.missingFilePrompt }
        _modify { yield &windowState.missingFilePrompt }
    }

    var indeterminateFileWriteReconciliationPrompt: IndeterminateFileWriteReconciliationPrompt? {
        get { windowState.indeterminateFileWriteReconciliationPrompt }
        _modify { yield &windowState.indeterminateFileWriteReconciliationPrompt }
    }

    var workspaceSearchPostActivationHook: (@MainActor () throws -> Void)? {
        get { windowState.workspaceSearchPostActivationHook }
        _modify { yield &windowState.workspaceSearchPostActivationHook }
    }

    var workspaceSearchTask: Task<Void, Never>? {
        get { windowState.workspaceSearchTask }
        _modify { yield &windowState.workspaceSearchTask }
    }

    var workspaceSearchEditRefresh: WorkspaceSearchEditRefresh {
        get { windowState.workspaceSearchEditRefresh }
        _modify { yield &windowState.workspaceSearchEditRefresh }
    }

    var workspaceSearchTaskToken: UUID? {
        get { windowState.workspaceSearchTaskToken }
        _modify { yield &windowState.workspaceSearchTaskToken }
    }

    var workspaceSearchQueryGeneration: UInt64 {
        get { windowState.workspaceSearchQueryGeneration }
        _modify { yield &windowState.workspaceSearchQueryGeneration }
    }

    var workspaceSearchRefreshIntent: WorkspaceSearchRefreshIntent? {
        get { windowState.workspaceSearchRefreshIntent }
        _modify { yield &windowState.workspaceSearchRefreshIntent }
    }

    var editorNavigationChannel: EditorNavigationChannelState {
        windowState.editorNavigationChannel
    }

    var completionWorkspaceTask: Task<Void, Never>? {
        get { windowState.completionWorkspaceTask }
        _modify { yield &windowState.completionWorkspaceTask }
    }

    var completionWorkspaceBaseCache: CompletionWorkspaceBaseCache? {
        get { windowState.completionWorkspaceBaseCache }
        _modify { yield &windowState.completionWorkspaceBaseCache }
    }

    var documentChangeCancellable: AnyCancellable? {
        get { windowState.documentChangeCancellable }
        _modify { yield &windowState.documentChangeCancellable }
    }

    var exportHTMLOperations: ExportHTMLOperationRegistry {
        get { windowState.exportHTMLOperations }
        _modify { yield &windowState.exportHTMLOperations }
    }
}
