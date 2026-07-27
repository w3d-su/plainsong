import AppKit
import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// PR #97 review fixes: shared focus receipt across the `WindowGroup`, find-bar chrome
/// eligibility, workspace-search fencing, close-bar fencing, and applied-selection reads.
@MainActor
final class EditorFindReviewFixTests: XCTestCase {
    private func makeAppState(text: String = "alpha beta alpha gamma") -> AppState {
        let url = URL(fileURLWithPath: "/tmp/plainsong-find-review-\(UUID().uuidString).md")
        let session = DocumentSession(text: text, url: url, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.editorFindHost.controller.debounceNanoseconds = 0
        appState.editorFindHost.commandContextOverride = true
        return appState
    }

    private func openFindBar(_ appState: AppState, query: String) {
        var ui = appState.editorFindHost.ui
        ui.isBarVisible = true
        ui.queryText = query
        ui.requestFocusAndSelectAll()
        appState.setEditorFindUI(ui)
        appState.ensureEditorFindSessionObserverInstalled()
        appState.syncEditorFindControllerDocument()
        if !query.isEmpty {
            appState.pushEditorFindQueryToController()
        }
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        predicate: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    // MARK: - Shared focus receipt (multi-window replay)

    func testFocusReceiptIsSharedSoASecondWindowCannotReplayASpentRequest() {
        let appState = makeAppState()
        openFindBar(appState, query: "alpha")
        let requestID = appState.editorFindHost.ui.focusRequestID
        XCTAssertGreaterThan(requestID, 0)

        // Window A's key-window field consumed the token.
        appState.markEditorFindFocusApplied(requestID)
        XCTAssertEqual(appState.editorFindHost.ui.focusAppliedID, requestID)

        // Window B (fresh coordinator, its own local receipt) re-reads shared state.
        XCTAssertFalse(
            EditorFindFocusArbitration.shouldApplyFocus(
                requestID: requestID,
                appliedID: appState.editorFindHost.ui.focusAppliedID,
                supersededID: appState.editorFindHost.ui.focusSupersededID,
                isKeyWindow: true
            ),
            "A spent request must not be applicable in another window"
        )
        XCTAssertFalse(
            EditorFindFocusArbitration.shouldKeepRetrying(
                requestID: requestID,
                snapshot: appState.editorFindHost.ui.focusSnapshot
            ),
            "A remounted bar must not keep retrying a consumed request"
        )
    }

    func testNewerFocusRequestIsApplicableAgainAfterAnEarlierOneWasConsumed() {
        let appState = makeAppState()
        openFindBar(appState, query: "alpha")
        let first = appState.editorFindHost.ui.focusRequestID
        appState.markEditorFindFocusApplied(first)

        appState.showOrRefocusEditorFind()
        let second = appState.editorFindHost.ui.focusRequestID
        XCTAssertGreaterThan(second, first)
        XCTAssertTrue(
            EditorFindFocusArbitration.shouldApplyFocus(
                requestID: second,
                appliedID: appState.editorFindHost.ui.focusAppliedID,
                supersededID: appState.editorFindHost.ui.focusSupersededID,
                isKeyWindow: true
            )
        )
    }

    func testBackgroundWindowAndSupersededRequestsNeverAdvanceTheReceipt() {
        let appState = makeAppState()
        openFindBar(appState, query: "alpha")
        let requestID = appState.editorFindHost.ui.focusRequestID

        XCTAssertFalse(
            EditorFindFocusArbitration.shouldApplyFocus(
                requestID: requestID,
                appliedID: 0,
                supersededID: 0,
                isKeyWindow: false
            ),
            "Only the key window may apply"
        )

        // ⇧⌘F / Escape abandons the request without advancing focusRequestID (F7).
        appState.supersedePendingEditorFindFocus()
        XCTAssertEqual(appState.editorFindHost.ui.focusRequestID, requestID)
        appState.markEditorFindFocusApplied(requestID)
        XCTAssertEqual(
            appState.editorFindHost.ui.focusAppliedID,
            0,
            "A superseded request must not be recorded as applied"
        )
        XCTAssertFalse(
            EditorFindFocusArbitration.shouldKeepRetrying(
                requestID: requestID,
                snapshot: appState.editorFindHost.ui.focusSnapshot
            )
        )
    }

    func testRetryContinuesWhileTheBarIsVisibleAndTheRequestIsUnresolved() {
        let appState = makeAppState()
        openFindBar(appState, query: "alpha")
        let requestID = appState.editorFindHost.ui.focusRequestID
        // The field may not be mounted in a key window yet on the first ⌘F: the loop must
        // stay armed rather than give up after one async turn.
        XCTAssertTrue(
            EditorFindFocusArbitration.shouldKeepRetrying(
                requestID: requestID,
                snapshot: appState.editorFindHost.ui.focusSnapshot
            )
        )

        appState.closeEditorFindBar()
        XCTAssertFalse(
            EditorFindFocusArbitration.shouldKeepRetrying(
                requestID: requestID,
                snapshot: appState.editorFindHost.ui.focusSnapshot
            ),
            "Closing the bar ends the retry"
        )
    }

    // MARK: - Find bar chrome eligibility

    func testFindBarControlsActEvenWhenTheResponderGuardWouldRejectTheContext() async throws {
        let appState = makeAppState(text: "one two one two one")
        openFindBar(appState, query: "one")
        try await waitUntil("session ready") {
            appState.editorFindHost.controller.session?.total == 3
        }
        XCTAssertEqual(appState.editorFindHost.controller.session?.currentOrdinal, 1)

        // Full Keyboard Access moved focus to a bar control the responder check cannot name.
        appState.editorFindHost.commandContextOverride = false
        appState.editorFindNext()
        XCTAssertEqual(
            appState.editorFindHost.controller.session?.currentOrdinal,
            1,
            "Menu ⌘G still respects the context guard"
        )

        appState.stepEditorFindFromBarControl(.next)
        XCTAssertEqual(
            appState.editorFindHost.controller.session?.currentOrdinal,
            2,
            "The bar's own Next button must never no-op"
        )
        appState.stepEditorFindFromBarControl(.previous)
        XCTAssertEqual(appState.editorFindHost.controller.session?.currentOrdinal, 1)
    }

    func testResponderEligibilityAcceptsFindBarChromeButNotUnrelatedFocus() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root

        // Find bar host: query field plus a sibling control (Aa / Next / Previous stand-in).
        let barHost = NSView(frame: NSRect(x: 0, y: 360, width: 600, height: 40))
        let queryField = NSTextField(string: "")
        queryField.setAccessibilityIdentifier(EditorFindAccessibility.queryField)
        queryField.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        let barButton = NSButton(title: "Aa", target: nil, action: nil)
        barButton.frame = NSRect(x: 210, y: 0, width: 40, height: 24)
        barHost.addSubview(queryField)
        barHost.addSubview(barButton)

        // Editor pane, sibling of the bar host.
        let editorHost = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 360))
        let editor = NSTextView(frame: editorHost.bounds)
        editor.setAccessibilityIdentifier(EditorAccessibility.textViewIdentifier)
        editorHost.addSubview(editor)

