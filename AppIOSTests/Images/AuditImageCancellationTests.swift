import Foundation
@testable import PlainsongIOS
import WorkspaceKitIOS
import XCTest

/// Audit-only regression probe. Production sources are unmodified lane 09.
final class AuditImageCancellationTests: XCTestCase {
    @MainActor
    func testTaskCancellationDuringStageRollsBack() async throws {
        let h = ImageInsertionHarness()
        let context = try h.capture()
        h.writer.pauseStage = true
        let task = Task { await h.insert(context) }
        await h.writer.stageEntered.wait()
        task.cancel()
        h.writer.stageRelease.signal()
        let outcome = await task.value
        assertCancelled(outcome)
        h.assertSourceUntouched()
        XCTAssertEqual(h.writer.rollbackCount, 1)
        XCTAssertEqual(h.writer.commitCount, 0)
        XCTAssertFalse(h.probe.events.contains("apply"))
    }
}
