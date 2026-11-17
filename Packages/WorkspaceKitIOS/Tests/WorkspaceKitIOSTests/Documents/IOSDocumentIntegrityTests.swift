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
        for _ in 0 ..< 12 {
            let handle = try await harness.openNote()
            lastSession = handle.session
            guard case .closed = try await harness.store.close(handle.identity) else { return XCTFail("close") }
            XCTAssertNil(harness.store.snapshot(for: handle.identity))
            guard case .closed(1) = harness.store.state(for: handle.identity) else {
                return XCTFail("expected the terminal access generation")
            }
            try await harness.store.retireRetainedWriter(handle.identity, disconnecting: false)
        }
        await waitUntil { lastSession == nil }
        XCTAssertTrue(harness.store.byResource.isEmpty)
        XCTAssertTrue(harness.store.byIdentity.isEmpty)
    }
}
