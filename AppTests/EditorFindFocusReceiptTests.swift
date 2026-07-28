import AppKit
@testable import EditorKit
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

        // An untagged report cannot be checked against the key window and cannot be scoped to
        // an owner, so it is ignored outright rather than stored or used to clear.
        appState.setEditorFindChromeFocus(.wholeWord, inWindowNumber: nil)
        XCTAssertEqual(appState.editorFindHost.chromeFocusByWindow[key], .matchCase)
        appState.setEditorFindChromeFocus(nil, inWindowNumber: nil)
        XCTAssertEqual(
            appState.editorFindHost.chromeFocusByWindow[key],
            .matchCase,
            "An untagged clear must not drop an owned report"
        )
        XCTAssertEqual(
            appState.editorFindHost.chromeFocusByWindow,
            [background: .matchCase, key: .matchCase],
            "Both windows keep their own report; the untagged calls changed nothing"
        )
        XCTAssertTrue(appState.isEditorFindCommandContextActive())

        // Focus left the bar: fall back to the AppKit editor / query-field check.
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
            appState.editorFindHost.chromeFocusByWindow[7],
            .next,
            "The report itself is retained — only its relevance changed"
        )
    }

    func testBackgroundWindowCannotClearTheKeyWindowsChromeFocusReport() {
        let appState = makeAppState()
        openFindBar(appState, query: "alpha")
        appState.editorFindHost.commandContextOverride = nil
        let key = 202
        let background = 101
        appState.editorFindHost.keyWindowNumberOverride = key

        // Full Keyboard Access has focus on the key window's Aa toggle.
        appState.setEditorFindChromeFocus(.matchCase, inWindowNumber: key)
        XCTAssertTrue(appState.isEditorFindCommandContextActive())

        // A background window's bar loses focus, or unmounts, and reports nil for itself.
        appState.setEditorFindChromeFocus(nil, inWindowNumber: background)
        XCTAssertEqual(appState.editorFindHost.chromeFocusByWindow[key], .matchCase)
        XCTAssertTrue(
            appState.isEditorFindCommandContextActive(),
            "⌘G / ⌘E must survive an unrelated window closing or losing focus"
        )

        // The owning window clears its own report normally.
        appState.setEditorFindChromeFocus(nil, inWindowNumber: key)
        XCTAssertNil(appState.editorFindHost.chromeFocusByWindow[key])
        XCTAssertFalse(appState.isEditorFindCommandContextActive())
    }

    func testBackgroundWindowCannotOverwriteTheKeyWindowsChromeFocusReport() {
        let appState = makeAppState()
        openFindBar(appState, query: "alpha")
        appState.editorFindHost.commandContextOverride = nil
        let key = 202
        let background = 101
        appState.editorFindHost.keyWindowNumberOverride = key
        appState.setEditorFindChromeFocus(.matchCase, inWindowNumber: key)

        // A background window reporting its own focus is a real report — it just belongs to
        // that window. It must not displace the key window's.
        appState.setEditorFindChromeFocus(.next, inWindowNumber: background)
        XCTAssertEqual(appState.editorFindHost.chromeFocusByWindow[key], .matchCase)
        XCTAssertEqual(appState.editorFindHost.chromeFocusByWindow[background], .next)
        XCTAssertTrue(
            appState.isEditorFindCommandContextActive(),
            "A background window's own focus must not take ⌘G / ⌘E away from the key window"
        )
    }

    func testSwitchingBackToAWindowThatAlreadyReportedFocusRestoresEligibility() {
        let appState = makeAppState()
        openFindBar(appState, query: "alpha")
        appState.editorFindHost.commandContextOverride = nil
        let windowA = 11
        let windowB = 22

        // Both bars hold their own SwiftUI FocusState; B reported last.
        appState.setEditorFindChromeFocus(.matchCase, inWindowNumber: windowA)
        appState.setEditorFindChromeFocus(.next, inWindowNumber: windowB)

        // Switching back to A republishes nothing: neither A's focus nor A's window number
        // changed, so no `onChange` fires. Eligibility must come from A's retained entry.
        appState.editorFindHost.keyWindowNumberOverride = windowA
        XCTAssertTrue(
            appState.isEditorFindCommandContextActive(),
            "Returning to a window whose bar still holds focus must restore ⌘G / ⌘E"
        )

        appState.editorFindHost.keyWindowNumberOverride = windowB
        XCTAssertTrue(appState.isEditorFindCommandContextActive())

        // A third window that never reported anything is not eligible.
        appState.editorFindHost.keyWindowNumberOverride = 33
        XCTAssertFalse(appState.isEditorFindCommandContextActive())
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
            // Two windows both reporting: an App-scoped close must drop every entry.
            appState.setEditorFindChromeFocus(.next, inWindowNumber: 31)
            appState.setEditorFindChromeFocus(.matchCase, inWindowNumber: 32)
            XCTAssertEqual(appState.editorFindHost.chromeFocusByWindow.count, 2, close.0)

            close.1(appState)
            XCTAssertFalse(appState.editorFindHost.ui.isBarVisible, close.0)
            XCTAssertTrue(
                appState.editorFindHost.chromeFocusByWindow.isEmpty,
                "\(close.0): a closed bar must not leave focus state that keeps commands eligible"
            )
        }
    }

    // MARK: - Window bridge

    func testWindowBridgeDefersPublicationToTheNextMainActorTurn() async throws {
        let bridge = EditorFindBarWindowBridge()
        let window = makeProbeWindow()
        defer { window.orderOut(nil) }

        // `EditorFindBarWindowReader.updateNSView` calls this from inside a SwiftUI view
        // update. Publishing synchronously there is undefined and trips "Modifying state
        // during view update", which is why the bar no longer writes `@State` directly.
        bridge.attach(to: window)
        XCTAssertNil(
            bridge.windowNumber,
            "The window must not be published synchronously during a view update"
        )

        try await waitUntil("bridge publishes on a later turn") {
            bridge.windowNumber == window.windowNumber
        }

        // Repeat attachment for the same window is a no-op.
        bridge.attach(to: window)
        XCTAssertEqual(bridge.windowNumber, window.windowNumber)

        // Detaching publishes nil, also deferred.
        bridge.attach(to: nil)
        XCTAssertEqual(bridge.windowNumber, window.windowNumber)
        try await waitUntil("bridge publishes detachment") { bridge.windowNumber == nil }
    }

    func testWindowBridgeAttachThenImmediateDetachNeverPublishesTheStaleWindow() async throws {
        let bridge = EditorFindBarWindowBridge()
        let window = makeProbeWindow()
        defer { window.orderOut(nil) }

        // Without generation fencing the second call compares against the *published* value —
        // still nil — decides nothing changed, returns early, and lets the first task publish
        // a window that is no longer attached.
        bridge.attach(to: window)
        bridge.attach(to: nil)

        for _ in 0 ..< 5 {
            await Task.yield()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(
            bridge.windowNumber,
            "A superseded attachment must never be published after it was detached"
        )
        XCTAssertNil(bridge.lastAttachedWindowNumber)
    }

    func testWindowBridgePublishesOnlyTheLatestOfARapidSequence() async throws {
        let bridge = EditorFindBarWindowBridge()
        let first = makeProbeWindow()
        let second = makeProbeWindow()
        defer {
            first.orderOut(nil)
            second.orderOut(nil)
        }

        bridge.attach(to: first)
        bridge.attach(to: second)
        bridge.attach(to: nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(bridge.windowNumber, "Only the last attachment of a burst may be published")

        // A→B settles on B, and B is remembered for teardown even after a later detach.
        bridge.attach(to: first)
        bridge.attach(to: second)
        try await waitUntil("bridge settles on the last window") {
            bridge.windowNumber == second.windowNumber
        }
        XCTAssertEqual(bridge.lastAttachedWindowNumber, second.windowNumber)

        bridge.attach(to: nil)
        try await waitUntil("bridge detaches") { bridge.windowNumber == nil }
        XCTAssertEqual(
            bridge.lastAttachedWindowNumber,
            second.windowNumber,
            "Teardown still needs the window whose report it must clear"
        )
    }

    func testWindowBridgeDismantleDetachesTheProbe() async throws {
        let bridge = EditorFindBarWindowBridge()
        let window = makeProbeWindow()
        defer { window.orderOut(nil) }
        let probe = EditorFindBarWindowProbeView()
        probe.bridge = bridge
        window.contentView?.addSubview(probe)
        try await waitUntil("probe reports its window") {
            bridge.windowNumber == window.windowNumber
        }

        EditorFindBarWindowReader.dismantleNSView(probe, coordinator: ())
        try await waitUntil("dismantle detaches") { bridge.windowNumber == nil }
        XCTAssertNil(probe.bridge)
        XCTAssertEqual(
            bridge.lastAttachedWindowNumber,
            window.windowNumber,
            "The bar must still be able to address the report it made for that window"
        )
    }

    private func makeProbeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    func testResponderEligibilityIsScopedToTheWindowItIsAskedAbout() throws {
        // Window A holds editor focus **and is the key window**; window B holds nothing
        // relevant. Asking about B must answer for B.
        //
        // The key window is driven through `EditorSelectionProbe.keyWindowOverrideForTesting`
        // because a test process cannot make a programmatic window key — `NSApp.keyWindow`
        // stays nil while the host app is inactive, and without the override a global
        // key-window implementation and a window-scoped one answer identically, so the test
        // could not tell them apart. With the override installed, reverting
        // `windowHasEditorOrFindChrome` to `keyWindowHasEditorFocus()` fails this test.
        let windowA = makeProbeWindow()
        let windowB = makeProbeWindow()
        defer {
            EditorSelectionProbe.keyWindowOverrideForTesting = nil
            windowA.orderOut(nil)
            windowB.orderOut(nil)
        }

        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))
        editor.setAccessibilityIdentifier(EditorAccessibility.textViewIdentifier)
        windowA.contentView?.addSubview(editor)
        let unrelated = NSButton(title: "Files", target: nil, action: nil)
        unrelated.frame = NSRect(x: 0, y: 0, width: 80, height: 24)
        windowB.contentView?.addSubview(unrelated)

        guard windowA.makeFirstResponder(editor) else {
            throw XCTSkip("makeFirstResponder(editor) unavailable in this runner")
        }
        guard windowB.makeFirstResponder(unrelated) else {
            throw XCTSkip("makeFirstResponder(unrelated) unavailable in this runner")
        }
        EditorSelectionProbe.keyWindowOverrideForTesting = { windowA }
        XCTAssertTrue(
            EditorSelectionProbe.keyWindowHasEditorFocus(),
            "precondition: the *key* window holds editor focus, which is what would leak"
        )

        XCTAssertTrue(
            EditorFindResponderSupport.windowHasEditorOrFindChrome(windowA),
            "The window that actually holds editor focus is eligible"
        )
        XCTAssertFalse(
            EditorFindResponderSupport.windowHasEditorOrFindChrome(windowB),
            "The key window's editor focus must not make a different window eligible"
        )

        // And the probe the check relies on is itself window-scoped.
        XCTAssertTrue(EditorSelectionProbe.hasEditorFocus(in: windowA))
        XCTAssertFalse(EditorSelectionProbe.hasEditorFocus(in: windowB))
    }

    func testEditorAndQueryFieldResponderEligibilityIsUnchanged() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // This window carries the owned query-field identifier and is made key below, so
        // leaving it key would change what `NSApp.keyWindow` answers for every later test in
        // the process. CI failed on exactly that ordering before this teardown existed.
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
