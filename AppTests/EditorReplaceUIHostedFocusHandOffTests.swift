import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// Replace PR H review fixes on the real row: focus never strands on the window when a
/// focused row control unmounts (B1), bar presses act only from the key window's bar (M3),
/// `Applying…` renders before the final recheck (M1), and Escape from a focused row button.
@MainActor
extension EditorFindHostedGateTests {
    /// After focus moved away from a removed control, every Find command is still eligible.
    func assertFindCommandsStayEligible(
        _ hosted: HostedReplaceWorkspace,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let app = hosted.appState
        XCTAssertTrue(app.isEditorFindCommandContextActive(), "⌘F / ⌘G / ⌘E context", file: file, line: line)
        XCTAssertTrue(EditorFindCommandDelivery.performFindNext(), "⌘G", file: file, line: line)
        XCTAssertTrue(EditorFindCommandDelivery.performFindPrevious(), "⇧⌘G", file: file, line: line)
        XCTAssertTrue(
            EditorFindCommandDelivery.performShowFindAndReplace(),
            "Find and Replace…", file: file, line: line
        )
        XCTAssertTrue(
            EditorFindCommandDelivery.performShowFind(), "⌘F", file: file, line: line
        )
    }

    func testHostedCollapseWhileARowControlHasFocusHandsFocusToTheQueryField() async throws {
        let hosted = try await makeHostedReplaceRow()
        let app = hosted.appState
        let window = hosted.window
        // The replacement field is focused; clicking the disclosure does not move focus.
        XCTAssertTrue(isReplacementFieldFirstResponder(in: window))
        try await click(EditorFindAccessibility.replaceDisclosure, in: window)
        try await waitUntil("collapse removes the focused field and focus lands on the query field") {
            self.replacementField(in: window) == nil && self.isFindFieldFirstResponder(in: window)
        }
        XCTAssertEqual(app.editorFindHost.ui.focusRequestID, app.editorFindHost.ui.focusAppliedID, "no new token")
        assertFindCommandsStayEligible(hosted)

        // A focused row button (Full Keyboard Access) collapses the same way.
        try await waitUntil("Find and Replace… re-expanded the row") { self.replacementField(in: window) != nil }
        let replaceAll = try await waitForBarButton(EditorFindAccessibility.replaceAllButton, in: window)
        XCTAssertTrue(window.makeFirstResponder(replaceAll))
        app.setEditorReplaceExpanded(false)
        try await waitUntil("the focused button's removal hands focus to the query field") {
            self.barButton(EditorFindAccessibility.replaceAllButton, in: window) == nil
                && self.isFindFieldFirstResponder(in: window)
        }
        assertFindCommandsStayEligible(hosted)
    }

    func testHostedCancelLeavingWhileFocusedHandsFocusToReplaceAllOrTheField() async throws {
        let source = String(repeating: "hit ", count: 200)
        // Pressed: Cancel unmounts and Replace All takes focus.
        var hosted = try await makeHostedReplaceRow(source: source)
        var hold = try await startHeldBarReplaceAll(hosted) {
            try await self.click(EditorFindAccessibility.replaceAllButton, in: hosted.window)
        }
        var cancel = try await waitForBarButton(EditorFindAccessibility.replaceCancelButton, in: hosted.window)
        XCTAssertTrue(hosted.window.makeFirstResponder(cancel))
        cancel.performClick(nil)
        hold.release()
        await awaitBarReplaceAll(hosted.appState)
        try await assertCancelHandedFocus(to: EditorFindAccessibility.replaceAllButton, hosted)

        // Committed: the plan finishes on its own while Cancel holds focus.
        hosted = try await makeHostedReplaceRow(source: source)
        hold = try await startHeldBarReplaceAll(hosted) {
            try await self.click(EditorFindAccessibility.replaceAllButton, in: hosted.window)
        }
        cancel = try await waitForBarButton(EditorFindAccessibility.replaceCancelButton, in: hosted.window)
        XCTAssertTrue(hosted.window.makeFirstResponder(cancel))
        hold.release()
        await awaitBarReplaceAll(hosted.appState)
        guard case .delivered(.replaced)? = hosted.appState.editorFindHost.replaceBatch.lastResult else {
            return XCTFail("the plan must commit")
        }
        try await assertCancelHandedFocus(to: EditorFindAccessibility.replaceAllButton, hosted)

        // Superseded with Replace All disabled (the query was cleared): the field takes focus.
        hosted = try await makeHostedReplaceRow(source: source)
        hold = try await startHeldBarReplaceAll(hosted) {
            try await self.click(EditorFindAccessibility.replaceAllButton, in: hosted.window)
        }
        cancel = try await waitForBarButton(EditorFindAccessibility.replaceCancelButton, in: hosted.window)
        XCTAssertTrue(hosted.window.makeFirstResponder(cancel))
        hosted.appState.handleEditorFindQueryTextChange("")
        hold.release()
        await awaitBarReplaceAll(hosted.appState)
        try await assertCancelHandedFocus(to: EditorFindAccessibility.replacementField, hosted)
    }

