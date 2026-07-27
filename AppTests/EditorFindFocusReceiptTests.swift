import AppKit
import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// Focus and select-all receipts are App-owned so a second `WindowGroup` window (or a
/// remounted bar) cannot replay a spent token, plus find-bar chrome command eligibility.
@MainActor
final class EditorFindFocusReceiptTests: XCTestCase {
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

    func testFindBarChromeFocusKeepsMenuCommandsEligibleOnlyForTheHostingKeyWindow() async throws {
        let text = "one two one two one"
        let appState = makeAppState(text: text)
        openFindBar(appState, query: "one")
        try await waitUntil("session ready") {
            appState.editorFindHost.controller.session?.total == 3
        }

        // Eligibility comes from the reported SwiftUI chrome focus, and the report is only
        // meaningful next to the window that produced it. Only *which window is key* is
        // stubbed; the report-versus-key comparison under test still runs. Reading ambient
        // `NSApp.keyWindow` instead would make this order-dependent on any other test that
        // leaves a window key — CI caught exactly that.
        appState.editorFindHost.commandContextOverride = nil
        let background = 101
        let key = 202
        appState.editorFindHost.keyWindowNumberOverride = key

        // Window A (background) reports focus on its own bar.
        appState.setEditorFindChromeFocus(.matchCase, inWindowNumber: background)
        XCTAssertFalse(
            appState.isEditorFindCommandContextActive(),
            "Focus stranded in a background window must not make ⌘G / ⌘E eligible in the key one"
        )

        // Window B (key) reports focus on its own bar.
        appState.setEditorFindChromeFocus(.matchCase, inWindowNumber: key)
        XCTAssertTrue(
            appState.isEditorFindCommandContextActive(),
            "Focus on a bar control in the key window must keep ⌘G / ⌘E live"
        )

        // An untagged report cannot be checked against the key window, so it is not stored.
        appState.setEditorFindChromeFocus(.wholeWord, inWindowNumber: nil)
        XCTAssertNil(appState.editorFindHost.chromeFocus)
        XCTAssertFalse(appState.isEditorFindCommandContextActive())

        // Focus left the bar: fall back to the AppKit editor / query-field check.
        appState.setEditorFindChromeFocus(.matchCase, inWindowNumber: key)
        appState.clearEditorFindChromeFocus()
        XCTAssertEqual(
            appState.isEditorFindCommandContextActive(),
            EditorFindResponderSupport.keyWindowHasEditorOrFindField(),
            "Without chrome focus, eligibility is exactly the AppKit responder answer"
        )

        // A hidden bar is never eligible, whatever focus was last reported.
        appState.setEditorFindChromeFocus(.matchCase, inWindowNumber: key)
        var ui = appState.editorFindHost.ui
        ui.isBarVisible = false
        appState.setEditorFindUI(ui)
        XCTAssertFalse(appState.isEditorFindCommandContextActive())
    }

    func testKeyWindowChangeAloneFlipsChromeFocusEligibility() {
        let appState = makeAppState()
        openFindBar(appState, query: "alpha")
        appState.editorFindHost.commandContextOverride = nil

        // One report, unchanged. Only which window is key moves — as when the user switches
        // windows without touching the bar.
        appState.setEditorFindChromeFocus(.next, inWindowNumber: 7)
        appState.editorFindHost.keyWindowNumberOverride = 7
        XCTAssertTrue(appState.isEditorFindCommandContextActive())

        appState.editorFindHost.keyWindowNumberOverride = 9
        XCTAssertFalse(
            appState.isEditorFindCommandContextActive(),
            "The same report must stop granting eligibility once its window is no longer key"
        )
        XCTAssertEqual(
            appState.editorFindHost.chromeFocus?.windowNumber,
            7,
            "The report itself is retained — only its relevance changed"
        )
    }

