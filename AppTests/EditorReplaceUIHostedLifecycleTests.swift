import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// R8 lifecycle (`docs/editor-replace-gates.md` §5.1 transition table) on the real row, each
/// with a Replace All preparing from the real button so "cancel progress" is observable.
@MainActor
extension EditorFindHostedGateTests {
    func testHostedEscapeInTheReplacementFieldClosesCancelsAndRetainsEverythingForReopen() async throws {
        let hosted = try await makeHostedReplaceRow(source: String(repeating: "hit ", count: 200))
        let app = hosted.appState
        let window = hosted.window
        let editor = try hostedEditor(hosted)
        let before = EditorReplaceEffectSnapshot(app, textView: editor)
        let hold = try await startHeldBarReplaceAll(hosted) {
            try await self.click(EditorFindAccessibility.replaceAllButton, in: window)
        }
        try await waitUntil("progress and Cancel are shown while preparing") {
            self.label(EditorFindAccessibility.replaceProgress, in: window)?.stringValue == "Preparing 0 / 200"
                && self.barButton(EditorFindAccessibility.replaceCancelButton, in: window) != nil
        }
        XCTAssertEqual(app.editorFindHost.lastReplaceAnnouncement, "Preparing 0 / 200")

        try replacementFieldEditor(in: window).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(app.editorFindHost.ui.isBarVisible)
        XCTAssertFalse(app.editorFindHost.replaceBatch.isPreparing, "closing cancels pre-commit work at once")
        hold.release()
        await awaitBarReplaceAll(app)
        XCTAssertEqual(app.editorFindHost.replaceBatch.lastResult, .superseded)
        try assertHostedBatchDidNotWrite(hosted, since: before)
        XCTAssertNil(app.editorFindHost.replaceStatus, "a closed row shows no late result")

        // ⌘F reopens with query, replacement value, and expansion retained.
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(EditorFindCommandDelivery.performShowFind())
        let field = try await waitForReplacementField(in: window)
        XCTAssertEqual(field.stringValue, "NEW")
        XCTAssertEqual(app.editorFindHost.ui.queryText, "hit")
        XCTAssertNil(label(EditorFindAccessibility.replaceProgress, in: window))
    }

    func testHostedCollapseThroughTheDisclosureCancelsThePlanAndHidesTheRetainedValue() async throws {
        let hosted = try await makeHostedReplaceRow(source: String(repeating: "hit ", count: 200))
        let app = hosted.appState
        let window = hosted.window
        let editor = try hostedEditor(hosted)
        let before = EditorReplaceEffectSnapshot(app, textView: editor)
        let hold = try await startHeldBarReplaceAll(hosted) {
            XCTAssertTrue(EditorFindCommandDelivery.performReplaceAll())
        }
        let generation = app.editorReplaceAuthorityGeneration

        try await click(EditorFindAccessibility.replaceDisclosure, in: window)
        XCTAssertGreaterThan(app.editorReplaceAuthorityGeneration, generation, "the real collapse seam")
        XCTAssertFalse(app.editorFindHost.replaceBatch.isPreparing)
        XCTAssertTrue(app.editorFindHost.ui.isBarVisible)
        hold.release()
        await awaitBarReplaceAll(app)
        XCTAssertEqual(app.editorFindHost.replaceBatch.lastResult, .superseded)
        try assertHostedBatchDidNotWrite(hosted, since: before)
        try await waitUntil("the collapsed row unmounts its field and actions") {
            self.replacementField(in: window) == nil
                && self.barButton(EditorFindAccessibility.replaceAllButton, in: window) == nil
        }
        XCTAssertFalse(EditorFindCommandDelivery.performReplace())
        XCTAssertFalse(EditorFindCommandDelivery.performReplaceAll())
        XCTAssertEqual(app.currentDocument.text, before.appText)

        try await click(EditorFindAccessibility.replaceDisclosure, in: window)
        let field = try await waitForReplacementField(in: window)
        XCTAssertEqual(field.stringValue, "NEW")
    }

