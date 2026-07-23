import AppKit
import EditorKit
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
/// **Keyboard smoke (merge gate for PR C):** the hosted smoke drives **real `NSEvent`s**
/// (`window.sendEvent`) — field ↓ through the field editor's `doCommandBy`, ↑/↓/Return/Escape
/// through the focused List's `onKeyPress`, and a real click on a backing table row — so the
/// gate detects silent native-table fallback. XCUITest in WS4 re-covers the same keys out of
/// process.
struct WorkspaceSearchSidebar: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var windowKeyState = WindowKeyStateTracker()
    /// Cancelable attempt ownership is deliberately non-published: scheduling focus from a
    /// mount/update callback must not mutate SwiftUI view state during that update.
    @StateObject private var focusAttemptController = WorkspaceSearchFocusAttemptController()
    @StateObject private var resultsFocusRestorationController =
        WorkspaceSearchFocusAttemptController()
    /// Selected match row stays view-local (activation uses retained search payload lookup).
    @State private var selectedResultRowID: WorkspaceSearchResultRowID?
    /// Results-list keyboard focus (secondary to AppKit query-field first responder).
    @FocusState private var isResultsFocused: Bool
    /// `FocusState` becomes true before SwiftUI necessarily installs key delivery. Keep the
    /// observable routing claim false until the AppKit editor responder has been displaced.
    @State private var isResultsRoutingReady = false
    /// Monotonic focus intent: every deliberate raise/lower bumps it so the queued
    /// post-handoff re-assert in `moveDownFromQueryField` cannot override a newer intent
    /// (Escape, ⌘⇧F, or generation change landing between queueing and running).
    @State private var resultsFocusIntentToken: UInt64 = 0
    /// View-instance epoch invalidates work that resumes after this sidebar disappears.
    @State private var resultsFocusLifecycleEpoch: UInt64 = 0
    /// Memoized pure presentation. Rebuilds only when the exact presenter inputs change
    /// (plain `Equatable`, copy-on-write-cheap while arrays are untouched), so streaming
    /// re-renders skip full section rebuilds and in-place rewrites can never serve stale rows.
    @State private var presentationMemoInputs: WorkspaceSearchResultsPresentationInputs?
    @State private var presentationMemoValue = WorkspaceSearchResultsPresentation.empty
    #if DEBUG
        @State private var debugFocusSurface = "unknown"
        @State private var debugReducerEvent = "none"
    #endif

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
                onEscapeToQueryField: { focusQueryFieldFromResults() },
                onActivationRequested: { restoreResultsFocusAfterActivation() },
                onKeyboardSelectionHandled: { recordKeyboardSelectionHandled($0) }
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
        .task(id: appState.workspaceSearchUI.focusRequestID) {
            await Task.yield()
            scheduleFocusAttempt()
        }
        .onDisappear {
            resultsFocusLifecycleEpoch &+= 1
            resultsFocusIntentToken &+= 1
            isResultsRoutingReady = false
            focusAttemptController.cancel()
            resultsFocusRestorationController.cancel()
        }
        .onChange(of: appState.workspaceSearchUI.focusRequestID) { _, _ in
            // ⌘⇧F always targets the query field, not the results list.
            lowerResultsFocus()
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
            lowerResultsFocus()
            refreshResultsPresentationMemo()
        }
        .onChange(of: isResultsFocused) { _, _ in
            publishKeyboardSmokeProbe()
            Task { @MainActor in
                refreshDebugFocusSurface()
            }
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
                lowerResultsFocus()
            }
            refreshResultsPresentationMemo()
        }
        .onChange(of: appState.canUseWorkspaceSearch) { _, _ in
            refreshResultsPresentationMemo()
        }
        .onChange(of: appState.isWorkspaceSearchReady) { _, _ in
            refreshResultsPresentationMemo()
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
                ZStack {
                    Text("Workspace search focus \(debugFocusSurface)")
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("plainsong.debug.workspaceSearch.focusSurface")
                        .accessibilityLabel("Workspace search focus \(debugFocusSurface)")
                    Text("Workspace search reducer \(debugReducerEvent)")
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("plainsong.debug.workspaceSearch.reducerEvent")
                        .accessibilityLabel("Workspace search reducer \(debugReducerEvent)")
                }
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .allowsHitTesting(false)
            }
        #endif
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
                    resultsFocusIntentToken &+= 1
                    isResultsRoutingReady = false
                    isResultsFocused = true
                }
                publishKeyboardSmokeProbe()
            }
        )
    }

    /// Deliberately releases the results keyboard surface and invalidates any queued re-assert.
    private func lowerResultsFocus() {
        resultsFocusIntentToken &+= 1
        isResultsRoutingReady = false
        isResultsFocused = false
        publishKeyboardSmokeProbe()
    }

    private func publishKeyboardSmokeProbe() {
        #if DEBUG
            WorkspaceSearchKeyboardSmokeProbe.publish(
                selection: selectedResultRowID,
                resultsFocused: isResultsFocused && isResultsRoutingReady
            )
        #endif
    }

    private func refreshDebugFocusSurface() {
        #if DEBUG
            if isResultsFocused, isResultsRoutingReady {
                debugFocusSurface = "results"
            } else if let window = windowKeyState.window,
                      WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(
                          in: window,
                          expectedField: windowKeyState.resolvedSearchField()
                      )
            {
                debugFocusSurface = "query"
            } else {
                debugFocusSurface = "other"
            }
        #endif
    }

    private func recordKeyboardSelectionHandled(_ action: WorkspaceSearchSelectionAction) {
        #if DEBUG
            switch action {
            case .selectFirst:
                debugReducerEvent = "selectFirst"
            case .selectLast:
                debugReducerEvent = "selectLast"
            case .moveUp:
                debugReducerEvent = "moveUp"
            case .moveDown:
                debugReducerEvent = "moveDown"
            case .clear:
                debugReducerEvent = "clear"
            }
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
        resultsFocusIntentToken &+= 1
        let intentToken = resultsFocusIntentToken
        isResultsRoutingReady = false
        isResultsFocused = true
        publishKeyboardSmokeProbe()

        // Re-assert after the current AppKit turn so FocusState can become key after nil FR.
        // Guarded by the intent token: a newer Escape/⌘⇧F/generation intent wins.
        Task { @MainActor in
            guard resultsFocusIntentToken == intentToken else { return }
            isResultsFocused = true
            await Task.yield()
            guard resultsFocusIntentToken == intentToken else { return }
            isResultsRoutingReady = true
            publishKeyboardSmokeProbe()
            refreshDebugFocusSurface()
        }
    }

    /// Query-field Escape: focus editor; keep query text and search results intact.
    private func escapeFromQueryFieldToEditor() {
        lowerResultsFocus()
        appState.requestEditorFocus()
    }

    /// Results Escape: return focus to the owned Search field without clearing selection state.
    private func focusQueryFieldFromResults() {
        lowerResultsFocus()
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
}

