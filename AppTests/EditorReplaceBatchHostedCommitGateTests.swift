import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

@MainActor
extension EditorFindHostedGateTests {
    func testHostedReplaceAllActualEditorMarkedTextStartsNoPreparationOrAuthorization() async throws {
        let hosted = try await makeHostedBatchWorkspace()
        let app = hosted.appState
        let editor = try hostedEditor(hosted)
        editor.setMarkedText("ㄓ", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        defer { editor.unmarkText() }
        XCTAssertTrue(editor.hasMarkedText())
        let before = EditorReplaceEffectSnapshot(app, textView: editor)
        let action = app.editorFindHost.replaceBatch.actionID
        let result = await app.performEditorReplaceAll(replacement: "NEW")
        XCTAssertEqual(result, .markedText)
        XCTAssertEqual(EditorReplaceEffectSnapshot(app, textView: editor), before)
        XCTAssertEqual(app.editorFindHost.replaceBatch.actionID, action)
        XCTAssertNil(app.editorFindHost.replaceAuthority.lastAuthorizationRecord)
        XCTAssertFalse(app.editorFindHost.replaceBatch.isPreparing)
        XCTAssertTrue(app.editorFindHost.replaceBatch.progress.isEmpty)
    }

    func testHostedReplaceAllFinalFenceRecheckDropsPlanBeforeUndoGroup() async throws {
        let hosted = try await makeHostedBatchWorkspace()
        let app = hosted.appState
        let state = app.editorFindHost.replaceBatch
        let editor = try hostedEditor(hosted)
        let before = EditorReplaceEffectSnapshot(app, textView: editor)
        state.willCommitForTesting = {
            let identity = ObjectIdentifier(app.currentDocument)
            app.workspaceMutationWriteFences.insert(identity)
            app.workspaceMutationWriteFences.remove(identity)
        }
        defer { state.willCommitForTesting = nil }
        let result = await app.performEditorReplaceAll(replacement: "NEW")
        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(EditorReplaceEffectSnapshot(app, textView: editor), before)
        XCTAssertFalse(editor.undoManager?.canUndo == true)
    }

    func testHostedReplaceAllFinalOwnedFieldMarkedTextRecheckRefusesBeforeWriter() async throws {
        let hosted = try await makeHostedBatchWorkspace()
        let app = hosted.appState
        let state = app.editorFindHost.replaceBatch
        let editor = try hostedEditor(hosted)
        let before = EditorReplaceEffectSnapshot(app, textView: editor)
        let writers = app.editorWriterInstallations
        var marked = false
        // Marked text can start without changing source/query/generation. Isolate
        // that condition, so only the live final owner recheck can reject it.
        app.editorFindHost.replaceMarkedTextOwners.hasMarkedTextForTesting = { marked }
        state.willCommitForTesting = { marked = true }
        defer {
            state.willCommitForTesting = nil
            app.editorFindHost.replaceMarkedTextOwners.hasMarkedTextForTesting = nil
        }
        let result = await app.performEditorReplaceAll(replacement: "NEW")
        XCTAssertEqual(result, .delivered(.refused(.markedText)))
        XCTAssertEqual(EditorReplaceEffectSnapshot(app, textView: editor), before)
        XCTAssertEqual(app.editorWriterInstallations, writers)
    }

    func testHostedReplaceAllActualQueryMarkedTextAtEntryStartsNoPlanProgressOrUndo() async throws {
        let hosted = try await makeHostedBatchWorkspace()
        let app = hosted.appState
        let editor = try hostedEditor(hosted)
        let field = try await waitForFindQueryField(in: hosted.window)
        XCTAssertTrue(hosted.window.makeFirstResponder(field))
        let fieldEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        fieldEditor.setMarkedText("hit", selectedRange: NSRange(location: 3, length: 0),
                                  replacementRange: NSRange(location: 0, length: fieldEditor.string.utf16.count))
        XCTAssertTrue(fieldEditor.hasMarkedText())
        defer { fieldEditor.unmarkText() }
        let before = EditorReplaceEffectSnapshot(app, textView: editor)
        let result = await app.performEditorReplaceAll(replacement: "NEW")
        XCTAssertEqual(result, .markedText)
        XCTAssertEqual(EditorReplaceEffectSnapshot(app, textView: editor), before)
        XCTAssertFalse(app.editorFindHost.replaceBatch.isPreparing)
        XCTAssertTrue(app.editorFindHost.replaceBatch.progress.isEmpty)
    }

    func testHostedReplaceAllCommitIsNonCancellableOnceNativeWriteStarts() async throws {
        let hosted = try await makeHostedBatchWorkspace()
        let app = hosted.appState
        let editor = try hostedEditor(hosted)
        let coordinator = try XCTUnwrap(editor.textDelegate as? MarkdownTextViewCoordinator)
        let observed = HostedBatchCommitObservation()
        let observer = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: editor, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                guard coordinator.writerAuthorizedTextMutationDepth > 0 else { return }
                observed.cancelledDuringAuthorizedWrite = true
                app.cancelEditorReplaceAll()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let revision = app.currentDocument.version
        let result = await app.performEditorReplaceAll(replacement: "NEW")
        guard case .delivered(.replaced) = result else {
            return XCTFail("the admitted native batch must complete, got \(result)")
        }
        XCTAssertTrue(observed.cancelledDuringAuthorizedWrite, "cancellation must occur inside the writer closure")
        XCTAssertEqual(app.currentDocument.text, "NEW one NEW two")
        XCTAssertEqual(app.currentDocument.version, revision + 1)
        editor.undoManager?.undo()
        XCTAssertEqual(app.currentDocument.text, "hit one hit two")
        XCTAssertFalse(editor.undoManager?.canUndo == true)
    }

    func testHostedReplaceAllMissingRecomputingAndStaleSessionNeverQueueIntent() async throws {
        let hosted = try await makeHostedBatchWorkspace()
        let app = hosted.appState
        let editor = try hostedEditor(hosted)
        let controller = app.editorFindHost.controller
        controller.clearForNoDocument()
        let beforeMissing = EditorReplaceEffectSnapshot(app, textView: editor)
        let missing = await app.performEditorReplaceAll(replacement: "NEW")
        XCTAssertEqual(missing, .ineligible(.noFindSession))
        XCTAssertEqual(EditorReplaceEffectSnapshot(app, textView: editor), beforeMissing)

        app.syncEditorFindControllerDocument()
        let hold = EditorFindMatchHold()
        controller.testMatchHold = hold
        defer {
            hold.release()
            controller.testMatchHold = nil
        }
        app.handleEditorFindQueryTextChange("hit")
        XCTAssertNil(controller.session)
        let beforeRecompute = EditorReplaceEffectSnapshot(app, textView: editor)
        let recomputing = await app.performEditorReplaceAll(replacement: "NEW")
        XCTAssertEqual(recomputing, .ineligible(.noFindSession))
        XCTAssertEqual(EditorReplaceEffectSnapshot(app, textView: editor), beforeRecompute)
        hold.release()
        try await waitUntil("refused recompute produces only a Find retained set") { controller.session != nil }
        XCTAssertEqual(app.currentDocument.text, "hit one hit two")
        XCTAssertEqual(controller.replacementScheduleCount, 0)
        XCTAssertFalse(editor.undoManager?.canUndo == true)

        // An App revision that Find has not yet observed refuses the retained set.
        app.currentDocument.replaceText("hit one hit two!", refreshStatistics: false)
        let beforeStale = EditorReplaceEffectSnapshot(app, textView: editor)
        let stale = await app.performEditorReplaceAll(replacement: "NEW")
        XCTAssertEqual(stale, .superseded)
        try assertHostedBatchDidNotWrite(hosted, since: beforeStale)
        XCTAssertFalse(app.editorFindHost.replaceBatch.isPreparing)
    }

    func testHostedReplaceAllPreparationIsOffMainAndProgressIsBoundedMonotonic() async throws {
        let hosted = try await makeHostedBatchWorkspace(source: String(repeating: "hit ", count: 250))
        let state = hosted.appState.editorFindHost.replaceBatch
        var observed: [EditorReplacePreparationProgress] = []
        state.onProgressForTesting = { observed.append($0) }
        defer { state.onProgressForTesting = nil }
        let result = await hosted.appState.performEditorReplaceAll(replacement: "NEW")
        guard case .delivered(.replaced) = result else { return XCTFail("expected batch, got \(result)") }
        XCTAssertTrue(state.lastPreparationRanOffMain)
        XCTAssertFalse(observed.isEmpty)
        XCTAssertLessThanOrEqual(observed.count, 100)
        XCTAssertEqual(Set(observed.map(\.totalMatchCount)), [250])
        let counts = observed.map(\.completedMatchCount)
        XCTAssertTrue(zip(counts, counts.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertTrue(counts.allSatisfy { (1 ... 250).contains($0) })
    }

    func testHostedReplaceAllCancellationAtSixtyFourMatchCheckpointLeavesNoMutation() async throws {
        let hosted = try await makeHostedBatchWorkspace(source: String(repeating: "hit ", count: 250))
        let (hold, task) = try await startHeldHostedBatch(hosted, atCheckpoint: { $0.plannedMatchCount == 64 })
        defer { hold.release() }
        let before = try EditorReplaceEffectSnapshot(hosted.appState, textView: hostedEditor(hosted))
        task.cancel()
        hold.release()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        try assertHostedBatchDidNotWrite(hosted, since: before)
    }

    func testHostedReplaceAllCancellationAtSixtyFiveThousandFiveHundredThirtySixCopiedUnitsLeavesNoMutation(
    ) async throws {
        let source = "hit" + String(repeating: "x", count: 70000) + "hit"
        let hosted = try await makeHostedBatchWorkspace(source: source)
        let (hold, task) = try await startHeldHostedBatch(hosted, atCheckpoint: { $0.copiedUTF16Count == 65536 })
        defer { hold.release() }
        let before = try EditorReplaceEffectSnapshot(hosted.appState, textView: hostedEditor(hosted))
        task.cancel()
        hold.release()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        try assertHostedBatchDidNotWrite(hosted, since: before)
    }
}

@MainActor
private final class HostedBatchCommitObservation {
    var cancelledDuringAuthorizedWrite = false
}