    func testHostedFileSwitchKeepsTheExpandedRowAndValuesAndDropsThePlanAndMessage() async throws {
        let hosted = try await makeHostedReplaceRow(source: String(repeating: "hit ", count: 200))
        let app = hosted.appState
        let window = hosted.window
        let other = hosted.fixture.root.appendingPathComponent("other.md")
        try "hit other".write(to: other, atomically: true, encoding: .utf8)
        app.refreshWorkspaceAfterFileSystemChange()
        try await waitUntil("the workspace capture includes other.md") {
            app.workspaceInstalledCaptureGeneration == app.workspaceGeneration
                && app.workspaceSnapshot?.entries.contains { $0.relativePath == "other.md" } == true
        }
        let identity = ObjectIdentifier(app.currentDocument)
        app.workspaceMutationWriteFences.insert(identity)
        try await click(EditorFindAccessibility.replaceButton, in: window)
        XCTAssertEqual(app.editorFindHost.replaceStatus?.kind, .blocked)
        app.workspaceMutationWriteFences.remove(identity)
        let postSource = app.currentDocument.text

        let hold = try await startHeldBarReplaceAll(hosted) {
            try await self.click(EditorFindAccessibility.replaceAllButton, in: window)
        }
        app.openWorkspaceFile(other)
        try await waitUntil("the sidebar switch installs other.md") {
            app.currentDocument.fileURL?.lastPathComponent == "other.md"
        }
        XCTAssertFalse(app.editorFindHost.replaceBatch.isPreparing, "a switch cancels progress")
        XCTAssertNil(app.editorFindHost.replaceStatus, "no message survives the switch")
        hold.release()
        await awaitBarReplaceAll(app)
        XCTAssertEqual(app.editorFindHost.replaceBatch.lastResult, .superseded)
        XCTAssertTrue(app.editorFindHost.ui.isReplaceRowActive, "the bar stays visible and expanded")
        XCTAssertEqual(app.editorFindHost.ui.replacementText, "NEW")
        let field = try await waitForReplacementField(in: window)
        XCTAssertEqual(field.stringValue, "NEW")
        try await waitUntil("the counter recomputes for the new document") {
            app.editorFindHost.controller.session?.total == 1
        }
        XCTAssertEqual(app.currentDocument.text, "hit other", "no replacement intent survives the switch")
        XCTAssertEqual(try String(contentsOf: hosted.postURL, encoding: .utf8), postSource)
    }

    func testHostedExternalReloadKeepsValuesAndExpansionCancelsProgressAndRecountsFirst() async throws {
        let hosted = try await makeHostedReplaceRow(source: String(repeating: "hit ", count: 200))
        let app = hosted.appState
        let window = hosted.window
        let hold = try await startHeldBarReplaceAll(hosted) {
            try await self.click(EditorFindAccessibility.replaceAllButton, in: window)
        }
        // A clean document reloads from disk without a prompt (§5.1 Reload row).
        try "hit x hit y".write(to: hosted.postURL, atomically: true, encoding: .utf8)
        app.refreshWorkspaceAfterFileSystemChange()
        try await waitUntil("the external change is adopted") { app.currentDocument.text == "hit x hit y" }
        XCTAssertFalse(app.editorFindHost.replaceBatch.isPreparing, "Reload cancels progress")
        hold.release()
        await awaitBarReplaceAll(app)
        XCTAssertEqual(app.editorFindHost.replaceBatch.lastResult, .superseded)
        XCTAssertEqual(app.currentDocument.text, "hit x hit y")
        XCTAssertTrue(app.editorFindHost.ui.isReplaceRowActive)
        XCTAssertEqual(app.editorFindHost.ui.replacementText, "NEW")
        try await waitUntil("authoritative post-resolution recompute and settled authority") {
            app.editorFindHost.controller.session?.total == 2
                && app.editorFindHost.controller.documentBinding.revision == UInt64(app.currentDocument.version)
                && app.editorReplaceAuthorizationDecision(for: app.currentDocument) == .allowed
        }
        // Only a fresh explicit action, after the recount, replaces.
        app.notifyEditorFindDocumentIdentityDidRekey()
        try await waitUntil("rekey rebinds the retained query") { app.editorFindHost.controller.session?.total == 2 }
        XCTAssertTrue(app.editorFindHost.ui.isReplaceRowActive, "rekey keeps the row")
        try await click(EditorFindAccessibility.replaceAllButton, in: window)
        await awaitBarReplaceAll(app)
        XCTAssertEqual(app.currentDocument.text, "NEW x NEW y")
    }

    func testHostedEditorTypingWithTheRowOpenTouchesNoReplaceGenerationOrRowState() async throws {
        let hosted = try await makeHostedReplaceRow()
        let app = hosted.appState
        let editor = try hostedEditor(hosted)
        XCTAssertTrue(hosted.window.makeFirstResponder(editor))
        editor.textSelection = NSRange(location: 15, length: 0)
        let authority = app.editorReplaceAuthorityGeneration
        let replacement = app.editorFindHost.replaceBatch.replacementGeneration
        let serial = app.editorFindHost.replaceStatusSerial
        let ui = app.editorFindHost.ui
        for character in "typing" {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
        }
        XCTAssertEqual(app.currentDocument.text, "hit one hit twotyping")
        XCTAssertEqual(app.editorReplaceAuthorityGeneration, authority, "editor keystrokes never touch authority")
        XCTAssertEqual(app.editorFindHost.replaceBatch.replacementGeneration, replacement)
        XCTAssertEqual(app.editorFindHost.replaceStatusSerial, serial)
        XCTAssertEqual(app.editorFindHost.ui.replacementText, ui.replacementText)
        XCTAssertEqual(app.editorFindHost.ui.replacementValidity, ui.replacementValidity)
        XCTAssertFalse(app.editorFindHost.replaceBatch.isPreparing)
    }
}