    private func assertCancelHandedFocus(
        to identifier: String,
        _ hosted: HostedReplaceWorkspace,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let window = hosted.window
        try await waitUntil("Cancel unmounted and \(identifier) holds focus") {
            guard self.barButton(EditorFindAccessibility.replaceCancelButton, in: window) == nil else {
                return false
            }
            if identifier == EditorFindAccessibility.replacementField {
                return self.isReplacementFieldFirstResponder(in: window)
            }
            return window.firstResponder === self.barButton(identifier, in: window)
        }
        XCTAssertTrue(hosted.appState.isEditorFindCommandContextActive(), file: file, line: line)
        if hosted.appState.editorFindHost.ui.hasActiveQuery {
            assertFindCommandsStayEligible(hosted, file: file, line: line)
        } else {
            XCTAssertTrue(EditorFindCommandDelivery.performShowFindAndReplace(), file: file, line: line)
            XCTAssertTrue(EditorFindCommandDelivery.performShowFind(), file: file, line: line)
        }
    }

    func testHostedApplyingRendersBeforeTheFinalRecheckWhichStillCatchesChangesInThatFrame() async throws {
        let hosted = try await makeHostedReplaceRow(source: String(repeating: "hit ", count: 200))
        let app = hosted.appState
        let window = hosted.window
        let state = app.editorFindHost.replaceBatch
        var rendered: String?
        var cancelShown = true
        state.willCommitForTesting = {
            rendered = self.label(EditorFindAccessibility.replaceProgress, in: window)?.stringValue
            cancelShown = self.barButton(EditorFindAccessibility.replaceCancelButton, in: window) != nil
        }
        defer { state.willCommitForTesting = nil }
        try await click(EditorFindAccessibility.replaceAllButton, in: window)
        await awaitBarReplaceAll(app)
        XCTAssertEqual(
            rendered,
            "Applying…",
            "the row rendered Applying… before the final recheck" + replaceBarTraceDiagnostic(app)
        )
        XCTAssertFalse(
            cancelShown,
            "Cancel is withdrawn once preparation is done" + replaceBarTraceDiagnostic(app)
        )
        XCTAssertEqual(app.editorReplaceActivity, .idle)
        guard case .delivered(.replaced)? = state.lastResult else { return XCTFail("expected the batch") }

        // A selection A→B→A during that frame still fails the final recheck.
        let editor = try hostedEditor(hosted)
        editor.undoManager?.undo()
        try await waitUntil("Undo restores a fresh retained set") {
            app.editorFindHost.controller.session?.total == 200
                && app.editorFindHost.controller.documentBinding.revision == UInt64(app.currentDocument.version)
        }
        let before = EditorReplaceEffectSnapshot(app, textView: editor)
        state.didBeginApplyingForTesting = {
            Task { @MainActor in
                let original = editor.selectedRange()
                editor.textSelection = NSRange(location: 1, length: 0)
                editor.textSelection = original
            }
        }
        defer { state.didBeginApplyingForTesting = nil }
        try await click(EditorFindAccessibility.replaceAllButton, in: window)
        await awaitBarReplaceAll(app)
        XCTAssertEqual(state.lastResult, .superseded)
        try assertHostedBatchDidNotWrite(hosted, since: before)
    }