    func testEveryBarCloseRouteClearsReportedChromeFocus() {
        for close in [
            ("Escape / Done", { (state: AppState) in state.closeEditorFindBar() }),
            ("workspace close", { (state: AppState) in state.notifyEditorFindWorkspaceDidClose() }),
            ("no document remains", { (state: AppState) in
                state.currentDocument = DocumentSession()
                state.notifyEditorFindDocumentDidSwitch()
            }),
        ] {
            let appState = makeAppState()
            openFindBar(appState, query: "alpha")
            appState.setEditorFindChromeFocus(.next, inWindowNumber: 31)
            XCTAssertEqual(appState.editorFindHost.chromeFocus?.focus, .next, close.0)

            close.1(appState)
            XCTAssertFalse(appState.editorFindHost.ui.isBarVisible, close.0)
            XCTAssertNil(
                appState.editorFindHost.chromeFocus,
                "\(close.0): a closed bar must not leave focus state that keeps commands eligible"
            )
        }
    }

    func testEditorAndQueryFieldResponderEligibilityIsUnchanged() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // This window carries the owned query-field identifier, so leaving it key would make
        // `keyWindowHostsFindBar()` true for every later test in the process. CI failed on
        // exactly that ordering before this teardown existed.
        //
        // `orderOut`, not `close`: a programmatic `NSWindow` defaults to
        // `isReleasedWhenClosed = true`, so closing it over-releases the local reference and
        // takes the test host down with it.
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        let queryField = NSTextField(string: "")
        queryField.setAccessibilityIdentifier(EditorFindAccessibility.queryField)
        queryField.frame = NSRect(x: 0, y: 360, width: 200, height: 24)
        let unrelated = NSButton(title: "Files", target: nil, action: nil)
        unrelated.frame = NSRect(x: 300, y: 100, width: 80, height: 24)
        root.addSubview(queryField)
        root.addSubview(unrelated)
        window.makeKeyAndOrderFront(nil)

        guard window.makeFirstResponder(queryField) else {
            throw XCTSkip("makeFirstResponder(queryField) unavailable in this runner")
        }
        XCTAssertTrue(EditorFindResponderSupport.windowHasEditorOrFindChrome(window))

        guard window.makeFirstResponder(unrelated) else {
            throw XCTSkip("makeFirstResponder(unrelated) unavailable in this runner")
        }
        XCTAssertFalse(
            EditorFindResponderSupport.windowHasEditorOrFindChrome(window),
            "Focus outside the editor and the owned query field stays ineligible in AppKit"
        )
    }

    // MARK: - Select-all receipt

    func testSelectAllReceiptIsSharedSoASecondWindowCannotReplayIt() {
        let appState = makeAppState()
        openFindBar(appState, query: "alpha")
        let selectAllID = appState.editorFindHost.ui.selectAllRequestID
        XCTAssertGreaterThan(selectAllID, 0)
        XCTAssertEqual(appState.editorFindHost.ui.selectAllAppliedID, 0)

        // Window A's field performed it.
        appState.markEditorFindSelectAllApplied(selectAllID)
        XCTAssertEqual(appState.editorFindHost.ui.selectAllAppliedID, selectAllID)

        // Window B's coordinator is fresh — its local receipt would be 0. The shared one is
        // what decides, and it already recorded this request as spent.
        let snapshot = appState.editorFindHost.ui.focusSnapshot
        XCTAssertFalse(
            snapshot.selectAllRequestID > snapshot.selectAllAppliedID,
            "A spent select-all must not be replayable, or the next keystroke wipes the query"
        )

        // A fresh ⌘F is a new request and is applicable again.
        appState.showOrRefocusEditorFind()
        let next = appState.editorFindHost.ui.focusSnapshot
        XCTAssertGreaterThan(next.selectAllRequestID, next.selectAllAppliedID)
    }

    func testSelectAllReceiptRejectsStaleAndRepeatedRequests() {
        let appState = makeAppState()
        openFindBar(appState, query: "alpha")
        let selectAllID = appState.editorFindHost.ui.selectAllRequestID

        appState.markEditorFindSelectAllApplied(selectAllID - 1)
        XCTAssertEqual(
            appState.editorFindHost.ui.selectAllAppliedID,
            0,
            "An older request must not advance the receipt"
        )
        appState.markEditorFindSelectAllApplied(selectAllID)
        appState.markEditorFindSelectAllApplied(selectAllID)
        XCTAssertEqual(appState.editorFindHost.ui.selectAllAppliedID, selectAllID)
    }
}
