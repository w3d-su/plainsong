import Foundation
@testable import PlainsongIOS
import WorkspaceCore
import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSImageInsertionTerminalTests: XCTestCase {
    func testCancelBeforeStageDoesNotCallWriter() async throws {
        let harness = ImageInsertionHarness()
        let context = try harness.capture()
        harness.controller.cancel(operationID: context.operationID)
        await assertCancelled(harness.insert(context))
        XCTAssertEqual(harness.writer.calls, [])
        harness.assertSourceUntouched()
    }

    func testCancelDuringStageRollsBackOnce() async throws {
        let harness = ImageInsertionHarness()
        let context = try harness.capture()
        harness.writer.pauseStage = true
        let task = Task { await harness.insert(context) }
        await harness.writer.stageEntered.wait()
        harness.controller.cancel(operationID: context.operationID)
        harness.controller.cancel(operationID: context.operationID)
        harness.writer.stageRelease.signal()
        await assertCancelled(task.value)
        harness.assertSourceUntouched()
        XCTAssertEqual(harness.writer.rollbackCount, 1)
        XCTAssertEqual(harness.writer.commitCount, 0)
        XCTAssertEqual(harness.probe.events.filter { $0 == "rollback" }.count, 1)
    }

    func testPickerDismissalDoesNotSaveOrEdit() throws {
        let harness = ImageInsertionHarness()
        let session = harness.session()
        XCTAssertNotNil(try XCTUnwrap(session.preparePicker()))
        session.pickerDismissed()
        session.pickerDismissed()
        XCTAssertEqual(session.phase, .cancelled)
        XCTAssertEqual(harness.writer.calls, [])
        harness.assertSourceUntouched()
    }

    func testTeardownDuringStageRollsBackOnce() async throws {
        let harness = ImageInsertionHarness()
        let session = harness.session()
        let prepared = try XCTUnwrap(session.preparePicker())
        let context = try XCTUnwrap(session.beginImport())
        XCTAssertEqual(context.operationID, prepared.operationID)
        harness.writer.pauseStage = true
        let task = Task {
            await session.finishImport(.success(Self.payload), context: context)
        }
        await harness.writer.stageEntered.wait()
        session.teardown()
        session.teardown()
        harness.writer.stageRelease.signal()
        await task.value
        harness.assertSourceUntouched()
        XCTAssertEqual(harness.writer.rollbackCount, 1)
        XCTAssertEqual(harness.writer.commitCount, 0)
        XCTAssertEqual(session.phase, .cancelled)
    }

    func testDuplicateFinishImportStagesOnce() async throws {
        let harness = ImageInsertionHarness()
        let session = harness.session()
        let prepared = try XCTUnwrap(session.preparePicker())
        let context = try XCTUnwrap(session.beginImport())
        harness.writer.pauseStage = true
        let first = Task { await session.finishImport(.success(Self.payload), context: context) }
        await harness.writer.stageEntered.wait()
        XCTAssertNil(session.beginImport())
        await session.finishImport(.success(Self.payload), context: prepared)
        harness.writer.stageRelease.signal()
        await first.value
        XCTAssertEqual(harness.writer.stagedRequests.count, 1)
        XCTAssertEqual(harness.writer.commitCount, 1)
        XCTAssertEqual(harness.writer.rollbackCount, 0)
        guard case .inserted = session.phase else {
            return XCTFail("expected inserted phase, got \(session.phase)")
        }
    }

    func testDuplicateInsertDoesNotCommitTwice() async throws {
        let harness = ImageInsertionHarness()
        let context = try harness.capture()
        harness.writer.pauseStage = true
        let first = Task { await harness.insert(context) }
        await harness.writer.stageEntered.wait()
        await assertCancelled(harness.insert(context))
        harness.writer.stageRelease.signal()
        _ = await assertInserted(first.value)
        XCTAssertEqual(harness.writer.stagedRequests.count, 1)
        XCTAssertEqual(harness.writer.commitCount, 1)
        XCTAssertEqual(harness.writer.rollbackCount, 0)
    }

    func testApplyRejectionRollsBackAndKeepsSource() async throws {
        let harness = ImageInsertionHarness()
        harness.editor.nextRefusal = .invalidRange
        let context = try harness.capture()
        await assertRefused(harness.insert(context), .invalidRange)
        XCTAssertEqual(harness.editor.text, harness.originalText)
        XCTAssertEqual(harness.editor.undoInvocations, 0)
        XCTAssertEqual(harness.writer.rollbackCount, 1)
        XCTAssertEqual(harness.writer.commitCount, 0)
        XCTAssertEqual(harness.writer.removedTokens, [harness.writer.ownershipToken])
        XCTAssertEqual(harness.probe.events, ["stage", "validate", "apply", "rollback"])
    }

    func testConflictRefusalRollsBackWithoutSourceChange() async throws {
        let harness = ImageInsertionHarness()
        harness.editor.nextRefusal = .busy
        let context = try harness.capture()
        await assertRefused(harness.insert(context), .busy)
        XCTAssertEqual(harness.editor.text, harness.originalText)
        XCTAssertEqual(harness.writer.rollbackCount, 1)
        XCTAssertEqual(harness.writer.commitCount, 0)
        XCTAssertEqual(harness.probe.events, ["stage", "validate", "apply", "rollback"])
    }

    func testRollbackRetentionDoesNotDelete() async throws {
        let harness = ImageInsertionHarness()
        harness.writer.forceRetainRollback = true
        harness.editor.nextRefusal = .readOnly
        let context = try harness.capture()
        let outcome = await harness.insert(context)
        guard case let .retained(receipt) = outcome else {
            return XCTFail("expected retained, got \(String(describing: outcome))")
        }
        XCTAssertEqual(receipt.targetLocation.relativePath, "notes/assets/photo-2.png")
        XCTAssertEqual(harness.writer.removedTokens, [])
        XCTAssertEqual(harness.writer.rollbackCount, 1)
        XCTAssertEqual(harness.writer.commitCount, 0)
        XCTAssertEqual(harness.editor.text, harness.originalText)
        let message = IOSImageInsertionMessages.recovery(relativePath: receipt.targetLocation.relativePath)
        XCTAssertTrue(message.contains("notes/assets/photo-2.png"))
        XCTAssertTrue(message.contains("not deleted"))
        XCTAssertFalse(message.contains("file:"))
        XCTAssertFalse(message.contains("/staged"))
    }

    func testStageRetentionDoesNotRollback() async throws {
        let harness = ImageInsertionHarness()
        let context = try harness.capture()
        let receipt = IOSAssetRecoveryReceipt(
            operationID: context.operationID,
            targetLocation: harness.destination,
            ownershipToken: harness.writer.ownershipToken,
            reason: .coordinationFailed
        )
        harness.writer.stageFailure = IOSAssetStageFailure.retained(receipt)
        let outcome = await harness.insert(context)
        guard case let .retained(actual) = outcome else {
            return XCTFail("expected retained, got \(String(describing: outcome))")
        }
        XCTAssertEqual(actual.ownershipToken, receipt.ownershipToken)
        XCTAssertEqual(harness.writer.rollbackCount, 0)
        XCTAssertEqual(harness.writer.commitCount, 0)
        harness.assertSourceUntouched()
    }

    func testMismatchedOperationDoesNotDelete() async throws {
        let harness = ImageInsertionHarness()
        harness.writer.operationIDOverride = UUID()
        let context = try harness.capture()
        let outcome = await harness.insert(context)
        guard case .retained = outcome else {
            return XCTFail("expected retained, got \(String(describing: outcome))")
        }
        XCTAssertEqual(harness.writer.removedTokens, [])
        XCTAssertEqual(harness.writer.rollbackCount, 1)
        XCTAssertEqual(harness.writer.commitCount, 0)
        harness.assertSourceUntouched()
    }

    func testProviderStageFailuresDoNotMutateSource() async throws {
        let reasons: [IOSWorkspaceFailure] = [.downloading, .offline, .readOnly, .permissionDenied, .coordinationFailed]
        for reason in reasons {
            let harness = ImageInsertionHarness()
            harness.writer.stageFailure = IOSAssetStageFailure.failed(reason)
            let context = try harness.capture()
            await assertFailed(harness.insert(context), reason)
            XCTAssertEqual(harness.writer.rollbackCount, 0)
            XCTAssertEqual(harness.writer.commitCount, 0)
            harness.assertSourceUntouched()
        }
    }

    func testCancellationErrorFromStageDoesNotRollback() async throws {
        let harness = ImageInsertionHarness()
        harness.writer.stageFailure = CancellationError()
        let context = try harness.capture()
        await assertCancelled(harness.insert(context))
        XCTAssertEqual(harness.writer.rollbackCount, 0)
        harness.assertSourceUntouched()
    }

    func testLoadFailureDoesNotStage() async throws {
        let harness = ImageInsertionHarness()
        let session = harness.session()
        let context = try XCTUnwrap(session.beginImport(after: session.preparePicker()))
        await session.finishImport(.failure(.unavailable), context: context)
        XCTAssertEqual(session.phase, .failed(.unavailable))
        XCTAssertEqual(harness.writer.calls, [])
        harness.assertSourceUntouched()
    }

    func testUncapturedContextDoesNotStage() async throws {
        let harness = ImageInsertionHarness()
        let snapshot = try XCTUnwrap(harness.editor.captureSnapshot())
        let forged = IOSImageInsertionContext(
            operationID: UUID(),
            editor: snapshot,
            destination: harness.destination,
            grant: harness.grant
        )
        await assertCancelled(harness.insert(forged))
        XCTAssertEqual(harness.writer.calls, [])
        harness.assertSourceUntouched()
    }

    private static let payload = IOSImagePickedPayload(
        bytes: ImageBytes.png,
        contentType: "image/png",
        preferredFilename: "from-photos.png"
    )
}

private extension IOSImageInsertionSession {
    func beginImport(after context: IOSImageInsertionContext?) -> IOSImageInsertionContext? {
        guard context != nil else { return nil }
        return beginImport()
    }
}
