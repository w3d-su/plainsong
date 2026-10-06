import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// R8 focus: Find and Replace… reuses the query receipt, Tab / click reach the replacement
/// field without a token, and ⌘F / ⌘E / ⌘G / ⇧⌘G / ⇧⌘F keep their contracts beside the row.
@MainActor
extension EditorFindHostedGateTests {
    func testHostedFindAndReplaceUsesTheQueryReceiptAndTabReachesReplacementWithoutAToken() async throws {
        let hosted = try await makeHostedBatchWorkspace()
        let app = hosted.appState
        let window = hosted.window
        installProductionKeyWindowSeams(app, group: hosted.group)
        routeMenuCommands(to: app)
        app.handleEditorFindQueryTextChange("hit one")
        let editor = try hostedEditor(hosted)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertFalse(app.editorFindHost.ui.isReplaceExpanded)
        let generation = app.editorReplaceAuthorityGeneration

        XCTAssertTrue(EditorFindCommandDelivery.performShowFindAndReplace())
        let request = app.editorFindHost.ui.focusRequestID
        XCTAssertTrue(app.editorFindHost.ui.isReplaceRowActive)
        XCTAssertGreaterThan(app.editorReplaceAuthorityGeneration, generation)
        try await waitUntil("the existing receipt focuses the query with select-all") {
            app.editorFindHost.ui.focusAppliedID == request
                && app.editorFindHost.ui.selectAllAppliedID == app.editorFindHost.ui.selectAllRequestID
                && self.findFieldEditorSelection(in: window) == NSRange(location: 0, length: 7)
        }
        _ = try await waitForReplacementField(in: window)

        // Tab: AppKit's key-view loop, no App focus request.
        let queryEditor = try XCTUnwrap(findQueryField(in: window)?.currentEditor() as? NSTextView)
        queryEditor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(isReplacementFieldFirstResponder(in: window))
        try await assertFocusRemains("no competing token takes focus back", windows: [window], appState: app) {
            self.isReplacementFieldFirstResponder(in: window)
                && app.editorFindHost.ui.focusRequestID == request
                && app.editorFindHost.ui.focusAppliedID == request
        }
        let replacementEditor = try replacementFieldEditor(in: window)
        replacementEditor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        XCTAssertTrue(isFindFieldFirstResponder(in: window))

        // Click: the field takes focus directly; still no token.
        try clickIntoFindField(in: window)
        let field = try XCTUnwrap(replacementField(in: window))
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(isReplacementFieldFirstResponder(in: window))
        XCTAssertEqual(app.editorFindHost.ui.focusRequestID, request)
    }

    func testHostedCommandFRefocusesAndSelectsTheQueryWithoutCollapsingAndCancelsThePlan() async throws {
        let hosted = try await makeHostedReplaceRow(source: String(repeating: "hit ", count: 200))
        let app = hosted.appState
        let window = hosted.window
        let editor = try hostedEditor(hosted)
        let before = EditorReplaceEffectSnapshot(app, textView: editor)
        let hold = try await startHeldBarReplaceAll(hosted) {
            try await self.click(EditorFindAccessibility.replaceAllButton, in: window)
        }
        XCTAssertTrue(app.editorFindHost.replaceBatch.isPreparing)
        XCTAssertTrue(isReplacementFieldFirstResponder(in: window))

        XCTAssertTrue(EditorFindCommandDelivery.performShowFind(), "the replacement field is Find provenance")
        XCTAssertFalse(app.editorFindHost.replaceBatch.isPreparing, "⌘F cancels the pre-commit plan at once")
        XCTAssertTrue(app.editorFindHost.ui.isReplaceRowActive, "⌘F never collapses the row")
        let request = app.editorFindHost.ui.focusRequestID
        try await waitUntil("⌘F focuses and selects the query") {
            app.editorFindHost.ui.focusAppliedID == request
                && self.findFieldEditorSelection(in: window) == NSRange(location: 0, length: 3)
        }
        hold.release()
        await awaitBarReplaceAll(app)
        XCTAssertEqual(app.editorFindHost.replaceBatch.lastResult, .superseded)
        try assertHostedBatchDidNotWrite(hosted, since: before)
        XCTAssertEqual(app.editorFindHost.ui.replacementText, "NEW")
        XCTAssertTrue(replacementField(in: window) != nil)
    }

