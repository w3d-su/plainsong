import AppKit
import SwiftUI

/// Request-scoped retry loop that makes the owned Search `NSTextField` first responder in the
/// designated key window (WS3C PR A; scheduled from `WorkspaceSearchSidebar`).
///
/// Bounded retries (180 × 16 ms) cover a loaded CI runner's `.files → .search` mount race without
/// depending on a single sleep or key-epoch change. In `force` mode (Escape from results) the loop re-focuses
/// the field even when the global `focusRequestID` receipt was already consumed, and never
/// marks new receipts. Key-window eligibility is re-read live on every iteration — never
/// captured across an `await`.
@MainActor
enum WorkspaceSearchFocusAttemptLoop {
    static func isLiveKeyWindow(appState: AppState, tracker: WindowKeyStateTracker) -> Bool {
        appState.isWorkspaceSearchFocusKeyWindow(tracker.window)
    }

    static func run(
        appState: AppState,
        tracker: WindowKeyStateTracker,
        attemptID: UInt64,
        force: Bool
    ) async {
        if force {
            await runForced(appState: appState, tracker: tracker)
        } else {
            await runRequested(appState: appState, tracker: tracker, attemptID: attemptID)
        }
    }

    private static func runForced(
        appState: AppState,
        tracker: WindowKeyStateTracker
    ) async {
        var consecutiveForcedFocusConfirmations = 0
        for _ in 0 ..< 180 {
            guard !Task.isCancelled else { return }
            guard isLiveKeyWindow(appState: appState, tracker: tracker) else {
                consecutiveForcedFocusConfirmations = 0
                guard await pauseBeforeRetry() else { return }
                continue
            }

            tracker.refreshBoundSearchFieldIfNeeded()
            if let window = tracker.window,
               isLiveKeyWindow(appState: appState, tracker: tracker),
               !WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(
                   in: window,
                   expectedField: tracker.resolvedSearchField()
               )
            {
                WorkspaceSearchFieldFocus.makeSearchFieldFirstResponder(
                    in: window,
                    preferredField: tracker.resolvedSearchField()
                )
            }

            if let window = tracker.window,
               WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(
                   in: window,
                   expectedField: tracker.resolvedSearchField()
               )
            {
                consecutiveForcedFocusConfirmations += 1
                // Lowering the results FocusState can apply after the key handler returns.
                // Confirm across multiple main-run-loop turns so a transient field claim
                // cannot be reported as the completed Escape transition.
                if consecutiveForcedFocusConfirmations >= 3 {
                    return
                }
            } else {
                consecutiveForcedFocusConfirmations = 0
            }
            guard await pauseBeforeRetry() else { return }
        }
    }

    private static func runRequested(
        appState: AppState,
        tracker: WindowKeyStateTracker,
        attemptID: UInt64
    ) async {
        for _ in 0 ..< 180 {
            guard !Task.isCancelled else { return }
            guard isLiveKeyWindow(appState: appState, tracker: tracker) else {
                guard await pauseBeforeRetry() else { return }
                continue
            }
            guard appState.workspaceSearchUI.focusRequestID == attemptID else { return }
            guard WorkspaceSearchFocusArbitration.shouldApplyFocus(
                requestID: attemptID,
                appliedID: appState.workspaceSearchUI.focusAppliedID,
                isKeyWindow: isLiveKeyWindow(appState: appState, tracker: tracker)
            ) else {
                return
            }

            tracker.refreshBoundSearchFieldIfNeeded()
            if confirmAndMarkFocusIfNeeded(
                appState: appState,
                tracker: tracker,
                attemptID: attemptID
            ) {
                return
            }
            guard await pauseBeforeRetry() else { return }
        }
    }

    private static func pauseBeforeRetry() async -> Bool {
        do {
            try await Task.sleep(nanoseconds: 16_000_000)
            return true
        } catch {
            return false
        }
    }

    /// Returns `true` when the global applied receipt was advanced for `attemptID`.
    @discardableResult
    static func confirmAndMarkFocusIfNeeded(
        appState: AppState,
        tracker: WindowKeyStateTracker,
        attemptID: UInt64
    ) -> Bool {
        guard isLiveKeyWindow(appState: appState, tracker: tracker) else { return false }
        guard appState.workspaceSearchUI.focusRequestID == attemptID else { return false }
        guard WorkspaceSearchFocusArbitration.shouldApplyFocus(
            requestID: attemptID,
            appliedID: appState.workspaceSearchUI.focusAppliedID,
            isKeyWindow: isLiveKeyWindow(appState: appState, tracker: tracker)
        ) else {
            return false
        }
        guard let window = tracker.window else { return false }
        let searchField = tracker.resolvedSearchField()

        if !WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(
            in: window,
            expectedField: searchField
        ) {
            guard isLiveKeyWindow(appState: appState, tracker: tracker),
                  WorkspaceSearchFieldFocus.makeSearchFieldFirstResponder(
                      in: window,
                      preferredField: searchField
                  ),
                  WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(
                      in: window,
                      expectedField: tracker.resolvedSearchField()
                  )
            else {
                return false
            }
        }
        guard isLiveKeyWindow(appState: appState, tracker: tracker) else { return false }
        appState.markWorkspaceSearchFocusApplied(attemptID)
        return true
    }
}
