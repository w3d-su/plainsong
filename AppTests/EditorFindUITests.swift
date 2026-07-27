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
        // Deterministic eligibility without flaky key-window first-responder setup.
        appState.editorFindHost.commandContextOverride = true
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

    // MARK: - F4b UI visibility

    func testFindBarStaysOpenAndRebindsOnDocumentSwitchWithoutAutoJump() async throws {
        let appState = makeAppState(text: "needle one needle two")
        openFindBar(appState, query: "needle")
        try await waitUntil("session matches first document") {
            appState.editorFindHost.controller.session?.total == 2
        }
        // Drain any query-time navigation from first document.
        appState.editorNavigationCommand = nil

        let otherURL = URL(fileURLWithPath: "/tmp/plainsong-editor-find-other-\(UUID().uuidString).md")
        let other = DocumentSession(text: "needle only once", url: otherURL, fileKind: .markdown)
        appState.setCurrentDocument(other, synchronizingWorkspaceTree: false)

        XCTAssertTrue(appState.editorFindHost.ui.isBarVisible, "F4b: bar stays open on file switch")
        XCTAssertEqual(appState.editorFindHost.ui.queryText, "needle")

        try await waitUntil("session rebinds to second document") {
            appState.editorFindHost.controller.session?.total == 1
        }

        // Rebind re-runs for the counter only — no auto-jump.
        XCTAssertNil(
            appState.editorFindHost.controller.pendingNavigationCommand,
            "F4b rebind must not auto-jump; user moves with ⌘G"
        )
        // Shared channel may carry a superseding cancel (so an older navigate cannot apply),
        // but must never publish a fresh navigate for the rebind.
        if let command = appState.editorNavigationCommand {
            if case .navigate = command {
                XCTFail("App must not apply a new find navigation after rebind; got \(command)")
            } else if case .cancel = command {
                // Expected: cancelPublishedFindNavigationOnSharedChannel on document switch.
            }
        }
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
        XCTAssertNil(appState.editorFindHost.controller.query)
        XCTAssertEqual(appState.editorFindHost.controller.documentBinding, .empty)
    }

    func testFindBarClosesOnWorkspaceClose() {
        let appState = makeAppState()
        openFindBar(appState, query: "alpha")
        XCTAssertTrue(appState.editorFindHost.ui.isBarVisible)
        XCTAssertNotNil(appState.editorFindHost.controller.query)

        appState.notifyEditorFindWorkspaceDidClose()

        XCTAssertFalse(appState.editorFindHost.ui.isBarVisible)
        XCTAssertEqual(appState.editorFindHost.ui.queryText, "")
        XCTAssertNil(appState.editorFindHost.controller.session)
        XCTAssertNil(
            appState.editorFindHost.controller.query,
            "controller query must clear on workspace close"
        )
    }

    func testFindCommandsNoOpWhenBarVisibleButFocusNotEditorOrFindField() {
        let appState = makeAppState()
        appState.editorFindHost.commandContextOverride = false
        var ui = appState.editorFindHost.ui
        ui.isBarVisible = true
        ui.queryText = "alpha"
        appState.setEditorFindUI(ui)
        let focusBefore = appState.editorFindHost.ui.focusRequestID

        // Bar visible alone is not eligibility when override says context inactive.
        appState.showOrRefocusEditorFind()
        XCTAssertEqual(appState.editorFindHost.ui.focusRequestID, focusBefore)

        appState.editorFindNext()
        appState.editorFindPrevious()
        appState.useSelectionForEditorFind()
        XCTAssertEqual(appState.editorFindHost.ui.queryText, "alpha")
    }

    func testFindNavigationUsesSharedAppNavigationChannelViaProvider() async throws {
        let appState = makeAppState(text: "one two one")
        // Simulate a prior workspace-search navigation at a high channel ID.
        appState.editorNavigationGeneration = 1000
        openFindBar(appState, query: "one")
        try await waitUntil("session ready") {
            appState.editorFindHost.controller.session?.total == 2
        }
        try await waitUntil("App publishes navigation") {
            appState.editorNavigationCommand != nil
        }
        guard case let .navigate(request)? = appState.editorNavigationCommand else {
            return XCTFail("expected navigate")
        }
        XCTAssertGreaterThan(
            request.id,
            1000,
            "find navigation must use App editorNavigationGeneration via navigationIDProvider"
        )
        XCTAssertFalse(request.shouldFocusEditor)
        // Provider is installed: controller pending shares the same ID as App publish.
        guard case let .navigate(pending)? = appState.editorFindHost.controller.pendingNavigationCommand
        else {
            return XCTFail("controller still holds pending")
        }
        XCTAssertEqual(pending.id, request.id)
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

    func testFindQueryFieldCoordinatorLeavesMarkedTextCommandsToInputContext() {
        // Behavioural gate: the Coordinator must not swallow Return/Escape while marked text
        // exists, so the input context can commit or cancel the composition. Hosted IME
        // streams remain owner-run (F6); this drives the real delegate callback.
        //
        // Previously this scraped `EditorFindQueryField.swift` for substrings, which proved
        // nothing about behaviour and deadlocked the sandboxed test host in `open()` when the
        // file's cached sandbox grant went stale.
        var submitCount = 0
        var escapeCount = 0
        let coordinator = EditorFindQueryField.Coordinator(
            text: .constant(""),
            readFocusSnapshot: { EditorFindUIState().focusSnapshot },
            markFocusApplied: { _ in },
            markSelectAllApplied: { _ in },
            onSubmit: { submitCount += 1 },
            onEscape: { escapeCount += 1 }
        )
        let field = NSTextField(string: "")
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))

        // No composition: the field owns Return and Escape.
        XCTAssertTrue(coordinator.control(
            field,
            textView: textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        XCTAssertEqual(submitCount, 1)
        XCTAssertTrue(coordinator.control(
            field,
            textView: textView,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        ))
        XCTAssertEqual(escapeCount, 1)

        // Composing: both keys belong to the input context, and neither action fires.
        textView.setMarkedText(
            "ㄅ",
            selectedRange: NSRange(location: 0, length: 1),
            replacementRange: NSRange(location: 0, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText(), "precondition: marked text is active")
        XCTAssertFalse(
            coordinator.control(
                field,
                textView: textView,
                doCommandBy: #selector(NSResponder.insertNewline(_:))
            ),
            "Return must commit the composition, not submit the find query"
        )
        XCTAssertFalse(
            coordinator.control(
                field,
                textView: textView,
                doCommandBy: #selector(NSResponder.cancelOperation(_:))
            ),
            "Escape must cancel the composition, not close the find bar"
        )
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(escapeCount, 1)
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
        appState.showOrRefocusEditorFind()
        XCTAssertTrue(appState.editorFindHost.ui.isBarVisible)
        let focusBefore = appState.editorFindHost.ui.focusRequestID
        let selectBefore = appState.editorFindHost.ui.selectAllRequestID

        // ⌘F while open: re-focus + select-all, never close.
        appState.showOrRefocusEditorFind()

        XCTAssertTrue(appState.editorFindHost.ui.isBarVisible, "⌘F must never close an open bar")
        XCTAssertEqual(appState.editorFindHost.ui.focusRequestID, focusBefore &+ 1)
        XCTAssertEqual(appState.editorFindHost.ui.selectAllRequestID, selectBefore &+ 1)
    }

    func testCommandFAndWorkspaceSearchFocusReceiptsDoNotCrossConsume() {
        let appState = makeAppState()
        appState.showOrRefocusEditorFind()
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
            "⇧⌘F must not advance find focusRequestID (token independence)"
        )
        XCTAssertEqual(
            appState.editorFindHost.ui.focusSupersededID,
            findAfter,
            "⇧⌘F must supersede pending Find focus so older async closures cannot steal"
        )
    }

    func testSupersededFindFocusIsNotEligibleForApply() {
        var ui = EditorFindUIState()
        ui.isBarVisible = true
        ui.requestFocusAndSelectAll()
        XCTAssertEqual(ui.focusRequestID, 1)
        XCTAssertEqual(ui.focusSupersededID, 0)
        ui.supersedePendingFocus()
        XCTAssertEqual(ui.focusSupersededID, 1)
        // A later ⌘F is still eligible (new request above superseded).
        ui.requestFocusAndSelectAll()
        XCTAssertEqual(ui.focusRequestID, 2)
        XCTAssertGreaterThan(ui.focusRequestID, ui.focusSupersededID)
    }

    // MARK: - ⌘E Use Selection (macOS convention: no show/focus)

    func testUseSelectionForFindSetsPatternWithoutShowingBar() {
        let appState = makeAppState(text: "prefix selectedWord suffix")
        let range = ("prefix selectedWord suffix" as NSString).range(of: "selectedWord")
        appState.editorFindHost.latestKnownEditorSelection = EditorFindCachedSelection(
            documentIdentity: appState.activeEditorDocumentIdentity,
            range: range
        )

        XCTAssertFalse(appState.editorFindHost.ui.isBarVisible)
        appState.useSelectionForEditorFind()
        XCTAssertEqual(appState.editorFindHost.ui.queryText, "selectedWord")
        XCTAssertFalse(
            appState.editorFindHost.ui.isBarVisible,
            "⌘E must not show the find bar (macOS convention)"
        )

        // Context inactive → no-op (does not show bar, does not change pattern).
        appState.editorFindHost.commandContextOverride = false
        appState.editorFindHost.ui.queryText = ""
        appState.setEditorFindUI(appState.editorFindHost.ui)
        appState.useSelectionForEditorFind()
        XCTAssertEqual(appState.editorFindHost.ui.queryText, "")
        XCTAssertFalse(appState.editorFindHost.ui.isBarVisible)
    }

    func testUseSelectionRejectsNewlinesAndOversizedPatterns() {
        let appState = makeAppState(text: "a\nb")
        appState.editorFindHost.latestKnownEditorSelection = EditorFindCachedSelection(
            documentIdentity: appState.activeEditorDocumentIdentity,
            range: NSRange(location: 0, length: 3) // includes newline
        )
        appState.useSelectionForEditorFind()
        XCTAssertEqual(appState.editorFindHost.ui.queryText, "")

        let long = String(repeating: "x", count: TextSearchEngine.maximumPatternUTF16Length + 1)
        let longSession = DocumentSession(
            text: long,
            url: URL(fileURLWithPath: "/tmp/plainsong-editor-find-long.md"),
            fileKind: .markdown
        )
        appState.setCurrentDocument(longSession, synchronizingWorkspaceTree: false)
        appState.editorFindHost.commandContextOverride = true
        appState.editorFindHost.latestKnownEditorSelection = EditorFindCachedSelection(
            documentIdentity: appState.activeEditorDocumentIdentity,
            range: NSRange(location: 0, length: long.utf16.count)
        )
        appState.useSelectionForEditorFind()
        XCTAssertEqual(appState.editorFindHost.ui.queryText, "")
    }

    func testCachedSelectionDoesNotCrossDocumentIdentity() {
        let appState = makeAppState(text: "alpha beta")
        let rangeA = ("alpha beta" as NSString).range(of: "alpha")
        appState.editorFindHost.latestKnownEditorSelection = EditorFindCachedSelection(
            documentIdentity: appState.activeEditorDocumentIdentity,
            range: rangeA
        )
        let other = DocumentSession(
            text: "gamma delta",
            url: URL(fileURLWithPath: "/tmp/plainsong-editor-find-other-sel.md"),
            fileKind: .markdown
        )
        appState.setCurrentDocument(other, synchronizingWorkspaceTree: false)
        // Cache cleared on switch.
        XCTAssertNil(appState.editorFindHost.latestKnownEditorSelection)

        appState.editorFindHost.commandContextOverride = true
        // Wrong-document cache must not supply ⌘E pattern.
        appState.editorFindHost.latestKnownEditorSelection = EditorFindCachedSelection(
            documentIdentity: EditorDocumentIdentity(rawValue: "file://other"),
            range: rangeA
        )
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
