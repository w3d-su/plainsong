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

    func testCloseDiscardsAChangedCleanReloadProposalWithoutWritingOrInstallingIt() async throws {
        let race = try await parkedObservation(externalText: "changed externally")
        let closing = await startCloseAndAssertPending(race)
        await race.harness.coordinator.unblockReads()

        guard case .closed = try await closing.value else {
            return XCTFail("A clean reload proposal must not permanently prevent close")
        }
        XCTAssertEqual(race.port.closeCalls, 1)
        XCTAssertTrue(race.entry.closed)
        XCTAssertTrue(race.entry.lease.isReleased)
        XCTAssertNil(race.entry.pendingProposal)
        XCTAssertNil(race.entry.externalToken)
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

    func testCloseRetainsACleanNewerRevisionThenObservesAgainAfterClosingEnds() async throws {
        let race = try await parkedObservation(externalText: "remote bytes")
        var readClosingPhases: [Bool] = []
        await race.harness.coordinator.setReadObserver { @MainActor in
            readClosingPhases.append(race.entry.isClosing)
        }
        race.handle.session.replaceText("temporary edit")
        race.handle.session.replaceText("baseline")
        let version = race.handle.session.version
        XCTAssertFalse(race.handle.session.isDirty)
        let closing = await startCloseAndAssertPending(race)
        await race.harness.coordinator.unblockReads()
        await waitUntil { !readClosingPhases.isEmpty }
        // The retry is allowed only after this close has conservatively retained.
        // Release it even in the negative implementation so no parked read leaks.
        XCTAssertEqual(readClosingPhases, [false])
        XCTAssertEqual(race.port.closeCalls, 0)
        XCTAssertFalse(race.entry.lease.isReleased)
        // The observer runs before the coordinator registers its continuation.
        // Do not release the gate until the retry has actually parked.
        await waitUntil { await race.harness.coordinator.blockedReads() == 2 }
        await race.harness.coordinator.setBlockReads(false)
        await race.harness.coordinator.unblockReads()
        guard case .retained = try await closing.value else {
            return XCTFail("An old read cannot prove a newer clean revision safe to close")
        }
        await waitUntil { race.entry.externalReadTasks.isEmpty }
        XCTAssertEqual(race.entry.pendingProposal?.text, "remote bytes")
        XCTAssertEqual(race.entry.pendingProposal?.capturedRevision.version, version)
        XCTAssertEqual(race.handle.session.text, "baseline")
        XCTAssertEqual(race.handle.session.version, version)
        XCTAssertFalse(race.handle.session.isDirty)
        XCTAssertFalse(race.entry.closed)
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