    func testHostedBackgroundWindowBarPressesCannotReachTheKeyWindowsEditor() async throws {
        let hosted = try await makeHostedReplaceRow(source: "hit one hit two")
        let app = hosted.appState
        let windowB = mountDesignatedKeyWorkspace(in: hosted.group, appState: app, originX: 40)
        _ = try await waitForReplacementField(in: windowB)
        let editor = try hostedEditor(hosted)
        app.editorFindHost.replaceAuthority.lastAuthorizationRecord = nil
        let before = EditorReplaceEffectSnapshot(app, textView: editor)
        XCTAssertTrue(hosted.window.isKeyWindow)

        try await click(EditorFindAccessibility.replaceButton, in: windowB)
        try await click(EditorFindAccessibility.replaceAllButton, in: windowB)
        try replacementFieldEditor(in: windowB).doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertNil(app.editorFindHost.replaceAllTask, "a background bar starts no Replace All")
        XCTAssertEqual(EditorReplaceEffectSnapshot(app, textView: editor), before, "zero effect on A's editor")
        XCTAssertNil(app.editorFindHost.replaceAuthority.lastAuthorizationRecord, "nothing was even validated")

        // The key window's own bar still works.
        try await click(EditorFindAccessibility.replaceButton, in: hosted.window)
        XCTAssertEqual(app.currentDocument.text, "NEW one hit two")
    }

    func testHostedEscapeOnAFocusedRowButtonClosesTheBarAndCancelsThePlan() async throws {
        let hosted = try await makeHostedReplaceRow(source: String(repeating: "hit ", count: 200))
        let app = hosted.appState
        let window = hosted.window
        let before = try EditorReplaceEffectSnapshot(app, textView: hostedEditor(hosted))
        let hold = try await startHeldBarReplaceAll(hosted) {
            try await self.click(EditorFindAccessibility.replaceAllButton, in: window)
        }
        let cancel = try await waitForBarButton(EditorFindAccessibility.replaceCancelButton, in: window)
        XCTAssertTrue(window.makeFirstResponder(cancel))
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
        ))
        window.sendEvent(escape)
        XCTAssertFalse(app.editorFindHost.ui.isBarVisible, "Escape on a focused row button closes the bar")
        XCTAssertFalse(app.editorFindHost.replaceBatch.isPreparing, "closing cancels the plan")
        hold.release()
        await awaitBarReplaceAll(app)
        try assertHostedBatchDidNotWrite(hosted, since: before)
    }

    func testHostedTransientBlockedMessageIsWithdrawnWhenTheInspectionSettles() async throws {
        let hosted = try await makeHostedReplaceRow()
        let app = hosted.appState
        let window = hosted.window
        let session = app.currentDocument
        let location = try WorkspaceFileSystemLocation(fileURL: hosted.postURL)
        app.externalDiskInspectionTasks[ObjectIdentifier(session)] = ExternalDiskInspectionTask(
            token: UUID(), session: session, canonicalURL: location.fileURL, location: location,
            lifecycleGeneration: 0, diskEventGeneration: 0,
            sourceSnapshot: EditorDocumentSourceSnapshot(source: session.text, revision: session.version),
            task: Task {}
        )
        try await click(EditorFindAccessibility.replaceButton, in: window)
        XCTAssertEqual(app.editorFindHost.replaceStatus?.blockedReason, .externalObservationPending)
        XCTAssertTrue(app.editorFindHost.replaceStatus?.isTransient == true, "shown with a clock, not a lock")
        app.externalDiskInspectionTasks[ObjectIdentifier(session)] = nil
        try await waitUntil("the settled inspection withdraws its blocked message") {
            app.editorFindHost.replaceStatus == nil
                && self.label(EditorFindAccessibility.replaceBlockedReason, in: window) == nil
        }
    }
}
