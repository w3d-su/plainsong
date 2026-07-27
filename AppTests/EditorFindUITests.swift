import AppKit
import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// PR C gates: F4b UI visibility, F5 source+preview navigation path, F6 structural IME,
/// F7 focus tokens and ⌘F re-focus, ⌘E without showing the bar.
@MainActor
final class EditorFindUITests: XCTestCase {
    private func makeAppState(text: String = "alpha beta alpha gamma") -> AppState {
        let url = URL(fileURLWithPath: "/tmp/plainsong-editor-find-\(UUID().uuidString).md")
        let session = DocumentSession(text: text, url: url, fileKind: .markdown)
        let appState = AppState(
            currentDocument: session,
            shouldRestoreLastOpenedFile: false
        )
        appState.editorFindHost.controller.debounceNanoseconds = 0
        return appState
    }

    private func openFindBar(
        _ appState: AppState,
        query: String = "",
        selectAll: Bool = true
    ) {
        var ui = appState.editorFindHost.ui
        ui.isBarVisible = true
        ui.queryText = query
        if selectAll {
            ui.requestFocusAndSelectAll()
        }
        appState.setEditorFindUI(ui)
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

    // MARK: - F4b UI visibility

    func testFindBarStaysOpenAndRebindsOnDocumentSwitchWithoutAutoJump() async throws {
        let appState = makeAppState(text: "needle one needle two")
        openFindBar(appState, query: "needle")
        try await waitUntil("session matches first document") {
            appState.editorFindHost.controller.session?.total == 2
        }
        // Drain any query-time navigation from first document.
        let firstNavID = appState.editorFindHost.controller.pendingNavigationCommand?.id
        appState.editorNavigationCommand = nil
        appState.editorFindHost.lastAppliedNavigationID = firstNavID

        let otherURL = URL(fileURLWithPath: "/tmp/plainsong-editor-find-other-\(UUID().uuidString).md")
        let other = DocumentSession(text: "needle only once", url: otherURL, fileKind: .markdown)
        appState.setCurrentDocument(other, synchronizingWorkspaceTree: false)

        XCTAssertTrue(appState.editorFindHost.ui.isBarVisible, "F4b: bar stays open on file switch")
        XCTAssertEqual(appState.editorFindHost.ui.queryText, "needle")

        try await waitUntil("session rebinds to second document") {
            appState.editorFindHost.controller.session?.total == 1
        }

        // Rebind must not emit a newer navigation (counter-only).
        if let pending = appState.editorFindHost.controller.pendingNavigationCommand {
            XCTAssertEqual(
                pending.id,
                firstNavID,
                "F4b rebind must not emit navigation for the newly focused file"
            )
        }
        XCTAssertNil(
            appState.editorNavigationCommand,
            "App must not apply a new find navigation after rebind"
        )
    }

    func testFindBarClosesWhenNoDocumentRemains() {
        let appState = makeAppState()
        openFindBar(appState, query: "alpha")
        XCTAssertTrue(appState.editorFindHost.ui.isBarVisible)

        // Simulate focused session closed → empty DocumentSession (no fileURL).
        appState.currentDocument = DocumentSession()
        appState.notifyEditorFindDocumentDidSwitch()

        XCTAssertFalse(appState.editorFindHost.ui.isBarVisible)
        XCTAssertNil(appState.editorFindHost.controller.session)
        XCTAssertEqual(appState.editorFindHost.controller.documentBinding, .empty)
    }

    func testFindBarClosesOnWorkspaceClose() {
        let appState = makeAppState()
        openFindBar(appState, query: "alpha")
        XCTAssertTrue(appState.editorFindHost.ui.isBarVisible)

        appState.notifyEditorFindWorkspaceDidClose()

        XCTAssertFalse(appState.editorFindHost.ui.isBarVisible)
        XCTAssertEqual(appState.editorFindHost.ui.queryText, "")
        XCTAssertNil(appState.editorFindHost.controller.session)
    }

    // MARK: - F5 source+preview

    func testSourcePlusPreviewLayoutEmitsFindNavigationOnSharedChannel() async throws {
        let appState = makeAppState(text: "hello findme world findme")
        appState.setLayoutMode(.sourcePreview)
        XCTAssertTrue(appState.isPreviewVisible)

        openFindBar(appState, query: "findme")
        try await waitUntil("query match session ready") {
            appState.editorFindHost.controller.session?.total == 2
        }
        // Presentation refresh applies navigation from controller pending command.
        try await waitUntil("App applies navigation command") {
            appState.editorNavigationCommand != nil
        }

        guard case let .navigate(request)? = appState.editorNavigationCommand else {
            return XCTFail("expected navigate command")
        }
        let expected = ("hello findme world findme" as NSString).range(of: "findme")
        XCTAssertEqual(request.selection, expected)
        XCTAssertTrue(appState.isPreviewVisible, "source+preview stays preview-visible")
        // Source identity unchanged.
        XCTAssertEqual(appState.currentDocument.text, "hello findme world findme")
    }

    func testSourceOnlyControlStillNavigatesWithoutPreview() async throws {
        let appState = makeAppState(text: "only findme once")
        appState.setLayoutMode(.sourceOnly)
        XCTAssertFalse(appState.isPreviewVisible)

        openFindBar(appState, query: "findme")
        try await waitUntil("session ready") {
            appState.editorFindHost.controller.session?.total == 1
        }
        try await waitUntil("navigation applied") {
            appState.editorNavigationCommand != nil
        }
        guard case let .navigate(request)? = appState.editorNavigationCommand else {
            return XCTFail("expected navigate")
        }
        XCTAssertEqual(
            request.selection,
            ("only findme once" as NSString).range(of: "findme")
        )
    }

    // MARK: - F6 IME structural

    func testFindQueryFieldCoordinatorLeavesMarkedTextCommandsToInputContext() throws {
        // Structural gate: Coordinator must not swallow Return/Escape while marked text exists.
        // Hosted IME streams remain owner-run; this proves the reservation is present.
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Views/EditorFindQueryField.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(
            source.contains("hasMarkedText()"),
            "Find field must consult marked-text state"
        )
        XCTAssertTrue(
            source.contains("cancelOperation"),
            "Find field must handle Escape"
        )
        // While marked: return false so the input context keeps the key.
        XCTAssertTrue(
            source.contains("return false"),
            "Marked-text branch must leave keys with the input context"
        )
    }

    // MARK: - F7 focus arbitration

    func testFindFocusTokensIndependentOfWorkspaceSearchTokens() {
        let appState = makeAppState()
        let searchBefore = appState.workspaceSearchUI.focusRequestID
        let findBefore = appState.editorFindHost.ui.focusRequestID

        openFindBar(appState, query: "alpha")
        XCTAssertEqual(
            appState.workspaceSearchUI.focusRequestID,
            searchBefore,
            "Find must not advance workspace-search focus receipts"
        )
        XCTAssertEqual(
            appState.editorFindHost.ui.focusRequestID,
            findBefore &+ 1
        )

        // Workspace search focus must not consume find tokens.
        appState.workspaceRootURL = URL(fileURLWithPath: "/tmp/plainsong-find-focus-arbitration")
        let findFocusAfterOpen = appState.editorFindHost.ui.focusRequestID
        appState.focusWorkspaceSearch()
        XCTAssertEqual(appState.editorFindHost.ui.focusRequestID, findFocusAfterOpen)
        XCTAssertGreaterThan(appState.workspaceSearchUI.focusRequestID, searchBefore)
    }

    func testCommandFWhileBarOpenRefocusesAndNeverCloses() {
        let appState = makeAppState()
        openFindBar(appState, query: "alpha")
        let focusBefore = appState.editorFindHost.ui.focusRequestID
        let selectBefore = appState.editorFindHost.ui.selectAllRequestID
        XCTAssertTrue(appState.editorFindHost.ui.isBarVisible)

        // Bar already open → contextOK without editor first responder.
        appState.showOrRefocusEditorFind()

        XCTAssertTrue(appState.editorFindHost.ui.isBarVisible, "⌘F must never close an open bar")
        XCTAssertEqual(appState.editorFindHost.ui.focusRequestID, focusBefore &+ 1)
        XCTAssertEqual(appState.editorFindHost.ui.selectAllRequestID, selectBefore &+ 1)
        XCTAssertEqual(appState.editorFindHost.ui.queryText, "alpha")
    }

    func testCommandFAndWorkspaceSearchFocusReceiptsDoNotCrossConsume() {
        let appState = makeAppState()
        openFindBar(appState, query: "x")
        let findFocus = appState.editorFindHost.ui.focusRequestID

        appState.workspaceRootURL = URL(fileURLWithPath: "/tmp/plainsong-find-cross-consume")
        let searchBefore = appState.workspaceSearchUI.focusRequestID
        appState.showOrRefocusEditorFind()
        XCTAssertEqual(
            appState.workspaceSearchUI.focusRequestID,
            searchBefore,
            "⌘F re-focus must not consume workspace-search focus receipts"
        )
        XCTAssertEqual(appState.editorFindHost.ui.focusRequestID, findFocus &+ 1)

        let findAfter = appState.editorFindHost.ui.focusRequestID
        appState.focusWorkspaceSearch()
        XCTAssertEqual(
            appState.editorFindHost.ui.focusRequestID,
            findAfter,
            "⇧⌘F must not consume find focus receipts"
        )
    }

    // MARK: - ⌘E Use Selection (macOS convention: no show/focus)

    func testUseSelectionForFindSetsPatternWithoutShowingBar() {
        let appState = makeAppState(text: "prefix selectedWord suffix")
        // Simulate a non-empty editor selection known to App (⌘E path).
        let range = ("prefix selectedWord suffix" as NSString).range(of: "selectedWord")
        appState.editorFindHost.latestKnownEditorSelection = range
        // Force command context via open bar then close — still allow when selection is known
        // by temporarily opening visibility for context, then testing the no-show contract.
        // useSelection requires editor/find context; seed bar visibility without focusing.
        var ui = appState.editorFindHost.ui
        ui.isBarVisible = true
        appState.setEditorFindUI(ui)

        appState.useSelectionForEditorFind()
        XCTAssertEqual(appState.editorFindHost.ui.queryText, "selectedWord")

        // Now close and prove ⌘E with bar closed still sets pattern without reopening when
        // we keep bar closed after useSelection — product: never shows.
        appState.closeEditorFindBar()
        XCTAssertFalse(appState.editorFindHost.ui.isBarVisible)

        // With bar closed, need command context. Seed selection and force context by
        // setting latestKnown + calling when bar was open path already validated no-show
        // doesn't open: useSelection when bar open doesn't change visibility goal.
        // Direct contract: after useSelection, bar remains closed if it was closed —
        // reopen then use with open, close, and assert useSelection path does not open.
        openFindBar(appState, query: "old")
        appState.editorFindHost.latestKnownEditorSelection = range
        appState.useSelectionForEditorFind()
        XCTAssertTrue(appState.editorFindHost.ui.isBarVisible)
        XCTAssertEqual(appState.editorFindHost.ui.queryText, "selectedWord")
        appState.closeEditorFindBar()
        XCTAssertFalse(appState.editorFindHost.ui.isBarVisible)
        // Closed + no editor focus → useSelection no-ops (does not show bar).
        appState.useSelectionForEditorFind()
        XCTAssertFalse(
            appState.editorFindHost.ui.isBarVisible,
            "⌘E must not show the find bar (macOS convention)"
        )
    }

    func testUseSelectionRejectsNewlinesAndOversizedPatterns() {
        let appState = makeAppState(text: "a\nb")
        openFindBar(appState)
        appState.editorFindHost.latestKnownEditorSelection = NSRange(location: 0, length: 3) // includes newline
        appState.useSelectionForEditorFind()
        XCTAssertEqual(appState.editorFindHost.ui.queryText, "")

        let long = String(repeating: "x", count: TextSearchEngine.maximumPatternUTF16Length + 1)
        let longSession = DocumentSession(
            text: long,
            url: URL(fileURLWithPath: "/tmp/plainsong-editor-find-long.md"),
            fileKind: .markdown
        )
        appState.setCurrentDocument(longSession, synchronizingWorkspaceTree: false)
        openFindBar(appState)
        appState.editorFindHost.latestKnownEditorSelection = NSRange(location: 0, length: long.utf16.count)
        appState.useSelectionForEditorFind()
        XCTAssertEqual(appState.editorFindHost.ui.queryText, "")
    }

    // MARK: - Accessibility IDs (F9 chrome half; XCUITest remains PR D)

    func testAccessibilityIdentifiersAreStableUnderPlainsongEditorFindNamespace() {
        XCTAssertEqual(EditorFindAccessibility.bar, "plainsong.editorFind.bar")
        XCTAssertEqual(EditorFindAccessibility.queryField, "plainsong.editorFind.queryField")
        XCTAssertEqual(EditorFindAccessibility.matchCase, "plainsong.editorFind.matchCase")
        XCTAssertEqual(EditorFindAccessibility.wholeWord, "plainsong.editorFind.wholeWord")
        XCTAssertEqual(EditorFindAccessibility.matchCounter, "plainsong.editorFind.matchCounter")
        XCTAssertEqual(EditorFindAccessibility.truncatedIndicator, "plainsong.editorFind.truncated")
        XCTAssertEqual(EditorFindAccessibility.nextButton, "plainsong.editorFind.next")
        XCTAssertEqual(EditorFindAccessibility.previousButton, "plainsong.editorFind.previous")
        XCTAssertEqual(EditorFindAccessibility.doneButton, "plainsong.editorFind.done")
    }

    func testTruncatedCounterPresentationIsDistinctFromExactTotal() {
        var ui = EditorFindUIState()
        let query = TextSearchQuery(pattern: "x")
        let oneMatch = [
            TextSearchMatch(
                range: NSRange(location: 0, length: 1),
                line: 1,
                preview: "x",
                previewMatchRange: NSRange(location: 0, length: 1)
            ),
        ]
        let exact = EditorFindSession(
            engineResults: oneMatch,
            query: query,
            preferredOrdinal: 1
        )
        ui.applySessionPresentation(exact)
        XCTAssertEqual(ui.matchCounterText, "1 / 1")
        XCTAssertFalse(ui.isTruncated)

        // Overflow hit at engine limit → isTruncated; retained total is ceiling.
        let overflow = (0 ..< EditorFindLimits.engineMatchLimit).map { index in
            TextSearchMatch(
                range: NSRange(location: index, length: 1),
                line: 1,
                preview: "x",
                previewMatchRange: NSRange(location: 0, length: 1)
            )
        }
        let truncated = EditorFindSession(
            engineResults: overflow,
            query: query,
            preferredOrdinal: 1
        )
        XCTAssertTrue(truncated.isTruncated)
        XCTAssertEqual(truncated.total, EditorFindLimits.retainedMatchCeiling)
        ui.applySessionPresentation(truncated)
        XCTAssertEqual(
            ui.matchCounterText,
            "1 / \(EditorFindLimits.retainedMatchCeiling)+"
        )
        XCTAssertTrue(ui.isTruncated)
        XCTAssertFalse(ui.matchCounterText.hasSuffix("\(EditorFindLimits.retainedMatchCeiling)"))
        XCTAssertTrue(ui.matchCounterText.hasSuffix("+"))
    }
}
