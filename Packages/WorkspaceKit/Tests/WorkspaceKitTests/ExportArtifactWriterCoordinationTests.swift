import Darwin
import Foundation
@testable import WorkspaceKit
import XCTest

/// Holds real coordinators used across threads by one test; `NSFileCoordinator` is thread-safe.
final class CoordinatorBox: @unchecked Sendable {
    let writer = NSFileCoordinator(filePresenter: nil)
    let other = NSFileCoordinator(filePresenter: nil)
    let held = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
}

/// Q1's real `NSFileCoordinator` branches. Nothing about the coordinator is mocked; the only
/// seam supplies the export's own coordinator instance so that it can be cancelled.
extension ExportArtifactWriterTests {
    /// The export's coordinator is already cancelled: the real coordinator returns
    /// `NSUserCancelledError` without running the accessor (observed on macOS 27.0), so nothing is
    /// published and staging is cleaned up. Deterministic, with no competing writer or timing.
    func testCancelledCoordinationPublishesNothing() throws {
        let fixture = try makeExportFixture(originalText: "original")
        let approved = try XCTUnwrap(fixture.originalIdentity)
        let destination = fixture.destination
        let box = CoordinatorBox()
        box.writer.cancel()
        let probe = ExportBoundaryProbe()
        let hooks = probe.hooks(isUbiquitous: { _ in true }, fileCoordinator: { box.writer })

        let outcome = export(
            "writer bytes",
            to: destination,
            disposition: .replaceConfirmed(approved),
            probe: probe,
            hooks: hooks
        )

        XCTAssertEqual(outcome, .notCommitted(.coordinationFailed))
        XCTAssertTrue(probe.calls(at: .publish).isEmpty, "the accessor never ran")
        XCTAssertEqual(probe.calls(at: .inspectLeaf).count, 1, "only the preflight proof ran; no re-proof")
        XCTAssertFalse(exists(probe.stagedPath))
        XCTAssertFalse(exists(probe.stagingDirectoryPath))
        XCTAssertEqual(try text(at: destination), "original")
        XCTAssertEqual(try identity(at: destination), approved)
    }

    /// Another coordinated writer moves the leaf while the export waits; the real coordinator
    /// hands the accessor the moved URL, which is not byte-for-byte the coordinated URL, so the
    /// export publishes nothing and the moved original is untouched.
    func testCoordinatedMoveWhileWaitingIsRefusedByTheAccessorURL() throws {
        let fixture = try makeExportFixture(originalText: "original")
        let approved = try XCTUnwrap(fixture.originalIdentity)
        let destination = fixture.destination
        let movedURL = fixture.directory.appendingPathComponent("moved.html", isDirectory: false)
        let box = CoordinatorBox()
        let probe = ExportBoundaryProbe(races: [.coordinate: {
            Thread.detachNewThread {
                var error: NSError?
                box.other.coordinate(
                    writingItemAt: destination,
                    options: .forMoving,
                    writingItemAt: movedURL,
                    options: .forReplacing,
                    error: &error
                ) { source, target in
                    box.held.signal()
                    box.release.wait()
                    try? FileManager.default.moveItem(at: source, to: target)
                    box.other.item(at: source, didMoveTo: target)
                }
            }
            box.held.wait()
            // There is no observable "the export is now waiting" signal: a file presenter is
            // messaged for the waiting writer only after the holder releases (measured), so the
            // mover releases after a margin. Released too early, the move lands before the export
            // coordinates and the re-proof (not the accessor URL) refuses; the assertions below
            // would then fail visibly rather than pass vacuously.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { box.release.signal() }
        }])
        let hooks = probe.hooks(isUbiquitous: { _ in true })

        let outcome = export(
            "writer bytes",
            to: destination,
            disposition: .replaceConfirmed(approved),
            probe: probe,
            hooks: hooks
        )

        XCTAssertEqual(outcome, .notCommitted(.namespaceChanged))
        XCTAssertTrue(probe.calls(at: .publish).isEmpty, "the moved leaf is never published over")
        XCTAssertEqual(
            probe.calls(at: .inspectLeaf).count,
            1,
            "refused by the accessor URL itself, before the in-accessor re-proof"
        )
        XCTAssertFalse(exists(probe.stagingDirectoryPath))
        XCTAssertFalse(exists(fixture.destinationPath))
        XCTAssertEqual(try text(at: movedURL), "original")
        XCTAssertEqual(try identity(at: movedURL), approved)
    }
}
