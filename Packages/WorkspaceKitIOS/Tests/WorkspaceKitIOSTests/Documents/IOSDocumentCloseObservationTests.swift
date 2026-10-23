import Foundation
import MarkdownCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSDocumentCloseObservationTests: XCTestCase {
    func testCloseWaitsForAnAlreadyIssuedSelfNoticeReadBeforeClosingTheProvider() async throws {
        let race = try await parkedObservation(externalText: "baseline")
        let closing = await startCloseAndAssertPending(race)
        await race.harness.coordinator.unblockReads()

        guard case .closed = try await closing.value else {
            return XCTFail("A verified clean self-notice must permit the original close")
        }
        XCTAssertEqual(race.port.closeCalls, 1)
        XCTAssertTrue(race.entry.closed)
        XCTAssertTrue(race.entry.lease.isReleased)
        XCTAssertNil(race.entry.externalToken)
        XCTAssertNil(race.entry.pendingProposal)
        XCTAssertEqual(race.handle.session.text, "baseline")
        XCTAssertTrue(race.port.written.isEmpty)
    }

    func testCloseStillRetainsAChangedCleanReadAsAnUnacknowledgedReloadProposal() async throws {
        let race = try await parkedObservation(externalText: "changed externally")
        let closing = await startCloseAndAssertPending(race)
        await race.harness.coordinator.unblockReads()

        guard case .retained = try await closing.value else {
            return XCTFail("Waiting for external bytes must not acknowledge a changed-source proposal")
        }
        XCTAssertEqual(race.port.closeCalls, 0)
        XCTAssertFalse(race.entry.closed)
        XCTAssertFalse(race.entry.lease.isReleased)
        XCTAssertEqual(race.entry.pendingProposal?.text, "changed externally")
        XCTAssertEqual(race.handle.session.text, "baseline")
        XCTAssertFalse(race.handle.session.isDirty)
        XCTAssertTrue(race.port.written.isEmpty)
    }

    func testCloseStillRetainsDirtySourceAndRecoveryAfterTheParkedReadConflicts() async throws {
        let race = try await parkedObservation(externalText: "remote bytes", draft: "local unsaved source")
        let closing = await startCloseAndAssertPending(race)
        await race.harness.coordinator.unblockReads()

        guard case let .retained(receipt) = try await closing.value else {
            return XCTFail("An external conflict cannot retire the local writer")
        }
        XCTAssertNotNil(receipt)
        XCTAssertEqual(race.port.closeCalls, 0)
        XCTAssertFalse(race.entry.closed)
        XCTAssertFalse(race.entry.lease.isReleased)
        XCTAssertTrue(race.entry.fenced)
        XCTAssertEqual(race.handle.session.text, "local unsaved source")
        XCTAssertTrue(race.handle.session.isDirty)
        XCTAssertTrue(race.port.written.isEmpty)
        let recovery = await race.harness.recovery.list()
        XCTAssertTrue(recovery.records.contains { $0.source == "local unsaved source" })
    }

    func testCloseDoesNotEraseAGenerationBarrierWhileTheExternalReadDrains() async throws {
        let race = try await parkedObservation(externalText: "baseline")
        let closing = await startCloseAndAssertPending(race)
        race.entry.accessGeneration += 1
        let changedGeneration = race.entry.accessGeneration
        await race.harness.coordinator.unblockReads()

        guard case .retained = try await closing.value else {
            return XCTFail("An obsolete read cannot clear the newer generation's barrier")
        }
        XCTAssertEqual(race.port.closeCalls, 0)
        XCTAssertFalse(race.entry.closed)
        XCTAssertFalse(race.entry.lease.isReleased)
        XCTAssertNotNil(race.entry.externalToken)
        XCTAssertEqual(race.entry.accessGeneration, changedGeneration)
        XCTAssertTrue(race.port.written.isEmpty)
    }

    private func parkedObservation(externalText: String, draft: String? = nil) async throws -> ParkedObservation {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "baseline")
        let port = try XCTUnwrap(harness.port(for: handle))
        let entry = try XCTUnwrap(harness.store.byIdentity[handle.identity])
        if let draft {
            handle.session.replaceText(draft)
        }
        await harness.coordinator.setBytes(Data(externalText.utf8))
        await harness.coordinator.setBlockReads(true)
        port.emit(.externalChange)
        await waitUntil { await harness.coordinator.blockedReads() == 1 }
        XCTAssertNotNil(entry.externalToken)
        return ParkedObservation(harness: harness, handle: handle, port: port, entry: entry)
    }

    private func startCloseAndAssertPending(_ race: ParkedObservation)
        async -> Task<IOSDocumentCloseOutcome, Error>
    {
        var finished = false
        let closing = Task { @MainActor in
            defer { finished = true }
            return try await race.harness.store.close(race.handle.identity)
        }
        await waitUntil { race.entry.isClosing || finished }
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(finished, "The issued observation is still explicitly parked")
        XCTAssertEqual(race.port.closeCalls, 0, "The provider must remain open until its read finishes")
        return closing
    }
}

@MainActor
private struct ParkedObservation {
    let harness: DocumentIOHarness
    let handle: IOSDocumentHandle
    let port: ScriptedFilePort
    let entry: IOSDocumentEntry
}
