import MarkdownCore
import SwiftUI

/// Workspace content-search chrome (WS3C Search mode).
///
/// Query publication goes through AppState UI helpers into the existing
/// `setWorkspaceSearchQuery` / `clearWorkspaceSearch` contract.
/// Results use a pure presentation model (`WorkspaceSearchResultsPresentation`) rendered in a
/// lazy `List` (WS3C PR B). Keyboard routing (PR C): query-field ↓ selects the first result and
/// focuses the list; ↑/↓ move without wrapping; Return activates via authority-gated lookup;
/// Escape returns field→editor (keeps query/results) or results→field.
///
/// Query-field focus is AppKit first-responder routing on the owned Search `NSTextField`
/// (`WorkspaceSearchQueryField`), **not** SwiftUI `FocusState` for that control. Only the
/// hosting key window may apply a `focusRequestID`; key state and field binding are re-read live
/// after every suspension (`WindowKeyStateTracker`). Results list focus uses SwiftUI
/// `FocusState` only as a secondary surface for ↑/↓/Return/Escape after ↓ from the field
/// **or** after a mouse selection into the list (click modality must match keyboard).
///
/// **Owner keyboard smoke (merge gate for PR C):** field ↓ → results; ↑/↓ no wrap; Return
/// activates; Escape results→field and field→editor (query/results retained); click a row
/// then ↑/↓ still uses the pure reducer. Full hosted coverage is deferred to WS4 XCUITest.
struct WorkspaceSearchSidebar: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var windowKeyState = WindowKeyStateTracker()
    /// Cancelable attempt for the latest focus request observed by this window.
    @State private var focusAttemptTask: Task<Void, Never>?
    /// Selected match row stays view-local (activation uses retained search payload lookup).
    @State private var selectedResultRowID: WorkspaceSearchResultRowID?
    /// Results-list keyboard focus (secondary to AppKit query-field first responder).
    @FocusState private var isResultsFocused: Bool
    /// Memoized pure presentation. Rebuilds only when the exact presenter inputs change
    /// (plain `Equatable`, copy-on-write-cheap while arrays are untouched), so streaming
    /// re-renders skip full section rebuilds and in-place rewrites can never serve stale rows.
    @State private var presentationMemoInputs: WorkspaceSearchResultsPresentationInputs?
    @State private var presentationMemoValue = WorkspaceSearchResultsPresentation.empty

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                queryField
                optionToggles
            }
            .padding(12)

            Divider()

            WorkspaceSearchResultsList(
                presentation: resultsPresentation,
                selectedRowID: resultsSelectionBinding,
                isResultsFocused: $isResultsFocused,
                onEscapeToQueryField: { focusQueryFieldFromResults() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WindowKeyStateReader(tracker: windowKeyState))
        .onAppear {
            refreshResultsPresentationMemo()
            scheduleFocusAttempt()
            publishKeyboardSmokeProbe()
        }
        .onDisappear {
            focusAttemptTask?.cancel()
            focusAttemptTask = nil
        }
        #if DEBUG
        .onReceive(
                NotificationCenter.default.publisher(for: .plainsongWorkspaceSearchKeyboardSmoke)
            ) { note in
                guard note.object as AnyObject === appState as AnyObject else { return }
                guard let command = note.userInfo?["command"] as? WorkspaceSearchKeyboardSmokeCommand
                else {
                    return
                }
                handleKeyboardSmokeCommand(command)
            }
        #endif
            .onChange(of: appState.workspaceSearchUI.focusRequestID) { _, _ in
                // ⌘⇧F always targets the query field, not the results list.
                isResultsFocused = false
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
            .onChange(of: appState.workspaceSearchState.queryGeneration) { _, _ in
                selectedResultRowID = nil
                isResultsFocused = false
                publishKeyboardSmokeProbe()
                refreshResultsPresentationMemo()
            }
            .onChange(of: isResultsFocused) { _, _ in
                publishKeyboardSmokeProbe()
            }
            .onChange(of: selectedResultRowID) { _, _ in
                publishKeyboardSmokeProbe()
            }
            .onChange(of: appState.workspaceSearchState) { _, _ in
                refreshResultsPresentationMemo()
                dropStaleSelectionIfNeeded()
            }
            .onChange(of: appState.workspaceSearchUI.queryText) { _, newValue in
                // clearWorkspaceSearch does not advance queryGeneration; still drop selection.
                if newValue.isEmpty {
                    selectedResultRowID = nil
                    isResultsFocused = false
                }
                refreshResultsPresentationMemo()
            }
            .onChange(of: appState.canUseWorkspaceSearch) { _, _ in
                refreshResultsPresentationMemo()
            }
            .onChange(of: appState.isWorkspaceSearchReady) { _, _ in
                refreshResultsPresentationMemo()
            }
    }

    private var resultsPresentation: WorkspaceSearchResultsPresentation {
        presentationMemoValue
    }

    /// List/button selection also claims the results keyboard surface so click-then-↑/↓
    /// uses the pure reducer (stale-gating) instead of native table navigation alone.
    private var resultsSelectionBinding: Binding<WorkspaceSearchResultRowID?> {
        Binding(
            get: { selectedResultRowID },
            set: { newValue in
                selectedResultRowID = newValue
                if newValue != nil {
                    isResultsFocused = true
                }
                publishKeyboardSmokeProbe()
            }
        )
    }

    private func publishKeyboardSmokeProbe() {
        #if DEBUG
            WorkspaceSearchKeyboardSmokeProbe.publish(
                selection: selectedResultRowID,
                resultsFocused: isResultsFocused
            )
        #endif
    }

    private func refreshResultsPresentationMemo() {
        let inputs = WorkspaceSearchResultsPresentationInputs(
            searchState: appState.workspaceSearchState,
            queryText: appState.workspaceSearchUI.queryText,
            canUseWorkspaceSearch: appState.canUseWorkspaceSearch,
            isWorkspaceSearchReady: appState.isWorkspaceSearchReady
        )
        guard presentationMemoInputs != inputs else { return }
        presentationMemoInputs = inputs
        presentationMemoValue = WorkspaceSearchResultsPresenter.make(inputs)
    }

    private var queryField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            WorkspaceSearchQueryField(
                text: queryTextBinding,
                windowKeyState: windowKeyState,
                isEnabled: appState.canUseWorkspaceSearch,
                onMoveDownToResults: { moveDownFromQueryField() },
                onEscapeToEditor: { escapeFromQueryFieldToEditor() }
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
            .accessibilityIdentifier(WorkspaceSearchAccessibility.matchCase)
            .disabled(!appState.canUseWorkspaceSearch)

            Toggle(isOn: wholeWordBinding) {
                Text("Whole Word")
                    .font(.caption)
            }
            .toggleStyle(.button)
            .help("Match whole words only")
            .accessibilityLabel("Whole Word")
            .accessibilityIdentifier(WorkspaceSearchAccessibility.wholeWord)
            .disabled(!appState.canUseWorkspaceSearch)
        }
    }

    // MARK: - Keyboard surfaces (PR C)

    /// Query-field ↓: select first result and move keyboard focus into the list.
    ///
    /// Focus handoff: (1) clear AppKit field-editor first responder, (2) write selection,
    /// (3) claim results `FocusState`, (4) re-assert focus on the next main turn so SwiftUI
    /// can install key delivery after `makeFirstResponder(nil)` (field editor otherwise keeps
    /// arrows). Owner / hosted smoke verifies this sequence; WS4 XCUITest remains the long-term
    /// automation home.
    private func moveDownFromQueryField() {
        refreshResultsPresentationMemo()
        let ordered = WorkspaceSearchSelectionNavigation.orderedRowIDs(in: resultsPresentation)
        guard !ordered.isEmpty else { return }

        // Drop the field editor before claiming results focus so ↓ is not re-handled by NSText.
        if let window = windowKeyState.window {
            window.makeFirstResponder(nil)
        }

        selectedResultRowID = WorkspaceSearchSelectionNavigation.reduce(
            selection: selectedResultRowID,
            action: .selectFirst,
            orderedIDs: ordered,
            queryGeneration: appState.workspaceSearchState.queryGeneration
        )
        isResultsFocused = true
        publishKeyboardSmokeProbe()

        // Re-assert after the current AppKit turn so FocusState can become key after nil FR.
        Task { @MainActor in
            isResultsFocused = true
            publishKeyboardSmokeProbe()
        }
    }

    /// Query-field Escape: focus editor; keep query text and search results intact.
    private func escapeFromQueryFieldToEditor() {
        isResultsFocused = false
        publishKeyboardSmokeProbe()
        appState.requestEditorFocus()
    }

    /// Results Escape: return focus to the owned Search field without clearing selection state.
    private func focusQueryFieldFromResults() {
        isResultsFocused = false
        publishKeyboardSmokeProbe()
        scheduleFocusAttempt(forceQueryField: true)
    }

    private func dropStaleSelectionIfNeeded() {
        let ordered = WorkspaceSearchSelectionNavigation.orderedRowIDs(in: resultsPresentation)
        let resolved = WorkspaceSearchSelectionNavigation.resolvedSelection(
            selectedResultRowID,
            orderedIDs: ordered,
            queryGeneration: appState.workspaceSearchState.queryGeneration
        )
        if resolved != selectedResultRowID {
            selectedResultRowID = resolved
            publishKeyboardSmokeProbe()
        }
    }

    #if DEBUG
        /// Hosted owner-smoke entry points: same code paths as key handlers, driven from XCTest.
        private func handleKeyboardSmokeCommand(_ command: WorkspaceSearchKeyboardSmokeCommand) {
            switch command {
            case .moveDownFromQueryField:
                moveDownFromQueryField()
            case let .resultsAction(action):
                // Same pure reducer path as `.onKeyPress` ↑/↓ on the results list.
                selectedResultRowID = WorkspaceSearchSelectionNavigation.reduce(
                    selection: selectedResultRowID,
                    action: action,
                    orderedIDs: WorkspaceSearchSelectionNavigation.orderedRowIDs(in: resultsPresentation),
                    queryGeneration: appState.workspaceSearchState.queryGeneration
                )
                if selectedResultRowID != nil {
                    isResultsFocused = true
                }
                publishKeyboardSmokeProbe()
            case .activateSelection:
                guard let selectedResultRowID,
                      let payload = WorkspaceSearchResultsPresenter.activationLookup(
                          rowID: selectedResultRowID,
                          searchState: appState.workspaceSearchState
                      )
                else {
                    return
                }
                appState.activateWorkspaceSearchResult(
                    context: payload.context,
                    fileResult: payload.fileResult,
                    match: payload.match
                )
            case .escapeFromResults:
                focusQueryFieldFromResults()
            case .escapeFromQueryField:
                escapeFromQueryFieldToEditor()
            case let .claimSelection(rowID):
                // Click modality: selection binding claims the results keyboard surface.
                selectedResultRowID = rowID
                isResultsFocused = true
                publishKeyboardSmokeProbe()
            }
        }
    #endif

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
    ///
    /// - Parameter forceQueryField: When true (Escape from results), focus the owned Search field
    ///   even when the global `focusRequestID` was already marked applied (⌘⇧F receipt).
    private func scheduleFocusAttempt(forceQueryField: Bool = false) {
        let tracker = windowKeyState
        let requestID = appState.workspaceSearchUI.focusRequestID
        let appliedID = appState.workspaceSearchUI.focusAppliedID

        if !forceQueryField {
            guard WorkspaceSearchFocusArbitration.shouldApplyFocus(
                requestID: requestID,
                appliedID: appliedID,
                isKeyWindow: isLiveKeyWindow(tracker: tracker)
            ) else {
                return
            }
        } else {
            guard isLiveKeyWindow(tracker: tracker) else { return }
        }

        focusAttemptTask?.cancel()
        let attemptID = requestID
        let force = forceQueryField
        focusAttemptTask = Task { @MainActor in
            // Bounded retries: covers late TextField mount after `.files → .search` without
            // depending solely on a single 16 ms sleep or keyEpoch changes.
            for _ in 0 ..< 40 {
                guard !Task.isCancelled else { return }
                guard isLiveKeyWindow(tracker: tracker) else { return }

                if !force {
                    guard appState.workspaceSearchUI.focusRequestID == attemptID else { return }
                    guard WorkspaceSearchFocusArbitration.shouldApplyFocus(
                        requestID: attemptID,
                        appliedID: appState.workspaceSearchUI.focusAppliedID,
                        isKeyWindow: isLiveKeyWindow(tracker: tracker)
                    ) else {
                        return
                    }
                }

                // Keep resolving the concrete Search field; layout may install it mid-loop.
                tracker.refreshBoundSearchFieldIfNeeded()

                if let window = tracker.window, isLiveKeyWindow(tracker: tracker) {
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
                } else if confirmAndMarkFocusIfNeeded(attemptID: attemptID, tracker: tracker) {
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
