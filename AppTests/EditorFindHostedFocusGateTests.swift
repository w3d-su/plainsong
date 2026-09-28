import AppKit
@testable import EditorKit
import Foundation
@testable import Plainsong
import XCTest

/// F7 focus arbitration on production `WorkspaceWindow`s whose key status is designated
/// (see `DesignatedKeyWindow`). Every assertion about focus reads the window's real
/// `firstResponder` / field editor; receipt IDs are checked only alongside it.
@MainActor
extension EditorFindHostedGateTests {
    func testHostedFindEligibleAfterSearchHandoffOnlyTheNewerFindRequestTakesFocus() async throws {
        let fixture = try makeWorkspaceFixture(files: ["post.md": "alpha"])
        let appState = fixture.appState
        appState.setLayoutMode(.sourceOnly)
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens") { appState.hasOpenDocument }
        let group = makeHostedWorkspaceGroup(fixture: fixture)
        let window = mountDesignatedKeyWorkspace(in: group, appState: appState)

        // ⌘F while no window is key: the owned field mounts and its real retry loop polls but
        // must not apply. That loop sleeps at least 180 × 16 ms ≈ 2.9 s before it gives up.
        let olderFindIssuedAt = Date()
        openFindBar(appState, query: "")
        _ = try await waitForFindQueryField(in: window)
        let olderFind = appState.editorFindHost.ui.focusRequestID
        XCTAssertGreaterThan(olderFind, 0)
        try await assertFocusRemains(
            "with no key window the older Find request stays pending",
            windows: [window],
            appState: appState
        ) {
            !self.isFindFieldFirstResponder(in: window)
                && appState.editorFindHost.ui.focusAppliedID != olderFind
        }
        // The supersession below must hit a *live* older request: still unresolved App-side,
        // and issued well inside its field's retry budget, so its loop is still polling.
        XCTAssertTrue(EditorFindFocusArbitration.shouldKeepRetrying(
            requestID: olderFind,
            snapshot: appState.editorFindHost.ui.focusSnapshot
        ))
        XCTAssertLessThan(
            Date().timeIntervalSince(olderFindIssuedAt),
            2.0,
            "⇧⌘F must arrive while the older Find retry loop is still running"
        )

        // ⇧⌘F, and the host becomes key in the same main-actor turn: the older Find retry is
        // now eligible on key status and mount, and only the newer intent may take focus.
        appState.focusWorkspaceSearch()
        let searchRequest = appState.workspaceSearchUI.focusRequestID
        designateKeyWindow(window, in: group)

        try await waitUntil("Search owns the real field editor in the key host") {
            appState.workspaceSearchUI.focusAppliedID == searchRequest
                && WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: window)
        }
        try await assertFocusRemains(
            "the superseded Find request never steals the field editor",
            windows: [window],
            appState: appState
        ) {
            WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: window)
                && !self.isFindFieldFirstResponder(in: window)
                && appState.editorFindHost.ui.focusAppliedID != olderFind
        }
        XCTAssertEqual(appState.editorFindHost.ui.focusSupersededID, olderFind)
        XCTAssertTrue(appState.editorFindHost.ui.isBarVisible, "Find stays open across the hand-off")

        // Re-issue ⌘F in the now-eligible host: the newer request lands on the Find field.
        appState.showOrRefocusEditorFind()
        let newerFind = appState.editorFindHost.ui.focusRequestID
        XCTAssertGreaterThan(newerFind, olderFind)
        try await waitUntil("the newer Find request takes the real field editor") {
            appState.editorFindHost.ui.focusAppliedID == newerFind
                && self.isFindFieldFirstResponder(in: window)
        }
        try await assertFocusRemains(
            "Search's spent request does not take focus back",
            windows: [window],
            appState: appState
        ) {
            self.isFindFieldFirstResponder(in: window)
                && !WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: window)
        }
        XCTAssertEqual(appState.workspaceSearchUI.focusRequestID, searchRequest)
        XCTAssertEqual(appState.workspaceSearchUI.focusAppliedID, searchRequest)
    }

    func testHostedFindAndSearchFocusReceiptsStayIndependentOnRealFirstResponders() async throws {
        let fixture = try makeWorkspaceFixture(files: ["post.md": "alpha"])
        let appState = fixture.appState
        appState.setLayoutMode(.sourceOnly)
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens") { appState.hasOpenDocument }
        let group = makeHostedWorkspaceGroup(fixture: fixture)
        let window = mountDesignatedKeyWorkspace(in: group, appState: appState)
        designateKeyWindow(window, in: group)

        // Alternate ⇧⌘F and ⌘F so each feature's request carries the very integer the other
        // feature just consumed. A shared or aliased receipt would treat it as already spent
        // and leave focus on the wrong field.
        for round in 1 ... 2 {
            let findBefore = appState.editorFindHost.ui
            appState.focusWorkspaceSearch()
            let search = appState.workspaceSearchUI.focusRequestID
            XCTAssertEqual(search, UInt64(round))
            try await waitUntil("round \(round): Search consumes its receipt on the real field editor") {
                appState.workspaceSearchUI.focusAppliedID == search
                    && WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: window)
            }
            try await assertFocusRemains(
                "round \(round): Search keeps focus",
                windows: [window],
                appState: appState
            ) {
                WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: window)
                    && !self.isFindFieldFirstResponder(in: window)
            }
            XCTAssertEqual(appState.editorFindHost.ui.focusRequestID, findBefore.focusRequestID)
            XCTAssertEqual(
                appState.editorFindHost.ui.focusAppliedID,
                findBefore.focusAppliedID,
                "round \(round): consuming a Search receipt must not consume Find's"
            )

            let searchBefore = appState.workspaceSearchUI
            if round == 1 {
                openFindBar(appState, query: "")
            } else {
                appState.showOrRefocusEditorFind()
            }
            let find = appState.editorFindHost.ui.focusRequestID
            XCTAssertEqual(find, search, "round \(round): the two receipts deliberately collide")
            try await waitUntil("round \(round): Find consumes its receipt on the real field editor") {
                appState.editorFindHost.ui.focusAppliedID == find
                    && self.isFindFieldFirstResponder(in: window)
            }
            try await assertFocusRemains(
                "round \(round): Find keeps focus",
                windows: [window],
                appState: appState
            ) {
                self.isFindFieldFirstResponder(in: window)
                    && !WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: window)
            }
            XCTAssertEqual(
                appState.workspaceSearchUI,
                searchBefore,
                "round \(round): consuming a Find receipt must not touch Search's"
            )
        }
    }

    func testHostedSpentFocusAndSelectAllCannotReplayInAnotherWindow() async throws {
        let fixture = try makeWorkspaceFixture(files: ["post.md": "alpha"])
        let appState = fixture.appState
        appState.setLayoutMode(.sourceOnly)
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens") { appState.hasOpenDocument }
        let group = makeHostedWorkspaceGroup(fixture: fixture)
        let windowA = mountDesignatedKeyWorkspace(in: group, appState: appState)
        let windowB = mountDesignatedKeyWorkspace(in: group, appState: appState, originX: 1040)
        designateKeyWindow(windowA, in: group)

        // "zzz" never matches, so no find navigation touches either editor's focus.
        openFindBar(appState, query: "zzz")
        let requested = appState.editorFindHost.ui.focusSnapshot
        try await waitUntil("window A consumes focus and select-all on its real field editor") {
            appState.editorFindHost.ui.focusAppliedID == requested.requestID
                && appState.editorFindHost.ui.selectAllAppliedID == requested.selectAllRequestID
                && self.findFieldEditorSelection(in: windowA) == NSRange(location: 0, length: 3)
        }
        let spent = appState.editorFindHost.ui.focusSnapshot
        _ = try await waitForFindQueryField(in: windowB)
        XCTAssertFalse(isFindFieldFirstResponder(in: windowB))

        // Window B becomes key with the request already spent in A.
        designateKeyWindow(windowB, in: group)
        republishFindChrome(appState)
        try await assertFocusRemains(
            "window B never replays A's spent focus request",
            windows: [windowA, windowB],
            appState: appState
        ) {
            !self.isFindFieldFirstResponder(in: windowB)
                && self.isFindFieldFirstResponder(in: windowA)
                && appState.editorFindHost.ui.focusSnapshot == spent
        }

        // The user clicks into B's field. Its fresh coordinator must not replay A's spent
        // select-all, or the next keystroke would replace the whole query.
        try clickIntoFindField(in: windowB)
        republishFindChrome(appState)
        try await assertFocusRemains(
            "window B keeps the user's caret; no select-all replay",
            windows: [windowA, windowB],
            appState: appState
        ) {
            self.findFieldEditorSelection(in: windowB) == NSRange(location: 3, length: 0)
                && appState.editorFindHost.ui.focusSnapshot == spent
        }
    }

    func testHostedRemountedBarCannotReplayASpentRequestAndANewOneLandsOnlyInTheKeyWindow() async throws {
        let fixture = try makeWorkspaceFixture(files: ["post.md": "alpha"])
        let appState = fixture.appState
        appState.setLayoutMode(.sourceOnly)
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens") { appState.hasOpenDocument }
        let group = makeHostedWorkspaceGroup(fixture: fixture)
        let windowA = mountDesignatedKeyWorkspace(in: group, appState: appState)
        designateKeyWindow(windowA, in: group)

        openFindBar(appState, query: "zzz")
        let requested = appState.editorFindHost.ui.focusSnapshot
        try await waitUntil("window A consumes focus and select-all on its real field editor") {
            appState.editorFindHost.ui.focusAppliedID == requested.requestID
                && appState.editorFindHost.ui.selectAllAppliedID == requested.selectAllRequestID
                && self.findFieldEditorSelection(in: windowA) == NSRange(location: 0, length: 3)
        }
        let spent = appState.editorFindHost.ui.focusSnapshot

        // A new `WindowGroup` window mounts a fresh bar (fresh coordinator, zero local state)
        // against the shared, already-spent receipts, and becomes key.
        let windowC = mountDesignatedKeyWorkspace(in: group, appState: appState, originX: 1040)
        _ = try await waitForFindQueryField(in: windowC)
        designateKeyWindow(windowC, in: group)
        republishFindChrome(appState)
        try await assertFocusRemains(
            "the remounted bar never replays the spent focus request",
            windows: [windowA, windowC],
            appState: appState
        ) {
            !self.isFindFieldFirstResponder(in: windowC)
                && appState.editorFindHost.ui.focusSnapshot == spent
        }
        try clickIntoFindField(in: windowC)
        republishFindChrome(appState)
        try await assertFocusRemains(
            "the remounted bar never replays the spent select-all",
            windows: [windowA, windowC],
            appState: appState
        ) {
            self.findFieldEditorSelection(in: windowC) == NSRange(location: 3, length: 0)
                && appState.editorFindHost.ui.focusSnapshot == spent
        }

        // Park both fields on their editors and issue a new ⌘F with **no** key window: every
        // bar's live retry loop must hold it. Then C becomes key: only C's field may take it,
        // and A's must not steal it while A is in the background.
        for window in [windowA, windowC] {
            let editor = try XCTUnwrap(editorTextView(in: window))
            XCTAssertTrue(window.makeFirstResponder(editor))
        }
        designateKeyWindow(nil, in: group)
        appState.showOrRefocusEditorFind()
        let fresh = appState.editorFindHost.ui.focusSnapshot
        XCTAssertGreaterThan(fresh.requestID, spent.requestID)
        try await assertFocusRemains(
            "with no key window neither bar takes the new request",
            windows: [windowA, windowC],
            appState: appState
        ) {
            !self.isFindFieldFirstResponder(in: windowA)
                && !self.isFindFieldFirstResponder(in: windowC)
                && appState.editorFindHost.ui.focusAppliedID == spent.requestID
        }
        designateKeyWindow(windowC, in: group)
        try await waitUntil("the new request lands on the key window's real field editor") {
            appState.editorFindHost.ui.focusAppliedID == fresh.requestID
                && appState.editorFindHost.ui.selectAllAppliedID == fresh.selectAllRequestID
                && self.findFieldEditorSelection(in: windowC) == NSRange(location: 0, length: 3)
        }
        try await assertFocusRemains(
            "the background window's bar does not take the new request",
            windows: [windowA, windowC],
            appState: appState
        ) {
            !self.isFindFieldFirstResponder(in: windowA)
                && self.isFindFieldFirstResponder(in: windowC)
        }
    }
}