private extension WorkspaceSearchSidebar {
    /// Editor navigation must briefly claim first responder to install and reveal the exact
    /// range. Restore the Search results surface on the next main turn so the activation key or
    /// click does not strand subsequent arrows/Escape in the editor. The intent token prevents a
    /// newer Escape, shortcut, or generation change from being overwritten by this handoff.
    func restoreResultsFocusAfterActivation() {
        resultsFocusIntentToken &+= 1
        let intentToken = resultsFocusIntentToken
        let lifecycleEpoch = resultsFocusLifecycleEpoch
        isResultsRoutingReady = false
        isResultsFocused = false
        publishKeyboardSmokeProbe()
        let tracker = windowKeyState
        resultsFocusRestorationController.replace {
            guard !Task.isCancelled,
                  resultsFocusIntentToken == intentToken,
                  resultsFocusLifecycleEpoch == lifecycleEpoch
            else {
                return
            }
            if tracker.window?.containsMarkdownEditor != true {
                isResultsFocused = true
                await Task.yield()
                guard !Task.isCancelled,
                      resultsFocusIntentToken == intentToken,
                      resultsFocusLifecycleEpoch == lifecycleEpoch
                else {
                    return
                }
                isResultsRoutingReady = true
                publishKeyboardSmokeProbe()
                refreshDebugFocusSurface()
                return
            }

            var observedEditorResponder = false
            for _ in 0 ..< 180 {
                guard !Task.isCancelled,
                      resultsFocusIntentToken == intentToken,
                      resultsFocusLifecycleEpoch == lifecycleEpoch
                else {
                    return
                }
                if tracker.window?.isMarkdownEditorFirstResponder == true {
                    observedEditorResponder = true
                }

                if observedEditorResponder {
                    isResultsFocused = false
                    await Task.yield()
                    guard !Task.isCancelled,
                          resultsFocusIntentToken == intentToken,
                          resultsFocusLifecycleEpoch == lifecycleEpoch
                    else {
                        return
                    }
                    isResultsFocused = true
                    await Task.yield()
                    guard !Task.isCancelled,
                          resultsFocusIntentToken == intentToken,
                          resultsFocusLifecycleEpoch == lifecycleEpoch
                    else {
                        return
                    }
                    if tracker.window?.isMarkdownEditorFirstResponder == false {
                        isResultsRoutingReady = true
                        publishKeyboardSmokeProbe()
                        refreshDebugFocusSurface()
                        return
                    }
                }
                do {
                    try await Task.sleep(nanoseconds: 16_000_000)
                } catch {
                    return
                }
            }

            // Navigation may be rejected before claiming the editor. Restore the result surface
            // after the bounded observation window so activation never strands keyboard input.
            guard !Task.isCancelled,
                  resultsFocusIntentToken == intentToken,
                  resultsFocusLifecycleEpoch == lifecycleEpoch
            else {
                return
            }
            isResultsFocused = true
            await Task.yield()
            guard !Task.isCancelled,
                  resultsFocusIntentToken == intentToken,
                  resultsFocusLifecycleEpoch == lifecycleEpoch
            else {
                return
            }
            isResultsRoutingReady = true
            publishKeyboardSmokeProbe()
            refreshDebugFocusSurface()
        }
    }

