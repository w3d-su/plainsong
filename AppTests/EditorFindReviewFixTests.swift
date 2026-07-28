import AppKit
import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// PR #97 review fixes: workspace-search fencing, close-bar fencing, and the provenance
/// rules for a selection the editor has actually applied.
///
/// Focus receipts and find-bar chrome eligibility live in `EditorFindFocusReceiptTests`.
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

    // MARK: - Escape routes

    func testEscapeFromTheEditorClosesTheBarAndReportsItConsumedTheKey() {
        let appState = makeAppState()
        openFindBar(appState, query: "alpha")
        XCTAssertTrue(appState.editorFindHost.ui.isBarVisible)

        // `MarkdownSTTextView.cancelOperation` reaches this through
        // `EditorFindActionHooks.cancelFind` once it has ruled out marked text and an open
        // completion list.
        XCTAssertTrue(
            appState.closeEditorFindBarFromEditorEscape(),
            "Escape in the editor must close the find bar"
        )
        XCTAssertFalse(appState.editorFindHost.ui.isBarVisible)

        // No bar left: the editor must keep its own Escape behaviour (STTextView opens the
        // completion list), so the hook has to decline rather than swallow the key.
        XCTAssertFalse(
            appState.closeEditorFindBarFromEditorEscape(),
            "With no bar open, Escape must fall through to the editor"
        )
    }

    func testEscapeFromBarChromeClosesTheBar() {
        let appState = makeAppState()
        openFindBar(appState, query: "alpha")
        appState.setEditorFindChromeFocus(.matchCase, inWindowNumber: 5)

        // SwiftUI `onExitCommand` from a focused bar control. No query field is mounted in
        // this headless state, so the composition guard reports not-composing.
        appState.closeEditorFindBarFromExitCommand()
        XCTAssertFalse(
            appState.editorFindHost.ui.isBarVisible,
            "Escape on Aa / whole-word / Next / Previous / Done must close the bar"
        )
        XCTAssertTrue(appState.editorFindHost.chromeFocusByWindow.isEmpty)

        // Idempotent when there is nothing to close.
        appState.closeEditorFindBarFromExitCommand()
        XCTAssertFalse(appState.editorFindHost.ui.isBarVisible)
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

    func testClosingTheBarKeepsTheOrdinalSoTheNextStepAdvances() async throws {
        let text = "a hit b hit c hit d"
        let appState = makeAppState(text: text)
        let hits = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "hit"),
            limit: EditorFindLimits.engineMatchLimit
        ).map(\.range)
        XCTAssertEqual(hits.count, 3)

        openFindBar(appState, query: "hit")
        try await waitUntil("session ready") {
            appState.editorFindHost.controller.session?.total == 3
        }
        // Walk to hit 2 the way a user would.
        appState.editorFindNext()
        XCTAssertEqual(appState.editorFindHost.controller.session?.currentOrdinal, 2)

        appState.closeEditorFindBar()
        XCTAssertFalse(appState.editorFindHost.ui.isBarVisible)
        XCTAssertEqual(
            appState.editorFindHost.controller.session?.currentOrdinal,
            2,
            "Closing the bar must not reset a resolved ordinal"
        )
        XCTAssertNotNil(appState.editorFindHost.controller.query)

        appState.editorFindNext()
        guard case let .navigate(nav)? =
            appState.editorFindHost.controller.pendingNavigationCommand
        else {
            return XCTFail("⌘G with the bar closed still steps the retained query")
        }
        XCTAssertEqual(
            nav.selection,
            hits[2],
            "⌘G after Escape must advance to hit 3, not restart at hit 1"
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

    // MARK: - Applied-selection provenance

    func testAppliedSelectionIsRejectedWithoutMatchingDocumentAndRevisionProvenance() {
        let identity = EditorDocumentIdentity(rawValue: "file:///tmp/current.md")
        let other = EditorDocumentIdentity(rawValue: "file:///tmp/other.md")
        let range = NSRange(location: 2, length: 3)
        let length = 20
        let revision = 7

        func applied(
            identity: EditorDocumentIdentity?,
            revision: Int?,
            installed: Bool = true,
            range: NSRange = range
        ) -> EditorAppliedSelection {
            EditorAppliedSelection(
                documentIdentity: identity,
                sourceRevision: revision,
                isDocumentInstalled: installed,
                range: range
            )
        }

        XCTAssertTrue(
            EditorFindAppliedSelectionPolicy.accepts(
                applied(identity: identity, revision: revision),
                identity: identity,
                revision: revision,
                textUTF16Length: length
            )
        )
        // Document switch: the native view still holds the previous source.
        XCTAssertFalse(
            EditorFindAppliedSelectionPolicy.accepts(
                applied(identity: other, revision: revision),
                identity: identity,
                revision: revision,
                textUTF16Length: length
            ),
            "A range from another document must never be indexed into the current text"
        )
        // Same-URL Reload: identity matches but the content behind it changed.
        XCTAssertFalse(
            EditorFindAppliedSelectionPolicy.accepts(
                applied(identity: identity, revision: revision - 1),
                identity: identity,
                revision: revision,
                textUTF16Length: length
            ),
            "A range from a superseded revision must be rejected, not reinterpreted"
        )
        // Transition not finished installing.
        XCTAssertFalse(
            EditorFindAppliedSelectionPolicy.accepts(
                applied(identity: identity, revision: revision, installed: false),
                identity: identity,
                revision: revision,
                textUTF16Length: length
            )
        )
        // No provenance at all.
        XCTAssertFalse(
            EditorFindAppliedSelectionPolicy.accepts(
                applied(identity: nil, revision: nil),
                identity: identity,
                revision: revision,
                textUTF16Length: length
            )
        )
        // Out of bounds for the current text.
        XCTAssertFalse(
            EditorFindAppliedSelectionPolicy.accepts(
                applied(
                    identity: identity,
                    revision: revision,
                    range: NSRange(location: 18, length: 5)
                ),
                identity: identity,
                revision: revision,
                textUTF16Length: length
            )
        )
        // Malformed range cannot overflow the bounds arithmetic.
        XCTAssertFalse(
            EditorFindAppliedSelectionPolicy.accepts(
                applied(
                    identity: identity,
                    revision: revision,
                    range: NSRange(location: NSNotFound, length: 0)
                ),
                identity: identity,
                revision: revision,
                textUTF16Length: length
            )
        )
    }
}
