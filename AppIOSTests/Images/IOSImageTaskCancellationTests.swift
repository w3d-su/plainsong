import Foundation
@testable import PlainsongIOS
import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSImageTaskCancellationTests: XCTestCase {
    func testCancelledCallerDoesNotBeginPersistence() async throws {
        let harness = ImageInsertionHarness()
        let context = try harness.capture()
        let release = AsyncSignal()
        let task = Task {
            await release.wait()
            return await harness.insert(context)
        }
        task.cancel()
        release.signal()
        await assertCancelled(task.value)
        XCTAssertEqual(harness.writer.calls, [])
        harness.assertSourceUntouched()
    }

    func testTaskCancelDuringNormalizationNeverStages() async throws {
        let transcoder = BlockingImageTranscoder()
        let harness = ImageInsertionHarness(transcoder: transcoder)
        let context = try harness.capture()
        let task = Task {
            await harness.insert(context, bytes: ImageBytes.heic(), contentType: "image/heic", filename: "photo.heic")
        }
        await transcoder.entered.wait()
        task.cancel()
        transcoder.release.signal()
        await assertCancelled(task.value)
        XCTAssertEqual(harness.writer.calls, [])
        harness.assertSourceUntouched()
    }

    func testTaskCancelDuringStageDrainsOneOwnedRollback() async throws {
        let harness = ImageInsertionHarness()
        let context = try harness.capture()
        harness.writer.pauseStage = true
        let task = Task { await harness.insert(context) }
        await harness.writer.stageEntered.wait()
        task.cancel()
        task.cancel()
        harness.writer.stageRelease.signal()
        await assertCancelled(task.value)
        harness.assertSourceUntouched()
        XCTAssertEqual(harness.writer.calls, ["stage", "rollback"])
        XCTAssertEqual(harness.writer.rollbackCount, 1)
        XCTAssertEqual(harness.writer.removedTokens, [harness.writer.ownershipToken])
        XCTAssertFalse(harness.writer.rollbackObservedCancellation)
    }

    func testTaskCancelDuringValidationDrainsWithoutApply() async throws {
        let harness = ImageInsertionHarness()
        let context = try harness.capture()
        harness.writer.pauseValidate = true
        let task = Task { await harness.insert(context) }
        await harness.writer.validateEntered.wait()
        task.cancel()
        harness.writer.validateRelease.signal()
        await assertCancelled(task.value)
        harness.assertSourceUntouched()
        XCTAssertEqual(harness.writer.calls, ["stage", "validate", "rollback"])
        XCTAssertEqual(harness.writer.rollbackCount, 1)
        XCTAssertEqual(harness.writer.removedTokens, [harness.writer.ownershipToken])
        XCTAssertFalse(harness.writer.rollbackObservedCancellation)
    }

    func testCancellationDuringFinalSnapshotNeverApplies() async throws {
        let harness = ImageInsertionHarness()
        let context = try harness.capture()
        harness.editor.beforeSnapshot = { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { await harness.insert(context) }
        await assertCancelled(task.value)
        harness.assertSourceUntouched()
        XCTAssertEqual(harness.writer.calls, ["stage", "validate", "rollback"])
        XCTAssertEqual(harness.writer.rollbackCount, 1)
        XCTAssertFalse(harness.writer.rollbackObservedCancellation)
    }

    func testCancelledRollbackRetentionKeepsReceiptAndOwnedIdentity() async throws {
        let harness = ImageInsertionHarness()
        let context = try harness.capture()
        harness.writer.pauseStage = true
        harness.writer.forceRetainRollback = true
        let task = Task { await harness.insert(context) }
        await harness.writer.stageEntered.wait()
        task.cancel()
        harness.writer.stageRelease.signal()
        let outcome = await task.value
        guard case let .retained(receipt) = outcome else {
            return XCTFail("expected retained receipt, got \(outcome)")
        }
        XCTAssertEqual(receipt.operationID, context.operationID)
        XCTAssertEqual(receipt.ownershipToken, harness.writer.ownershipToken)
        XCTAssertEqual(harness.writer.rollbackCount, 1)
        XCTAssertEqual(harness.writer.removedTokens, [])
        XCTAssertFalse(harness.writer.rollbackObservedCancellation)
        harness.assertSourceUntouched()
    }

    func testTaskCancellationInsideAcceptedApplyStillCommitsOnce() async throws {
        let harness = ImageInsertionHarness()
        let context = try harness.capture()
        harness.editor.beforeApply = { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { await harness.insert(context) }
        _ = await assertInserted(task.value)
        XCTAssertEqual(harness.probe.events, ["stage", "validate", "apply", "commit"])
        XCTAssertEqual(harness.writer.calls, ["stage", "validate", "commit"])
        XCTAssertEqual(harness.editor.submitted.count, 1)
        XCTAssertEqual(harness.writer.commitCount, 1)
        XCTAssertEqual(harness.writer.rollbackCount, 0)
        XCTAssertEqual(harness.writer.removedTokens, [])
        XCTAssertFalse(harness.writer.commitObservedCancellation)
        XCTAssertNotEqual(harness.editor.text, harness.originalText)
    }
}

private final class BlockingImageTranscoder: IOSImageRasterTranscoding, @unchecked Sendable {
    let entered = AsyncSignal()
    let release = DispatchSemaphore(value: 0)

    func pngData(fromHEIC _: Data) -> Data? {
        entered.signal()
        release.wait()
        return ImageBytes.png
    }
}