    func testHostedUseSelectionForFindAndFindNextPreviousLeaveTheReplacementAndSourceAlone() async throws {
        let hosted = try await makeHostedReplaceRow(source: "hit one hit two")
        let app = hosted.appState
        let window = hosted.window
        let editor = try hostedEditor(hosted)
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.textSelection = NSRange(location: 4, length: 3)
        try await waitUntil("the editor applied the selection") {
            self.appliedRange(in: window) == NSRange(location: 4, length: 3)
        }
        let ui = app.editorFindHost.ui
        XCTAssertTrue(EditorFindCommandDelivery.performUseSelectionForFind())
        XCTAssertEqual(app.editorFindHost.ui.queryText, "one")
        XCTAssertEqual(app.editorFindHost.ui.replacementText, ui.replacementText)
        XCTAssertEqual(app.editorFindHost.ui.isReplaceExpanded, ui.isReplaceExpanded)
        XCTAssertEqual(app.editorFindHost.ui.isBarVisible, ui.isBarVisible)
        XCTAssertEqual(app.editorFindHost.ui.focusRequestID, ui.focusRequestID, "⌘E never focuses the bar")
        XCTAssertTrue(window.firstResponder === editor)

        app.handleEditorFindQueryTextChange("hit")
        try await waitUntil("the retained set is back") { app.editorFindHost.controller.session?.total == 2 }
        _ = try replacementFieldEditor(in: window)
        let source = app.currentDocument.text
        let undo = editor.undoManager?.canUndo
        for step in [EditorFindCommandDelivery.performFindNext, EditorFindCommandDelivery.performFindPrevious,
                     EditorFindCommandDelivery.performFindNext]
        {
            XCTAssertTrue(step())
            XCTAssertEqual(app.currentDocument.text, source, "⌘G / ⇧⌘G never mutate")
        }
        try await waitUntil("Find navigation still applies") {
            self.appliedRange(in: window) == app.editorFindHost.controller.session?.currentMatch?.range
        }
        XCTAssertEqual(editor.undoManager?.canUndo, undo)
        XCTAssertEqual(app.editorFindHost.ui.replacementText, "NEW")
    }

    func testHostedShiftCommandFCancelsThePlanAndSupersedesFindFocusWithoutConsumingReceipts() async throws {
        let hosted = try await makeHostedReplaceRow(source: String(repeating: "hit ", count: 200))
        let app = hosted.appState
        let window = hosted.window
        let editor = try hostedEditor(hosted)
        let before = EditorReplaceEffectSnapshot(app, textView: editor)
        let hold = try await startHeldBarReplaceAll(hosted) {
            try await self.click(EditorFindAccessibility.replaceAllButton, in: window)
        }
        let receipts = app.editorFindHost.ui.focusSnapshot
        let search = app.workspaceSearchUI.focusRequestID

        XCTAssertTrue(PlainsongWorkspaceSearchKeyAction.performIfAvailable())
        XCTAssertFalse(app.editorFindHost.replaceBatch.isPreparing, "⇧⌘F cancels the pre-commit plan at once")
        XCTAssertEqual(app.workspaceSearchUI.focusRequestID, search &+ 1)
        let after = app.editorFindHost.ui.focusSnapshot
        XCTAssertEqual(after.requestID, receipts.requestID, "⇧⌘F issues no Find focus token")
        XCTAssertEqual(after.appliedID, receipts.appliedID, "⇧⌘F consumes no Find receipt")
        XCTAssertEqual(after.selectAllAppliedID, receipts.selectAllAppliedID)
        XCTAssertGreaterThanOrEqual(after.supersededID, receipts.supersededID)
        XCTAssertEqual(app.editorFindHost.ui.replacementText, "NEW")
        XCTAssertEqual(app.editorFindHost.ui.queryText, "hit")
        XCTAssertTrue(app.editorFindHost.ui.isReplaceRowActive)
        hold.release()
        await awaitBarReplaceAll(app)
        XCTAssertEqual(app.editorFindHost.replaceBatch.lastResult, .superseded)
        try assertHostedBatchDidNotWrite(hosted, since: before)

        // A pending Find request (no key window yet) is superseded, never consumed.
        designateKeyWindow(nil, in: hosted.group)
        app.editorFindHost.commandContextOverride = true
        app.showOrRefocusEditorFind()
        app.editorFindHost.commandContextOverride = nil
        let pending = app.editorFindHost.ui.focusRequestID
        XCTAssertTrue(PlainsongWorkspaceSearchKeyAction.performIfAvailable())
        if app.workspaceSearchUI.mode != .search {
            XCTAssertTrue(PlainsongWorkspaceSearchKeyAction.performIfAvailable())
        }
        XCTAssertEqual(app.editorFindHost.ui.focusSupersededID, pending)
        XCTAssertNotEqual(app.editorFindHost.ui.focusAppliedID, pending)
        designateKeyWindow(window, in: hosted.group)
        try await assertFocusRemains("the superseded Find request never applies", windows: [window], appState: app) {
            app.editorFindHost.ui.focusAppliedID != pending && !self.isFindFieldFirstResponder(in: window)
        }
    }
}
