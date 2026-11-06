import AppKit
import Combine
import EditorKit
import MarkdownCore
import WorkspaceKit

/// Window-scoped state (`docs/window-state-gates.md` §3.2): the window's document, layout,
/// editor navigation, Find host, sidebar tree and search, completion metadata, prompts,
/// errors, and Export as HTML… bookkeeping.
///
/// Windows PR B1: `AppState` owns the only instance and forwards every property under its
/// original name (`AppState+WindowStateForwarding.swift`), so all windows still share it.
@MainActor
final class WindowState: ObservableObject {
    /// Set by `AppState.init`. Receives the hooked property's own `#fileID`/`#line`, so the
    /// Replace authority trace still names the input that changed. Until then a call goes
    /// to `UnwiredContainerHook`.
    var onEditorReplaceAuthorityInputChange: @MainActor (StaticString, UInt) -> Void = { fileID, line in
        UnwiredContainerHook.report("WindowState.onEditorReplaceAuthorityInputChange", fileID: fileID, line: line)
    }

    /// Set by `AppState.init`; records an Export as HTML… context change. Until then a call
    /// goes to `UnwiredContainerHook`.
    var onExportHTMLContextChange: @MainActor (ExportHTMLStopReason, StaticString, UInt) -> Void = { _, fileID, line in
        UnwiredContainerHook.report("WindowState.onExportHTMLContextChange", fileID: fileID, line: line)
    }

    @Published var currentDocument: DocumentSession {
        didSet {
            noteEditorReplaceAuthorityInputDidChange()
            if oldValue !== currentDocument { noteExportHTMLContextChange(.documentChanged) }
        }
    }

    @Published var layoutMode: EditorLayoutMode
    @Published var workspaceRootURL: URL? {
        didSet {
            if oldValue != workspaceRootURL { noteExportHTMLContextChange(.workspaceChanged) }
        }
    }

    @Published var workspaceTree: WorkspaceFileTree?
    @Published var workspaceSearchState = WorkspaceSearchState()
    /// Sidebar mode, query chrome, and focus request/applied tokens.
    /// Focus is AppKit first-responder routing on the owned Search `NSTextField`, not SwiftUI `FocusState`.
    @Published var workspaceSearchUI = WorkspaceSearchUIState()
    /// Test seam / multi-window key routing refresh. Bumped when key eligibility may have changed
    /// without a new `focusRequestID` (window activation, or a test override flip).
    @Published var workspaceSearchFocusKeyEpoch: UInt64 = 0
    /// When non-`nil`, replaces `NSWindow.isKeyWindow` for search focus eligibility (tests).
    var workspaceSearchFocusKeyWindowCheck: ((NSWindow) -> Bool)?
    /// Windows whose split-view sidebar is hidden, so ⇧⌘F there opens Search instead of Files.
    let workspaceSidebarHiddenWindows = NSHashTable<NSWindow>.weakObjects()
    let editorFindHost: EditorFindHost
    @Published var editorNavigationCommand: EditorNavigationCommand?
    @Published var showAllFiles = false
    @Published var completionWorkspace: CompletionWorkspace = .empty
    @Published var presentedError: AppStateUserVisibleError?
    @Published var exportHTMLStatus: ExportHTMLStatus? {
        didSet {
            ExportHTMLStatusBanner.announce(exportHTMLStatus, previous: oldValue,
                                            post: exportHTMLOperations.announcementPoster)
        }
    }

    @Published var externalChangePrompt: AppState.ExternalChangePrompt? {
        didSet { noteEditorReplaceAuthorityInputDidChange() }
    }

    @Published var missingFilePrompt: AppState.MissingFilePrompt? {
        didSet { noteEditorReplaceAuthorityInputDidChange() }
    }

    @Published var indeterminateFileWriteReconciliationPrompt:
        IndeterminateFileWriteReconciliationPrompt?
    @Published var wysiwygFallbackMessage: String?
    @Published var editorFocusRequestID = 0 {
        didSet { noteEditorReplaceAuthorityInputDidChange() }
    }

    /// Deterministic test seam after search activation but before its identity arbitration.
    var workspaceSearchPostActivationHook: (@MainActor () throws -> Void)?
    var workspaceSearchTask: Task<Void, Never>?
    var workspaceSearchEditRefresh = WorkspaceSearchEditRefresh()
    var workspaceSearchTaskToken: UUID?
    var workspaceSearchQueryGeneration: UInt64 = 0
    var workspaceSearchRefreshIntent: WorkspaceSearchRefreshIntent?
    let editorNavigationChannel = EditorNavigationChannelState()
    var completionWorkspaceTask: Task<Void, Never>?
    var completionWorkspaceBaseCache: CompletionWorkspaceBaseCache?
    var documentChangeCancellable: AnyCancellable?
    /// Export as HTML… operation bookkeeping (`AppState+ExportHTML.swift`).
    var exportHTMLOperations = ExportHTMLOperationRegistry()

    /// `replaceAuthority` is the registry's app-global generation (§3.2 `editorFindHost` row).
    init(
        shownSession: DocumentSession,
        layoutMode: EditorLayoutMode,
        wysiwygFallbackMessage: String?,
        replaceAuthority: EditorReplaceAuthorityState
    ) {
        currentDocument = shownSession
        self.layoutMode = layoutMode
        self.wysiwygFallbackMessage = wysiwygFallbackMessage
        editorFindHost = EditorFindHost(replaceAuthority: replaceAuthority)
    }

    deinit {
        completionWorkspaceTask?.cancel()
        workspaceSearchTask?.cancel()
    }

    /// The session this window shows, for registry inventories (`docs/window-state-gates.md`
    /// §3.4 I2).
    var shownSession: DocumentSession {
        get { currentDocument }
        set { currentDocument = newValue }
    }

    /// The files whose saving this window's external-change or missing-file prompt blocks
    /// (§3.4 I3).
    var saveBlockingPromptURLs: [URL] {
        [externalChangePrompt?.fileURL, missingFilePrompt?.fileURL].compactMap(\.self)
    }

    func noteEditorReplaceAuthorityInputDidChange(fileID: StaticString = #fileID, line: UInt = #line) {
        onEditorReplaceAuthorityInputChange(fileID, line)
    }

    func noteExportHTMLContextChange(
        _ reason: ExportHTMLStopReason,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) {
        onExportHTMLContextChange(reason, fileID, line)
    }
}