    /// Starts or replaces a cancelable, request-scoped focus attempt for this window.
    /// The bounded retry loop lives in `WorkspaceSearchFocusAttemptLoop`.
    ///
    /// - Parameter forceQueryField: When true (Escape from results), focus the owned Search field
    ///   even when the global `focusRequestID` was already marked applied (⌘⇧F receipt).
    private func scheduleFocusAttempt(forceQueryField: Bool = false) {
        let tracker = windowKeyState
        let appState = appState
        let requestID = appState.workspaceSearchUI.focusRequestID
        let appliedID = appState.workspaceSearchUI.focusAppliedID

        if !forceQueryField {
            guard WorkspaceSearchFocusArbitration.shouldApplyFocus(
                requestID: requestID,
                appliedID: appliedID,
                isKeyWindow: true
            ) else {
                return
            }
        }

        let force = forceQueryField
        focusAttemptController.replace {
            await WorkspaceSearchFocusAttemptLoop.run(
                appState: appState,
                tracker: tracker,
                attemptID: requestID,
                force: force
            )
            refreshDebugFocusSurface()
        }
    }
}

private extension NSWindow {
    /// The hosted keyboard smoke mounts only the Search sidebar. In the real app, an editor
    /// text view is already present and navigation must be observed claiming it before results
    /// focus is restored; without an editor surface there is no later responder handoff to wait for.
    var containsMarkdownEditor: Bool {
        func containsEditor(_ root: NSView?) -> Bool {
            guard let root else { return false }
            if root.accessibilityIdentifier() == EditorAccessibility.textViewIdentifier {
                return true
            }
            return root.subviews.contains(where: containsEditor)
        }

        return containsEditor(contentView)
    }

    var isMarkdownEditorFirstResponder: Bool {
        guard var view = firstResponder as? NSView else { return false }
        while true {
            if view.accessibilityIdentifier() == EditorAccessibility.textViewIdentifier {
                return true
            }
            guard let parent = view.superview else { return false }
            view = parent
        }
    }
}

@MainActor
private final class WorkspaceSearchFocusAttemptController: ObservableObject {
    private var task: Task<Void, Never>?

    func replace(operation: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            await operation()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
