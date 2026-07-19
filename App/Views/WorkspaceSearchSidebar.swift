import MarkdownCore
import SwiftUI

/// Workspace content-search chrome (WS3C Search mode).
///
/// Query publication goes through AppState UI helpers into the existing
/// `setWorkspaceSearchQuery` / `clearWorkspaceSearch` contract.
/// Grouped results, keyboard activation, and detailed status land in later WS3C PRs.
///
/// Focus is AppKit first-responder routing on the owned Search `NSTextField`
/// (`WorkspaceSearchQueryField`), **not** SwiftUI `FocusState`. Only the hosting key window may
/// apply a `focusRequestID`; key state and field binding are re-read live after every suspension
/// (`WindowKeyStateTracker`). A cancelable, request-scoped retry loop covers the first `⌘⇧F`
/// path where mode flips `.files → .search` while the field is still mounting.
struct WorkspaceSearchSidebar: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var windowKeyState = WindowKeyStateTracker()
    /// Cancelable attempt for the latest focus request observed by this window.
    @State private var focusAttemptTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            queryField
            optionToggles
            hintSection
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WindowKeyStateReader(tracker: windowKeyState))
        .onAppear {
            scheduleFocusAttempt()
        }
        .onDisappear {
            focusAttemptTask?.cancel()
            focusAttemptTask = nil
        }
        .onChange(of: appState.workspaceSearchUI.focusRequestID) { _, _ in
            scheduleFocusAttempt()
        }
        .onChange(of: windowKeyState.keyEpoch) { _, _ in
            scheduleFocusAttempt()
        }
        .onChange(of: windowKeyState.searchFieldMountEpoch) { _, _ in
            // Owned field registered after `.files → .search` without a key change.
            scheduleFocusAttempt()
        }
        .onChange(of: appState.workspaceSearchFocusKeyEpoch) { _, _ in
            scheduleFocusAttempt()
        }
    }

    private var queryField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            WorkspaceSearchQueryField(
                text: queryTextBinding,
                windowKeyState: windowKeyState,
                isEnabled: appState.canUseWorkspaceSearch
            )
            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)

            if !appState.workspaceSearchUI.queryText.isEmpty {
                Button {
                    appState.updateWorkspaceSearchQueryText("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private var optionToggles: some View {
        HStack(spacing: 8) {
            Toggle(isOn: matchCaseBinding) {
                Text("Aa")
                    .font(.system(.body, design: .rounded).weight(.medium))
            }
            .toggleStyle(.button)
            .help("Match Case (off = smart case)")
            .accessibilityLabel("Match Case")
            .disabled(!appState.canUseWorkspaceSearch)

            Toggle(isOn: wholeWordBinding) {
                Text("Whole Word")
                    .font(.caption)
            }
            .toggleStyle(.button)
            .help("Match whole words only")
            .accessibilityLabel("Whole Word")
            .disabled(!appState.canUseWorkspaceSearch)
        }
    }

    @ViewBuilder
    private var hintSection: some View {
        if !appState.canUseWorkspaceSearch {
            Text("Open a folder workspace to search.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if !appState.isWorkspaceSearchReady {
            Text("Preparing workspace…")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if appState.workspaceSearchUI.queryText.isEmpty {
            Text("Type to search Markdown and MDX files.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var queryTextBinding: Binding<String> {
        Binding(
            get: { appState.workspaceSearchUI.queryText },
            set: { appState.updateWorkspaceSearchQueryText($0) }
        )
    }

    private var matchCaseBinding: Binding<Bool> {
        Binding(
            get: { appState.workspaceSearchUI.matchCase },
            set: { appState.setWorkspaceSearchMatchCase($0) }
        )
    }

    private var wholeWordBinding: Binding<Bool> {
        Binding(
            get: { appState.workspaceSearchUI.wholeWord },
            set: { appState.setWorkspaceSearchWholeWord($0) }
        )
    }

    private func isLiveKeyWindow(tracker: WindowKeyStateTracker) -> Bool {
        appState.isWorkspaceSearchFocusKeyWindow(tracker.window)
    }

    /// Starts or replaces a cancelable, request-scoped focus attempt for this window.
    private func scheduleFocusAttempt() {
        let tracker = windowKeyState
        let requestID = appState.workspaceSearchUI.focusRequestID
        let appliedID = appState.workspaceSearchUI.focusAppliedID
        guard WorkspaceSearchFocusArbitration.shouldApplyFocus(
            requestID: requestID,
            appliedID: appliedID,
            isKeyWindow: isLiveKeyWindow(tracker: tracker)
        ) else {
            return
        }

        focusAttemptTask?.cancel()
        let attemptID = requestID
        focusAttemptTask = Task { @MainActor in
            // Bounded retries: covers late TextField mount after `.files → .search` without
            // depending solely on a single 16 ms sleep or keyEpoch changes.
            for _ in 0 ..< 40 {
                guard !Task.isCancelled else { return }
                guard isLiveKeyWindow(tracker: tracker) else { return }
                guard appState.workspaceSearchUI.focusRequestID == attemptID else { return }
                guard WorkspaceSearchFocusArbitration.shouldApplyFocus(
                    requestID: attemptID,
                    appliedID: appState.workspaceSearchUI.focusAppliedID,
                    isKeyWindow: isLiveKeyWindow(tracker: tracker)
                ) else {
                    return
                }

                // Keep resolving the concrete Search field; layout may install it mid-loop.
                tracker.refreshBoundSearchFieldIfNeeded()

                if let window = tracker.window, isLiveKeyWindow(tracker: tracker) {
                    WorkspaceSearchFieldFocus.makeSearchFieldFirstResponder(
                        in: window,
                        preferredField: tracker.resolvedSearchField()
                    )
                }

                if confirmAndMarkFocusIfNeeded(attemptID: attemptID, tracker: tracker) {
                    return
                }

                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    /// Returns `true` when the global applied receipt was advanced for `attemptID`.
    @discardableResult
    private func confirmAndMarkFocusIfNeeded(
        attemptID: UInt64,
        tracker: WindowKeyStateTracker
    ) -> Bool {
        guard isLiveKeyWindow(tracker: tracker) else { return false }
        guard appState.workspaceSearchUI.focusRequestID == attemptID else { return false }
        guard WorkspaceSearchFocusArbitration.shouldApplyFocus(
            requestID: attemptID,
            appliedID: appState.workspaceSearchUI.focusAppliedID,
            isKeyWindow: isLiveKeyWindow(tracker: tracker)
        ) else {
            return false
        }
        guard let window = tracker.window else { return false }
        let searchField = tracker.resolvedSearchField()

        if !WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(
            in: window,
            expectedField: searchField
        ) {
            guard isLiveKeyWindow(tracker: tracker),
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
        guard isLiveKeyWindow(tracker: tracker) else { return false }
        appState.markWorkspaceSearchFocusApplied(attemptID)
        return true
    }
}
