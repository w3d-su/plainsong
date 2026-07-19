import AppKit
import Foundation
import MarkdownCore

@MainActor
extension AppState {
    /// Folder workspace is required for content search (single-file mode stays disabled).
    var canUseWorkspaceSearch: Bool {
        workspaceRootURL != nil
    }

    /// Snapshot + root authority are installed and match the current generation/root spelling.
    ///
    /// Opening a folder sets `workspaceRootURL` before the async scan finishes. Typing during that
    /// window records a generation-scoped pending resume instead of calling `startWorkspaceSearch`.
    var isWorkspaceSearchReady: Bool {
        guard canUseWorkspaceSearch,
              workspaceSnapshot != nil,
              let rootAuthority = workspaceSearchRootAuthority
        else {
            return false
        }
        return workspaceSearchAuthorityMatchesCurrentRoot(rootAuthority)
    }

    /// Selects Files or Search mode. Search is refused without an open folder workspace.
    /// Switching to Files keeps any still-valid search results and query chrome.
    /// Mode changes do **not** request search-field focus (only `focusWorkspaceSearch` does).
    func selectWorkspaceSidebarMode(_ mode: WorkspaceSidebarMode) {
        if mode == .search, !canUseWorkspaceSearch {
            return
        }
        guard workspaceSearchUI.mode != mode else { return }
        var ui = workspaceSearchUI
        ui.mode = mode
        workspaceSearchUI = ui
    }

    /// `Command-Shift-F`: switch to Search and request field focus. Repeated presses always
    /// increment the focus token so the field re-focuses even when already in Search mode.
    func focusWorkspaceSearch() {
        guard canUseWorkspaceSearch else { return }
        var ui = workspaceSearchUI
        ui.mode = .search
        ui.focusRequestID &+= 1
        workspaceSearchUI = ui
    }

    /// Marks a focus request as consumed after the **key** window's owned Search `NSTextField`
    /// is the real first responder (AppKit routing, not SwiftUI `FocusState`).
    ///
    /// Background windows that share AppState must not call this for tokens they ignored.
    /// Idempotent for older or already-applied tokens.
    func markWorkspaceSearchFocusApplied(_ requestID: UInt64) {
        guard requestID == workspaceSearchUI.focusRequestID,
              WorkspaceSearchFocusArbitration.shouldApplyFocus(
                  requestID: requestID,
                  appliedID: workspaceSearchUI.focusAppliedID,
                  isKeyWindow: true
              )
        else {
            return
        }
        var ui = workspaceSearchUI
        ui.focusAppliedID = requestID
        workspaceSearchUI = ui
    }

    /// Live key-window eligibility for a hosting `NSWindow`.
    ///
    /// Always re-query after suspensions; never cache the Bool across `await`. Production uses
    /// `NSWindow.isKeyWindow`; tests may install `workspaceSearchFocusKeyWindowCheck`.
    func isWorkspaceSearchFocusKeyWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        if let workspaceSearchFocusKeyWindowCheck {
            return workspaceSearchFocusKeyWindowCheck(window)
        }
        return window.isKeyWindow
    }

    /// Notifies Search sidebars to re-evaluate pending focus after key eligibility changes
    /// without a new shortcut token (e.g. window activation or a test override flip).
    func refreshWorkspaceSearchFocusKeyRouting() {
        workspaceSearchFocusKeyEpoch &+= 1
    }

    /// Updates the search field and publishes through the existing debounced query contract.
    func updateWorkspaceSearchQueryText(_ text: String) {
        var ui = workspaceSearchUI
        ui.queryText = text
        workspaceSearchUI = ui
        publishWorkspaceSearchQueryFromUI()
    }

    func setWorkspaceSearchMatchCase(_ matchCase: Bool) {
        guard workspaceSearchUI.matchCase != matchCase else { return }
        var ui = workspaceSearchUI
        ui.matchCase = matchCase
        workspaceSearchUI = ui
        publishWorkspaceSearchQueryFromUI()
    }

    func setWorkspaceSearchWholeWord(_ wholeWord: Bool) {
        guard workspaceSearchUI.wholeWord != wholeWord else { return }
        var ui = workspaceSearchUI
        ui.wholeWord = wholeWord
        workspaceSearchUI = ui
        publishWorkspaceSearchQueryFromUI()
    }

    /// Builds a `TextSearchQuery` from UI chrome and starts or clears search.
    ///
    /// Empty text calls `clearWorkspaceSearch()`. Non-empty text only starts when the workspace
    /// search root is ready. While not ready, records `pendingResumeGeneration` for the current
    /// workspace generation so only that install may auto-resume (not every later FSEvent reload).
    func publishWorkspaceSearchQueryFromUI() {
        let text = workspaceSearchUI.queryText
        guard !text.isEmpty else {
            clearPendingWorkspaceSearchUIResume()
            clearWorkspaceSearch()
            return
        }
        guard canUseWorkspaceSearch else {
            clearPendingWorkspaceSearchUIResume()
            clearWorkspaceSearch()
            return
        }
        guard isWorkspaceSearchReady else {
            var ui = workspaceSearchUI
            ui.pendingResumeGeneration = workspaceGeneration
            workspaceSearchUI = ui
            return
        }
        clearPendingWorkspaceSearchUIResume()
        setWorkspaceSearchQuery(workspaceSearchUI.makeTextSearchQuery())
    }

    /// Resumes a generation-scoped pending UI query after authority install.
    ///
    /// No-ops when there is no pending generation, the generation does not match the installed
    /// workspace generation, or the field was cleared. Does **not** re-search solely because the
    /// query field is non-empty after an ordinary reload (refresh is a later WS3C item).
    func resumePendingWorkspaceSearchFromUIIfNeeded() {
        guard let pendingGeneration = workspaceSearchUI.pendingResumeGeneration else { return }
        guard isWorkspaceSearchReady else { return }
        guard pendingGeneration == workspaceGeneration else {
            clearPendingWorkspaceSearchUIResume()
            return
        }
        guard !workspaceSearchUI.queryText.isEmpty else {
            clearPendingWorkspaceSearchUIResume()
            return
        }
        clearPendingWorkspaceSearchUIResume()
        setWorkspaceSearchQuery(workspaceSearchUI.makeTextSearchQuery())
    }

    /// Rebinds an already-pending resume to the new workspace generation after a gen advance
    /// that still has not installed authority (open-scan cancellation / replacement scan).
    /// Does not create a new pending resume from a bare non-empty query field.
    func rebindPendingWorkspaceSearchUIResumeAfterGenerationAdvance() {
        guard workspaceSearchUI.pendingResumeGeneration != nil else { return }
        var ui = workspaceSearchUI
        if ui.queryText.isEmpty {
            ui.pendingResumeGeneration = nil
        } else {
            ui.pendingResumeGeneration = workspaceGeneration
        }
        workspaceSearchUI = ui
    }

    /// Clears search chrome and returns to Files. Used on workspace close/switch only —
    /// switching sidebar mode to Files does not call this.
    ///
    /// Focus tokens are marked fully applied so a later Search picker entry cannot replay them.
    func resetWorkspaceSearchUIState() {
        let requestID = workspaceSearchUI.focusRequestID
        workspaceSearchUI = WorkspaceSearchUIState(
            focusRequestID: requestID,
            focusAppliedID: requestID,
            pendingResumeGeneration: nil
        )
    }

    private func clearPendingWorkspaceSearchUIResume() {
        guard workspaceSearchUI.pendingResumeGeneration != nil else { return }
        var ui = workspaceSearchUI
        ui.pendingResumeGeneration = nil
        workspaceSearchUI = ui
    }
}
