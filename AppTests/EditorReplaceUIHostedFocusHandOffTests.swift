import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// Replace PR H review fixes on the real row: focus never strands on the window when a
/// focused row control unmounts (B1), bar presses act only from the key window's bar (M3),
/// Applying frames remain owned by their action, and Escape from a focused row button.
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

    func testHostedCancelLeavingWhileFocusedHandsFocusToReplaceAllWhenEnabledElseTheField() async throws {
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

        // Superseded while the recount is held: the committed query keeps Replace All enabled.
        hosted = try await makeHostedReplaceRow(source: source)
        hold = try await startHeldBarReplaceAll(hosted) {
            try await self.click(EditorFindAccessibility.replaceAllButton, in: hosted.window)
        }
        cancel = try await waitForBarButton(EditorFindAccessibility.replaceCancelButton, in: hosted.window)
        XCTAssertTrue(hosted.window.makeFirstResponder(cancel))
        let controller = hosted.appState.editorFindHost.controller
        let recount = EditorFindMatchHold()
        controller.testMatchHold = recount
        defer {
            recount.release()
            controller.testMatchHold = nil
        }
        hosted.appState.handleEditorFindQueryTextChange("hi")
        XCTAssertNil(controller.session, "precondition: the recount is held")
        XCTAssertFalse(
            hosted.appState.editorFindHost.ui.hasActiveQuery,
            "precondition: the session-derived flag is false"
        )
        hold.release()
        await awaitBarReplaceAll(hosted.appState)
        try await assertCancelHandedFocus(to: EditorFindAccessibility.replaceAllButton, hosted)
        XCTAssertNil(controller.session, "the hand-off happened while the recount was still held")
        recount.release()
        controller.testMatchHold = nil

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
        let observed = observeCommitTimeRow(hosted)
        defer {
            state.willCommitForTesting = nil
            state.applyingFrameDidElapseForTesting = nil
        }
        try await click(EditorFindAccessibility.replaceAllButton, in: window)
        await awaitBarReplaceAll(app)
        XCTAssertEqual(
            observed.rendered,
            "Applying…",
            "the row rendered Applying… before the final recheck" + replaceBarTraceDiagnostic(app)
        )
        XCTAssertFalse(
            observed.cancelShown,
            "Cancel is withdrawn once preparation is done (still attached one run-loop turn into the "
                + "Applying frame): \(observed.strayReport ?? "not mounted at the frame end")"
                + barViewTraceDiagnostic()
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

    func testHostedReplaceAllPressedDuringAnotherApplyingFrameShowsPreparingAndKeepsItsOwnApplyingFrame() async throws {
        let hosted = try await makeHostedReplaceRow(source: String(repeating: "hit ", count: 200))
        try await waitForHostedReplaceObservationQuiescence(hosted)
        let app = hosted.appState
        let window = hosted.window
        let state = app.editorFindHost.replaceBatch
        let bHold = HostedReplaceBatchHold()
        let probe = HostedOverlappingApplyingProbe()
        defer {
            bHold.release()
            state.didBeginApplyingForTesting = nil
            state.applyingFrameDidElapseForTesting = nil
            state.onChunkForTesting = nil
        }
        addTeardownBlock { @MainActor in
            bHold.release()
            state.didBeginApplyingForTesting = nil
            state.applyingFrameDidElapseForTesting = nil
            state.onChunkForTesting = nil
        }

        state.didBeginApplyingForTesting = {
            probe.applyingBegins += 1
            if probe.applyingBegins == 1 {
                state.onChunkForTesting = { _ in bHold.checkpoint() }
                let replaceAll = self.barButton(EditorFindAccessibility.replaceAllButton, in: window)
                probe.bPressEnabled = replaceAll?.isEnabled
                replaceAll?.performClick(nil)
            } else if probe.applyingBegins == 2 {
                probe.bBeganApplying = true
            }
        }
        state.applyingFrameDidElapseForTesting = {
            probe.applyingFrameEnds += 1
            if probe.applyingFrameEnds == 1 {
                do {
                    try await self.waitUntil("B enters held preparation") { bHold.isEntered }
                } catch {
                    XCTFail("waiting for B's held preparation threw: \(error)" + self.replaceBarTraceDiagnostic(app))
                    return
                }
                probe.bPreparationWasHeld = bHold.isEntered
                probe.bPreparationRanOnMainThread = bHold.didRunOnMainThread
                probe.isApplyingAtAFrameEnd = state.isApplying
                probe.activityAtAFrameEnd = app.editorReplaceActivity
                if case .preparing = app.editorReplaceActivity {
                    probe.preparingAtAFrameEnd = true
                }
                do {
                    try await self.waitUntil("B's Preparing label and Cancel render while held") {
                        self.label(EditorFindAccessibility.replaceProgress, in: window)?.stringValue
                            != EditorReplaceStatusText.applying
                            && self.barButton(EditorFindAccessibility.replaceCancelButton, in: window) != nil
                    }
                } catch {
                    XCTFail("waiting for B's Preparing row threw: \(error)" + self.replaceBarTraceDiagnostic(app))
                }
                let rendered = await self.observeAfterOneMainRunLoopTurn {
                    (
                        self.label(EditorFindAccessibility.replaceProgress, in: window)?.stringValue,
                        self.barButton(EditorFindAccessibility.replaceCancelButton, in: window) != nil
                    )
                }
                probe.progressAtAFrameEnd = rendered.0
                probe.cancelMountedAtAFrameEnd = rendered.1
                bHold.release()
                do {
                    try await self.waitUntil("B begins its Applying frame") { probe.bBeganApplying }
                } catch {
                    XCTFail("waiting for B's Applying frame threw: \(error)" + self.replaceBarTraceDiagnostic(app))
                }
            } else if probe.applyingFrameEnds == 2 {
                _ = await probe.aTask?.value
                probe.isApplyingAtBFrameEnd = state.isApplying
                probe.activityAtBFrameEnd = app.editorReplaceActivity
                probe.progressAtBFrameEnd = await self.observeAfterOneMainRunLoopTurn {
                    self.label(EditorFindAccessibility.replaceProgress, in: window)?.stringValue
                }
            }
        }
        probe.aTask = Task { @MainActor in
            await app.performEditorReplaceAll(
                replacement: app.editorFindHost.ui.replacementText,
                invocation: .barControl
            )
        }

        guard let aTask = probe.aTask else { return XCTFail("A's task was not created") }
        let aResult = await aTask.value
        probe.aResult = aResult
        await awaitBarReplaceAll(app)
        probe.lastResult = state.lastResult
        probe.finalActivity = app.editorReplaceActivity
        let diagnostic = probe.diagnostic + replaceBarTraceDiagnostic(app)
        #if DEBUG
            if ProcessInfo.processInfo.environment["PLAINSONG_HOSTED_TRACE_STDOUT"] == "1" {
                print("REPLPROBE \(probe.diagnostic)")
            }
        #endif

        XCTAssertEqual(probe.aResult, .superseded, "A is superseded by the bar press: \(diagnostic)")
        guard case .delivered(.replaced)? = probe.lastResult else {
            return XCTFail("B commits: \(diagnostic)")
        }
        XCTAssertEqual(probe.applyingBegins, 2, "A and B each begin Applying: \(diagnostic)")
        XCTAssertEqual(probe.applyingFrameEnds, 2, "A and B each reach frame end: \(diagnostic)")
        XCTAssertTrue(probe.bPressEnabled == true, "B's real bar button was enabled: \(diagnostic)")
        XCTAssertTrue(probe.bPreparationWasHeld, "B was held during preparation: \(diagnostic)")
        XCTAssertFalse(probe.bPreparationRanOnMainThread, "B's preparation ran off-main: \(diagnostic)")
        XCTAssertEqual(probe.isApplyingAtAFrameEnd, false, "B is not applying at A's frame end: \(diagnostic)")
        XCTAssertTrue(probe.preparingAtAFrameEnd, "B shows Preparing at A's frame end: \(diagnostic)")
        XCTAssertNotNil(probe.progressAtAFrameEnd, "B's progress label is mounted: \(diagnostic)")
        XCTAssertNotEqual(
            probe.progressAtAFrameEnd, EditorReplaceStatusText.applying,
            "B does not render Applying at A's frame end: \(diagnostic)"
        )
        XCTAssertTrue(probe.cancelMountedAtAFrameEnd, "B's Cancel is mounted while preparing: \(diagnostic)")
        XCTAssertTrue(probe.bBeganApplying, "B entered its Applying frame: \(diagnostic)")
        XCTAssertEqual(probe.isApplyingAtBFrameEnd, true, "A's wake-up leaves B applying: \(diagnostic)")
        XCTAssertEqual(probe.activityAtBFrameEnd, .applying, "B still owns the Applying activity: \(diagnostic)")
        XCTAssertEqual(
            probe.progressAtBFrameEnd, EditorReplaceStatusText.applying,
            "B's Applying label survives A's finish: \(diagnostic)"
        )
        XCTAssertEqual(probe.finalActivity, .idle, "the current action finishes idle: \(diagnostic)")

        bHold.release()
        state.didBeginApplyingForTesting = nil
        state.applyingFrameDidElapseForTesting = nil
        state.onChunkForTesting = nil
    }

    /// Records the row at commit. A Cancel mounted at the end of the Applying frame — only
    /// synchronous code separates it from `willCommit` — gets exactly one run-loop turn (one
    /// main-queue hop) to unmount while `Applying…` is still shown: SwiftUI can defer the
    /// removal one turn, but a Cancel still attached after it means the Applying frame never
    /// withdrew it. The turn must pass before the commit: after it the row is idle, which
    /// hides a Cancel kept mounted while applying.
    private func observeCommitTimeRow(_ hosted: HostedReplaceWorkspace) -> HostedCommitTimeRow {
        let app = hosted.appState
        let window = hosted.window
        let state = app.editorFindHost.replaceBatch
        let observed = HostedCommitTimeRow()
        state.applyingFrameDidElapseForTesting = {
            guard self.barButton(EditorFindAccessibility.replaceCancelButton, in: window) != nil else { return }
            self.recordReplaceStray("cancelButton mountedAtCommit=true activity=\(app.editorReplaceActivity)")
            let report: String? = await self.observeAfterOneMainRunLoopTurn {
                guard let stray = self.barButton(EditorFindAccessibility.replaceCancelButton, in: window),
                      stray.superview != nil
                else { return nil }
                return self.mountedBarButtonDiagnostic(stray, window: window, app: app)
            }
            observed.strayReport = report ?? "transient: gone after one turn"
            self.recordReplaceStray(
                "cancelButton \(report == nil ? "transient" : "persistent") afterTurns=1 "
                    + "stillAttached=\(report != nil) activity=\(app.editorReplaceActivity)"
            )
        }
        state.willCommitForTesting = {
            observed.rendered = self.label(EditorFindAccessibility.replaceProgress, in: window)?.stringValue
            observed.cancelShown = self.barButton(EditorFindAccessibility.replaceCancelButton, in: window) != nil
        }
        return observed
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

/// What the row showed at `willCommitForTesting`, plus the diagnostic for a Cancel still
/// attached one run-loop turn into the Applying frame.
@MainActor
final class HostedCommitTimeRow {
    var rendered: String?
    var cancelShown = true
    var strayReport: String?
}

@MainActor
final class HostedOverlappingApplyingProbe {
    var aTask: Task<EditorReplaceBatchCommandResult, Never>?
    var aResult: EditorReplaceBatchCommandResult?
    var lastResult: EditorReplaceBatchCommandResult?
    var applyingBegins = 0
    var applyingFrameEnds = 0
    var bPressEnabled: Bool?
    var bBeganApplying = false
    var bPreparationWasHeld = false
    var bPreparationRanOnMainThread = true
    var isApplyingAtAFrameEnd: Bool?
    var activityAtAFrameEnd: EditorReplaceActivity?
    var preparingAtAFrameEnd = false
    var progressAtAFrameEnd: String?
    var cancelMountedAtAFrameEnd = false
    var isApplyingAtBFrameEnd: Bool?
    var activityAtBFrameEnd: EditorReplaceActivity?
    var progressAtBFrameEnd: String?
    var finalActivity: EditorReplaceActivity?

    var diagnostic: String {
        "aResult=\(aResult?.replaceBatchTraceSummary ?? "nil") "
            + "lastResult=\(lastResult?.replaceBatchTraceSummary ?? "nil") "
            + "applyingBegins=\(applyingBegins) applyingFrameEnds=\(applyingFrameEnds) "
            + "bPressEnabled=\(String(describing: bPressEnabled)) bBeganApplying=\(bBeganApplying) "
            + "bPreparationWasHeld=\(bPreparationWasHeld) "
            + "bPreparationRanOnMainThread=\(bPreparationRanOnMainThread) "
            + "isApplyingAtAFrameEnd=\(String(describing: isApplyingAtAFrameEnd)) "
            + "activityAtAFrameEnd=\(String(describing: activityAtAFrameEnd)) "
            + "preparingAtAFrameEnd=\(preparingAtAFrameEnd) "
            + "progressAtAFrameEnd=\(String(describing: progressAtAFrameEnd)) "
            + "cancelMountedAtAFrameEnd=\(cancelMountedAtAFrameEnd) "
            + "isApplyingAtBFrameEnd=\(String(describing: isApplyingAtBFrameEnd)) "
            + "activityAtBFrameEnd=\(String(describing: activityAtBFrameEnd)) "
            + "progressAtBFrameEnd=\(String(describing: progressAtBFrameEnd)) "
            + "finalActivity=\(String(describing: finalActivity))"
    }
}
