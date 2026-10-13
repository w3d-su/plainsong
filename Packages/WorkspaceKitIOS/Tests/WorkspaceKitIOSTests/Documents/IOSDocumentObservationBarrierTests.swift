import Foundation
import MarkdownCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSDocumentObservationBarrierTests: XCTestCase {
    func testOwnNoticeDrainsInFlightAndRejectsQueuedWritesBeforeRestoringAutosave() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "baseline")
        let port = try XCTUnwrap(harness.port(for: handle))
        handle.session.replaceText("saved snapshot")
        port.blocksSaves = true
        let entered = expectation(description: "save entered")
        port.onSaveEntered = { entered.fulfill() }
        let first = Task { try await harness.store.save(handle.identity) }
        await fulfillment(of: [entered], timeout: 2)
        handle.session.replaceText("newer live source")
        let queued = Task { try await harness.store.save(handle.identity) }
        await waitUntil { harness.store.byIdentity[handle.identity]?.nextSequence == 2 }
        await harness.coordinator.setBytes(Data("saved snapshot".utf8))
        port.emit(.externalChange)
        XCTAssertFalse(harness.store.state(for: handle.identity)?.canWrite ?? true)
        let readsBeforeDrain = await harness.coordinator.completedReads()
        XCTAssertEqual(readsBeforeDrain, 0)
        port.releaseOne()
        _ = try await first.value
        do {
            _ = try await queued.value
            XCTFail("an observation barrier must reject a previously queued original write")
        } catch let failure as IOSDocumentFailure {
            XCTAssertEqual(failure, .conflict)
        }
        await waitUntil { await harness.coordinator.completedReads() == 1 }
        await waitUntil { harness.store.state(for: handle.identity)?.canWrite == true }
        XCTAssertEqual(port.written.map { String(data: $0, encoding: .utf8) }, ["saved snapshot"])
        XCTAssertEqual(handle.session.text, "newer live source")
        XCTAssertTrue(handle.session.isDirty)
        port.blocksSaves = false
        _ = try await harness.store.save(handle.identity)
        XCTAssertFalse(handle.session.isDirty)
    }

    func testExternalReadFailureKeepsOriginalFencedAndPersistsDirtyDraft() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "baseline")
        let port = try XCTUnwrap(harness.port(for: handle))
        handle.session.replaceText("recover this draft")
        await harness.coordinator.setReadFailure(.coordinationFailed)
        port.emit(.externalChange)
        await waitUntil {
            if case .unavailable = harness.store.state(for: handle.identity) {
                return true
            }
            return false
        }
        do {
            _ = try await harness.store.save(handle.identity)
            XCTFail("unknown external content must not permit overwriting the original")
        } catch let failure as IOSDocumentFailure {
            XCTAssertEqual(failure, .conflict)
        }
        XCTAssertTrue(port.written.isEmpty)
        XCTAssertEqual(handle.session.text, "recover this draft")
        let recovery = await harness.recovery.list()
        XCTAssertTrue(recovery.records.contains { $0.source == "recover this draft" })
    }

    func testDeferredReloadContinuesBlockingTheOriginalAndRefusalRecoversNewEdit() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "baseline")
        let port = try XCTUnwrap(harness.port(for: handle))
        await harness.coordinator.setBytes(Data("remote".utf8))
        port.emit(.externalChange)
        await waitUntil { harness.store.byIdentity[handle.identity]?.pendingProposal != nil }
        let proposal = try XCTUnwrap(harness.store.byIdentity[handle.identity]?.pendingProposal)
        harness.store.acknowledgeExternalReload(operationID: proposal.operationID, outcome: .deferred)
        handle.session.replaceText("new local edit")
        do {
            _ = try await harness.store.save(handle.identity)
            XCTFail("deferred reconciliation must not authorize an original-file write")
        } catch let failure as IOSDocumentFailure { XCTAssertEqual(failure, .conflict) }
        harness.store.acknowledgeExternalReload(operationID: proposal.operationID, outcome: .refused(.sourceChanged))
        await waitUntil {
            if case .conflict = harness.store.state(for: handle.identity) {
                return true
            }
            return false
        }
        XCTAssertTrue(port.written.isEmpty)
        let recovery = await harness.recovery.list()
        XCTAssertTrue(recovery.records.contains { $0.source == "new local edit" })
    }

    func testCleanNewerRevisionRestartsExternalObservationInsteadOfStayingFenced() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "baseline")
        let port = try XCTUnwrap(harness.port(for: handle))
        await harness.coordinator.setBytes(Data("remote".utf8))
        await harness.coordinator.setBlockReads(true)
        port.emit(.externalChange)
        await waitUntil { await harness.coordinator.blockedReads() == 1 }
        handle.session.replaceText("temporary edit")
        handle.session.replaceText("baseline")
        XCTAssertFalse(handle.session.isDirty)
        await harness.coordinator.setBlockReads(false)
        await harness.coordinator.unblockReads()
        await waitUntil { harness.store.byIdentity[handle.identity]?.pendingProposal != nil }
        let proposal = try XCTUnwrap(harness.store.byIdentity[handle.identity]?.pendingProposal)
        XCTAssertEqual(proposal.capturedRevision.version, handle.session.version)
        XCTAssertEqual(proposal.text, "remote")
        XCTAssertTrue(port.written.isEmpty)
    }
}
