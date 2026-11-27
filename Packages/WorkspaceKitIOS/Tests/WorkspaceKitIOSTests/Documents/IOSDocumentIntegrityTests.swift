import MarkdownCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSDocumentIntegrityTests: XCTestCase {
    func testChangesDuringOpenAndItsReadbackBecomeTheInitialBaseline() async throws {
        let harness = DocumentIOHarness()
        harness.ports.blockOpen = true
        await harness.coordinator.setBlockReads(true)
        let opening = Task { try await harness.openNote(text: "old") }
        await waitUntil { harness.ports.created.first?.parked == 1 }
        let port = try XCTUnwrap(harness.ports.created.first)
        port.emit(.externalChange)
        port.releaseOne()
        await waitUntil { await harness.coordinator.blockedReads() == 1 }
        let joined = Task { try await harness.openNote(text: "old") }
        await waitUntil { harness.store.byIdentity.values.first?.openWaiters.count == 1 }
        port.emit(.externalChange)
        await harness.coordinator.setBytes(Data("newest".utf8))
        await harness.coordinator.setBlockReads(false)
        await harness.coordinator.unblockReads()
        let handle = try await opening.value
        let joinedHandle = try await joined.value
        XCTAssertTrue(joinedHandle.session === handle.session)
        let reads = await harness.coordinator.completedReads()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(handle.session.text, "newest")
        XCTAssertFalse(handle.session.isDirty)
        XCTAssertEqual(harness.store.state(for: handle.identity)?.canWrite, true)
        XCTAssertTrue(port.written.isEmpty)
    }

    func testFailedReadbackDuringOpenKeepsOriginalReadOnly() async throws {
        let harness = DocumentIOHarness()
        harness.ports.blockOpen = true
        await harness.coordinator.setReadFailure(.offline)
        let opening = Task { try await harness.openNote(text: "old") }
        await waitUntil { harness.ports.created.first?.parked == 1 }
        let port = try XCTUnwrap(harness.ports.created.first)
        port.emit(.externalChange)
        port.releaseOne()
        let handle = try await opening.value
        XCTAssertEqual(handle.session.text, "old")
        XCTAssertEqual(harness.store.state(for: handle.identity)?.canWrite, false)
        XCTAssertTrue(port.written.isEmpty)

        await harness.coordinator.setReadFailure(nil)
        await harness.coordinator.setBytes(Data("current".utf8))
        port.emit(.writePermissionChanged(true))
        await waitUntil { harness.store.byIdentity[handle.identity]?.pendingProposal != nil }
        let proposal = try XCTUnwrap(harness.store.byIdentity[handle.identity]?.pendingProposal)
        XCTAssertEqual(proposal.text, "current")
        XCTAssertEqual(harness.store.state(for: handle.identity)?.canWrite, false)
        handle.session.replaceText(proposal.text)
        let revision = IOSDocumentRevision(documentID: handle.identity, version: handle.session.version)
        harness.store.acknowledgeExternalReload(operationID: proposal.operationID, outcome: .installed(revision))
        XCTAssertEqual(harness.store.state(for: handle.identity)?.canWrite, true)
        XCTAssertFalse(handle.session.isDirty)
    }

    func testNoticeQueuedDuringFailedOpenReadbackRetriesAfterPublishing() async throws {
        let harness = DocumentIOHarness()
        harness.ports.blockOpen = true
        await harness.coordinator.setBlockReads(true)
        await harness.coordinator.setReadFailure(.offline)
        let opening = Task { try await harness.openNote(text: "old") }
        await waitUntil { harness.ports.created.first?.parked == 1 }
        let port = try XCTUnwrap(harness.ports.created.first)
        port.emit(.externalChange)
        port.releaseOne()
        await waitUntil { await harness.coordinator.blockedReads() == 1 }
        port.emit(.externalChange)
        await harness.coordinator.unblockReads()
        let handle = try await opening.value
        XCTAssertEqual(handle.session.text, "old")
        XCTAssertEqual(harness.store.state(for: handle.identity)?.canWrite, false)

        await waitUntil { await harness.coordinator.blockedReads() == 2 }
        await harness.coordinator.setReadFailure(nil)
        await harness.coordinator.setBytes(Data("current".utf8))
        await harness.coordinator.setBlockReads(false)
        await harness.coordinator.unblockReads()
        await waitUntil { harness.store.byIdentity[handle.identity]?.pendingProposal != nil }
        let proposal = try XCTUnwrap(harness.store.byIdentity[handle.identity]?.pendingProposal)
        XCTAssertEqual(proposal.text, "current")
        let completedReads = await harness.coordinator.completedReads()
        XCTAssertEqual(completedReads, 1)
    }

    func testClosingAnUneditedFailedOpenSnapshotDoesNotCreateRecovery() async throws {
        let harness = DocumentIOHarness()
        harness.ports.blockOpen = true
        await harness.coordinator.setReadFailure(.offline)
        let opening = Task { try await harness.openNote(text: "cached") }
        await waitUntil { harness.ports.created.first?.parked == 1 }
        let port = try XCTUnwrap(harness.ports.created.first)
        port.emit(.externalChange)
        port.releaseOne()
        let handle = try await opening.value
        guard case .closed = try await harness.store.close(handle.identity) else {
            return XCTFail("closing an untouched opening snapshot must release its writer")
        }
        let drafts = await harness.store.recoveryList()
        XCTAssertTrue(drafts.records.isEmpty)
        XCTAssertTrue(port.written.isEmpty)
    }

    func testClosingAnUneditedFailedCreateSnapshotDoesNotCreateRecovery() async throws {
        let harness = DocumentIOHarness()
        let (handle, port) = try await createNoteWithFailedReadback(harness, text: "restored draft")
        guard case .closed = try await harness.store.close(handle.identity) else {
            return XCTFail("closing an untouched created snapshot must release its writer")
        }
        let drafts = await harness.store.recoveryList()
        XCTAssertTrue(drafts.records.isEmpty)
        XCTAssertEqual(port.closeCalls, 1)
        XCTAssertEqual(port.written, [Data("restored draft".utf8)])
    }

    func testCreatedSnapshotRegainsWritesWhenALaterReadMatchesIt() async throws {
        let harness = DocumentIOHarness()
        let (handle, port) = try await createNoteWithFailedReadback(harness, text: "draft")
        await harness.coordinator.setReadFailure(nil)
        await harness.coordinator.setBytes(Data("draft".utf8))
        port.emit(.externalChange)
        await waitUntil { harness.store.state(for: handle.identity)?.canWrite == true }
        XCTAssertFalse(handle.session.isDirty)
        XCTAssertNil(harness.store.byIdentity[handle.identity]?.pendingProposal)
    }

    /// Creates `Note.md` while the provider reports a change that cannot be read back.
    private func createNoteWithFailedReadback(
        _ harness: DocumentIOHarness, text: String
    ) async throws -> (IOSDocumentHandle, ScriptedFilePort) {
        harness.ports.blockCreate = true
        await harness.coordinator.setReadFailure(.offline)
        let location = harness.location(relativePath: "Note.md", generation: 1)
        let lease = harness.directoryLease(generation: 1)
        let creating = Task { try await harness.store.create(at: location, initialText: text, lease: lease) }
        await waitUntil { harness.ports.created.first?.parked == 1 }
        let port = try XCTUnwrap(harness.ports.created.first)
        port.emit(.externalChange)
        port.releaseOne()
        let handle = try await creating.value
        XCTAssertEqual(handle.session.text, text)
        XCTAssertEqual(harness.store.state(for: handle.identity)?.canWrite, false)
        return (handle, port)
    }

    func testConflictReloadChecksLivePermissionAfterIndeterminateSave() async throws {
        for writable in [true, false] {
            let harness = DocumentIOHarness()
            let handle = try await harness.openNote(text: "A")
            let port = try XCTUnwrap(harness.port(for: handle))
            handle.session.replaceText("B")
            port.indeterminateNextSave = true
            do {
                _ = try await harness.store.save(handle.identity)
                XCTFail("expected unconfirmed save")
            } catch let error as IOSDocumentFailure { XCTAssertEqual(error, .indeterminate) }
            await harness.coordinator.setBytes(Data("B".utf8))
            port.emit(.externalChange)
            await waitUntil {
                if case .conflict = harness.store.state(for: handle.identity) { return true }
                return false
            }
            try await harness.store.resolveExternal(handle.identity, choice: .reload)
            let proposal = try XCTUnwrap(harness.store.byIdentity[handle.identity]?.pendingProposal)
            port.canWrite = writable
            let revision = IOSDocumentRevision(documentID: handle.identity, version: handle.session.version)
            harness.store.acknowledgeExternalReload(operationID: proposal.operationID, outcome: .installed(revision))
            XCTAssertEqual(harness.store.state(for: handle.identity)?.canWrite, writable)
            XCTAssertFalse(handle.session.isDirty)
            if writable {
                handle.session.replaceText("C")
                _ = try await harness.store.save(handle.identity)
                XCTAssertEqual(port.written.last, Data("C".utf8))
            }
        }
    }

    func testIndeterminateWriteCannotAcknowledgeUndoToTheOldBaseline() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "old")
        let port = try XCTUnwrap(harness.port(for: handle))
        handle.session.replaceText("maybe written")
        port.indeterminateNextSave = true
        do {
            _ = try await harness.store.save(handle.identity)
            XCTFail("provider returned an unknown outcome")
        } catch let failure as IOSDocumentFailure { XCTAssertEqual(failure, .indeterminate) }
        handle.session.replaceText("old")
        XCTAssertTrue(handle.session.isDirty)
        guard case .unavailable(1, .indeterminate) = harness.store.state(for: handle.identity) else {
            return XCTFail("expected an unavailable writer with an unknown last save")
        }
        do {
            _ = try await harness.store.save(handle.identity)
            XCTFail("an uncertain baseline cannot acknowledge a save")
        } catch let failure as IOSDocumentFailure { XCTAssertEqual(failure, .conflict) }
        let outcomes = await harness.store.flushForBackground()
        guard case .recovered = outcomes.first else { return XCTFail("expected a recovered draft") }
        let recovery = await harness.store.recoveryList()
        XCTAssertTrue(recovery.records.contains { $0.source == "old" })
        try await harness.store.retireRetainedWriter(handle.identity, disconnecting: false)
        let reopened = try await harness.openNote(text: "maybe written")
        XCTAssertEqual(reopened.session.text, "maybe written")
        XCTAssertEqual(harness.store.state(for: reopened.identity)?.canWrite, true)
    }

    func testClosedDocumentsReleaseTheirSessionsAndKeepTerminalState() async throws {
        let harness = DocumentIOHarness()
        weak var lastSession: DocumentSession?
        var identities: [IOSDocumentIdentity] = []
        for _ in 0 ... IOSUIDocumentStore.closedHistoryLimit {
            let handle = try await harness.openNote()
            lastSession = handle.session
            identities.append(handle.identity)
            guard case .closed = try await harness.store.close(handle.identity) else { return XCTFail("close") }
            XCTAssertNil(harness.store.snapshot(for: handle.identity))
            guard case .closed(1) = harness.store.state(for: handle.identity) else {
                return XCTFail("expected the terminal access generation")
            }
            try await harness.store.retireRetainedWriter(handle.identity, disconnecting: false)
        }
        let oldest = try XCTUnwrap(identities.first)
        XCTAssertNil(harness.store.state(for: oldest))
        try await harness.store.retireRetainedWriter(oldest, disconnecting: false)
        guard case .closed(1) = harness.store.state(for: identities[1]) else {
            return XCTFail("expected recent terminal state")
        }
        await waitUntil { lastSession == nil }
        XCTAssertTrue(harness.store.byResource.isEmpty)
        XCTAssertTrue(harness.store.byIdentity.isEmpty)
    }
}