        // Unrelated chrome (sidebar), also a sibling.
        let sidebarButton = NSButton(title: "Files", target: nil, action: nil)
        sidebarButton.frame = NSRect(x: 500, y: 100, width: 80, height: 24)

        root.addSubview(barHost)
        root.addSubview(editorHost)
        root.addSubview(sidebarButton)
        window.makeKeyAndOrderFront(nil)

        guard window.makeFirstResponder(barButton) else {
            throw XCTSkip("makeFirstResponder(barButton) unavailable in this runner")
        }
        XCTAssertTrue(
            EditorFindResponderSupport.windowHasEditorOrFindChrome(window),
            "A control inside the find bar must keep ⌘F / ⌘G / ⌘E live"
        )

        guard window.makeFirstResponder(sidebarButton) else {
            throw XCTSkip("makeFirstResponder(sidebarButton) unavailable in this runner")
        }
        XCTAssertFalse(
            EditorFindResponderSupport.windowHasEditorOrFindChrome(window),
            "Focus outside the bar and editor stays ineligible"
        )

        guard window.makeFirstResponder(queryField) else {
            throw XCTSkip("makeFirstResponder(queryField) unavailable in this runner")
        }
        XCTAssertTrue(EditorFindResponderSupport.windowHasEditorOrFindChrome(window))
    }

    // MARK: - Workspace search fencing

    func testWorkspaceSearchHandOffStopsAnInFlightFindFromNavigatingAfterwards() async throws {
        let text = "target one target two target three"
        let appState = makeAppState(text: text)
        // Leave the find query genuinely in flight: without the fence its `.query`
        // generation would complete *after* the activation and draw a higher navigation ID.
        appState.editorFindHost.controller.debounceNanoseconds = 80_000_000
        openFindBar(appState, query: "target")
        XCTAssertNil(appState.editorFindHost.controller.session, "query must still be debouncing")

        let searchRange = (text as NSString).range(of: "three")
        let documentIdentity = try XCTUnwrap(appState.activeEditorDocumentIdentity)
        appState.notifyEditorFindWorkspaceSearchWillNavigate(to: searchRange)
        appState.issueEditorNavigation(
            documentIdentity: documentIdentity,
            selection: searchRange
        )
        guard case let .navigate(searchNavigation)? = appState.editorNavigationCommand else {
            return XCTFail("expected workspace-search navigation")
        }
        XCTAssertEqual(searchNavigation.selection, searchRange)

        // Let the fenced counter-only recompute finish; it must not publish navigation.
        try await waitUntil("counter recompute lands", timeout: 3) {
            appState.editorFindHost.controller.session?.total == 3
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(
            appState.editorFindHost.controller.pendingNavigationCommand,
            "Fenced find generation must not produce navigation"
        )
        guard case let .navigate(current)? = appState.editorNavigationCommand else {
            return XCTFail("workspace-search navigation must remain the live command")
        }
        XCTAssertEqual(
            current.id,
            searchNavigation.id,
            "No later find navigation may supersede the search result"
        )
        XCTAssertEqual(current.selection, searchRange)
    }

    func testWorkspaceSearchHandOffKeepsTheQueryAndReAnchorsTheNextStep() async throws {
        let text = "hit a hit b hit c"
        let appState = makeAppState(text: text)
        openFindBar(appState, query: "hit")
        try await waitUntil("session ready") {
            appState.editorFindHost.controller.session?.total == 3
        }

        let hits = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "hit"),
            limit: EditorFindLimits.engineMatchLimit
        ).map(\.range)
        appState.notifyEditorFindWorkspaceSearchWillNavigate(to: hits[1])
        try await waitUntil("counter recompute lands at the new anchor") {
            appState.editorFindHost.controller.session?.currentOrdinal == 2
        }
        XCTAssertEqual(appState.editorFindHost.ui.queryText, "hit")

        // First ⌘G after the hand-off activates the match at the search caret, not past it.
        appState.editorFindNext()
        guard case let .navigate(step)? = appState.editorFindHost.controller.pendingNavigationCommand
        else {
            return XCTFail("expected ⌘G navigation after hand-off")
        }
        XCTAssertEqual(step.selection, hits[1])
    }

    // MARK: - Close-bar fencing

    func testClosingTheBarFencesAQueryStillInsideTheDebounceWindow() async throws {
        let appState = makeAppState(text: "escape me escape me")
        appState.editorFindHost.controller.debounceNanoseconds = 40_000_000
        openFindBar(appState, query: "escape")
        XCTAssertNil(appState.editorFindHost.controller.session, "still debouncing")

        appState.closeEditorFindBar()
        XCTAssertFalse(appState.editorFindHost.ui.isBarVisible)

        // Give the debounced generation more than enough time to have landed.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(
            appState.editorFindHost.controller.pendingNavigationCommand,
            "A query fenced by Escape must not move the editor selection afterwards"
        )
        if case .navigate = appState.editorNavigationCommand {
            XCTFail("Closed find bar must not leave a navigate command on the shared channel")
        }
    }

    func testClosingTheBarKeepsTheQueryUsableForALaterStep() async throws {
        let text = "keep me keep me"
        let appState = makeAppState(text: text)
        openFindBar(appState, query: "keep")
        try await waitUntil("session ready") {
            appState.editorFindHost.controller.session?.total == 2
        }
        appState.closeEditorFindBar()
        try await waitUntil("counter-only recompute lands after close") {
            appState.editorFindHost.controller.session?.total == 2
        }
        XCTAssertNotNil(appState.editorFindHost.controller.query)

        appState.editorFindNext()
        XCTAssertNotNil(
            appState.editorFindHost.controller.pendingNavigationCommand,
            "⌘G with the bar closed still steps the retained query"
        )
    }

    // MARK: - Selection cache reflects applied state

    func testPublishedFindNavigationDoesNotSeedTheSelectionCache() async throws {
        let text = "cached one cached two"
        let appState = makeAppState(text: text)
        openFindBar(appState, query: "cached")
        try await waitUntil("session ready") {
            appState.editorFindHost.controller.session?.total == 2
        }
        try await waitUntil("App publishes navigation") {
            appState.editorNavigationCommand != nil
        }
        // No editor view exists in this headless state, so nothing applied the request.
        XCTAssertNil(
            appState.editorFindHost.latestKnownEditorSelection,
            "Publishing is not applying: ⌘E must not adopt an unapplied range"
        )
    }
}
