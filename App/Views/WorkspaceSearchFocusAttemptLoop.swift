import AppKit
import SwiftUI

/// Request-scoped retry loop that makes the owned Search `NSTextField` first responder in the
/// designated key window (WS3C PR A; scheduled from `WorkspaceSearchSidebar`).
///
/// Bounded retries (40 × 16 ms) cover the `.files → .search` mount race without depending on a
/// single sleep or key-epoch change. In `force` mode (Escape from results) the loop re-focuses
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
        for _ in 0 ..< 40 {
            guard !Task.isCancelled else { return }
            guard isLiveKeyWindow(appState: appState, tracker: tracker) else { return }

            if !force {
                guard appState.workspaceSearchUI.focusRequestID == attemptID else { return }
                guard WorkspaceSearchFocusArbitration.shouldApplyFocus(
                    requestID: attemptID,
                    appliedID: appState.workspaceSearchUI.focusAppliedID,
                    isKeyWindow: isLiveKeyWindow(appState: appState, tracker: tracker)
                ) else {
                    return
                }
            }

            // Keep resolving the concrete Search field; layout may install it mid-loop.
            tracker.refreshBoundSearchFieldIfNeeded()

            if let window = tracker.window,
               isLiveKeyWindow(appState: appState, tracker: tracker)
            {
                WorkspaceSearchFieldFocus.makeSearchFieldFirstResponder(
                    in: window,
                    preferredField: tracker.resolvedSearchField()
                )
            }

            if force {
                if let window = tracker.window,
                   WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(
                       in: window,
                       expectedField: tracker.resolvedSearchField()
                   )
                {
                    return
                }
            } else if confirmAndMarkFocusIfNeeded(
                appState: appState,
                tracker: tracker,
                attemptID: attemptID
            ) {
                return
            }

            try? await Task.sleep(nanoseconds: 16_000_000)
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
