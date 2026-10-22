import Foundation

/// Edit-driven refresh of an active workspace search
/// (`docs/decisions/2026-10-22-edit-driven-search-refresh-waits-for-a-pause.md`).
///
/// Every edit to a workspace document restarted the active search at once. Each restart
/// replaced `workspaceSearchState` with empty results (a whole-window publish and a flash of
/// "Waiting…" per keystroke) and, after the search debounce, re-read every candidate file.
/// It also ran while the Files navigator was showing, where nobody sees the results.
struct WorkspaceSearchEditRefresh {
    /// Typing pause after which an edit restarts the active search.
    var delayNanoseconds: UInt64 = 500_000_000
    var task: Task<Void, Never>?
    /// An edit arrived while the Search navigator was not showing.
    var isPendingUntilSearchShows = false

    mutating func cancel() {
        task?.cancel()
        task = nil
        isPendingUntilSearchShows = false
    }
}

@MainActor
extension AppState {
    /// Restarts the active search once edits pause, or when the Search navigator next shows.
    func scheduleEditDrivenWorkspaceSearchRefresh() {
        workspaceSearchEditRefresh.task?.cancel()
        workspaceSearchEditRefresh.task = nil
        guard workspaceSearchUI.mode == .search else {
            workspaceSearchEditRefresh.isPendingUntilSearchShows = true
            return
        }
        let delay = workspaceSearchEditRefresh.delayNanoseconds
        workspaceSearchEditRefresh.task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            workspaceSearchEditRefresh.task = nil
            restartActiveWorkspaceSearchWithFreshOverlays()
        }
    }

    /// Runs a refresh deferred while the Files navigator was showing.
    func resumeEditDrivenWorkspaceSearchRefreshIfNeeded() {
        guard workspaceSearchUI.mode == .search,
              workspaceSearchEditRefresh.isPendingUntilSearchShows
        else { return }
        workspaceSearchEditRefresh.isPendingUntilSearchShows = false
        restartActiveWorkspaceSearchWithFreshOverlays()
    }
}
