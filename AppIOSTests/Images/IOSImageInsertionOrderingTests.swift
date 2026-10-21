import MarkdownCore
@testable import PlainsongIOS
import XCTest

@MainActor
final class IOSImageInsertionOrderingTests: XCTestCase {
    func testPersistenceAndValidateFinishBeforeTheSourceEdit() async throws {
        let harness = ImageInsertionHarness()
        let context = try harness.capture()
        harness.writer.pauseStage = true
        let task = Task { await harness.insert(context) }
        await harness.writer.stageEntered.wait()
        XCTAssertEqual(harness.probe.events, ["stage"])
        XCTAssertEqual(harness.editor.submitted.count, 0)
        harness.assertSourceUntouched()

        harness.writer.stageRelease.signal()
        let outcome = await task.value
        let revision = assertInserted(outcome)
        XCTAssertEqual(revision, harness.editor.revision)
        XCTAssertEqual(harness.probe.events, ["stage", "validate", "apply", "commit"])
        XCTAssertEqual(harness.writer.commitCount, 1)
        XCTAssertEqual(harness.writer.rollbackCount, 0)
    }

    func testAcceptedInsertionUsesTheSavedRelativePath() async throws {
        let harness = ImageInsertionHarness()
        let context = try harness.capture()
        let outcome = await harness.insert(context)
        _ = assertInserted(outcome)

        let edit = try XCTUnwrap(harness.editor.submitted.first)
        let markdown = SmartPaste.imageInsertion(relativePath: "assets/photo-2.png")
        XCTAssertEqual(edit.bindingID, context.editor.bindingID)
        XCTAssertEqual(edit.baseRevision, context.editor.revision)
        XCTAssertEqual(edit.selectionGeneration, context.editor.selectionGeneration)
        XCTAssertEqual(edit.accessGeneration, context.editor.accessGeneration)
        XCTAssertEqual(edit.undoActionName, IOSImageInsertionGuard.undoActionName)
        XCTAssertEqual(edit.result.replacementRange, context.editor.selection)
        XCTAssertEqual(edit.result.replacementString, markdown)
        XCTAssertNotEqual(
            edit.result.replacementString,
            SmartPaste.imageInsertion(relativePath: "notes/assets/photo-2.png")
        )
        XCTAssertFalse(edit.result.replacementString.contains("from-photos"))
        XCTAssertFalse(edit.result.replacementString.contains("/staged"))
        XCTAssertFalse(edit.result.replacementString.contains("file:"))
        let insertedLength = (markdown as NSString).length
        XCTAssertEqual(
            edit.result.newSelection,
            NSRange(location: context.editor.selection.location + insertedLength, length: 0)
        )
        XCTAssertEqual(harness.editor.text, "Hello" + markdown)

        let request = try XCTUnwrap(harness.writer.stagedRequests.first)
        XCTAssertEqual(request.operationID, context.operationID)
        XCTAssertEqual(request.bytes, ImageBytes.png)
        XCTAssertEqual(request.contentType, "image/png")
        XCTAssertEqual(request.preferredFilename, "from-photos.png")
        XCTAssertEqual(request.destination.relativePath, "notes/post.md")
        XCTAssertEqual(request.destination.workspaceID, context.destination.workspaceID)
        XCTAssertNotEqual(context.destination.fileURL.path, context.grant.rootURL.path)
    }

    func testUndoAndRedoKeepTheCommittedImage() async throws {
        let harness = ImageInsertionHarness()
        let context = try harness.capture()
        _ = await assertInserted(harness.insert(context))
        let inserted = harness.editor.text

        harness.editor.undo()
        XCTAssertEqual(harness.editor.text, harness.originalText)
        harness.editor.redo()
        XCTAssertEqual(harness.editor.text, inserted)
        XCTAssertEqual(harness.writer.commitCount, 1)
        XCTAssertEqual(harness.writer.rollbackCount, 0)
        XCTAssertEqual(harness.writer.removedTokens, [])
    }

    func testRetainedCommitAfterAcceptIsStillInserted() async throws {
        let harness = ImageInsertionHarness()
        harness.writer.forceRetainCommit = true
        let context = try harness.capture()
        let outcome = await harness.insert(context)
        guard case let .inserted(_, ownership) = outcome else {
            return XCTFail("expected inserted, got \(String(describing: outcome))")
        }
        guard case .retained = ownership else {
            return XCTFail("expected retained ownership")
        }
        XCTAssertEqual(harness.writer.commitCount, 1)
        XCTAssertEqual(harness.writer.rollbackCount, 0)
        XCTAssertNotEqual(harness.editor.text, harness.originalText)
    }

    func testCancelObservedInsideApplyStillCommits() async throws {
        let harness = ImageInsertionHarness()
        let context = try harness.capture()
        harness.editor.beforeApply = { harness.controller.cancel(operationID: context.operationID) }
        _ = await assertInserted(harness.insert(context))
        XCTAssertEqual(harness.writer.commitCount, 1)
        XCTAssertEqual(harness.writer.rollbackCount, 0)
        XCTAssertNotEqual(harness.editor.text, harness.originalText)
        XCTAssertEqual(harness.probe.events, ["stage", "validate", "apply", "commit"])
    }
}
