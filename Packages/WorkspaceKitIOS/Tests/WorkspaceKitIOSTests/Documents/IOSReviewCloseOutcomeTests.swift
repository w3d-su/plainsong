import Foundation
import MarkdownCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSReviewCloseOutcomeTests: XCTestCase {
    func testCleanPendingAndDeferredReloadsCanCloseWithoutWriting() async throws {
        for deferred in [false, true] {
            let harness = DocumentIOHarness()
            let handle = try await harness.openNote(text: "clean local")
            let entry = try XCTUnwrap(harness.store.byIdentity[handle.identity])
            let port = try XCTUnwrap(harness.port(for: handle))
            await harness.coordinator.setBytes(Data("remote".utf8))
            port.emit(.externalChange)
            await waitUntil { entry.pendingProposal != nil }
            let proposal = try XCTUnwrap(entry.pendingProposal)
            if deferred {
                harness.store.acknowledgeExternalReload(operationID: proposal.operationID, outcome: .deferred)
            }
            guard case .closed = try await harness.store.close(handle.identity) else {
                return XCTFail("a clean proposal must not permanently retain the document")
            }
            XCTAssertTrue(entry.closed)
            XCTAssertTrue(entry.lease.isReleased)
            XCTAssertNil(entry.pendingProposal)
            XCTAssertNil(entry.externalToken)
            XCTAssertTrue(port.written.isEmpty)
            XCTAssertEqual(handle.session.text, "clean local")
            let records = await harness.recovery.list()
            XCTAssertTrue(records.records.isEmpty)
        }
    }

    func testCleanCloseDrainsAnIssuedReadBeforeReleasingTheLease() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "clean local")
        let entry = try XCTUnwrap(harness.store.byIdentity[handle.identity])
        let port = try XCTUnwrap(harness.port(for: handle))
        await harness.coordinator.setBytes(Data("remote".utf8))
        await harness.coordinator.setBlockReads(true)
        port.emit(.externalChange)
        await waitUntil { await harness.coordinator.blockedReads() == 1 }
        let closing = Task { try await harness.store.close(handle.identity) }
        await waitUntil { entry.isClosing }
        XCTAssertEqual(port.closeCalls, 0)
        XCTAssertFalse(entry.lease.isReleased)
        await harness.coordinator.unblockReads()
        guard case .closed = try await closing.value else { return XCTFail("clean close") }
        XCTAssertTrue(entry.lease.isReleased)
        XCTAssertTrue(entry.externalReadTasks.isEmpty)
        XCTAssertNil(entry.pendingProposal)
        XCTAssertTrue(port.written.isEmpty)
    }

    func testCloseDuringRetirementReturnsLatestDurableDraftAndPublishesReceipt() async throws {
        let harness = DocumentIOHarness()
        let original = try await harness.openNote(text: "baseline")
        let port = try XCTUnwrap(harness.port(for: original))
        original.session.replaceText("first draft")
        var releaseClose: CheckedContinuation<Void, Never>?
        port.closeGate = { await withCheckedContinuation { releaseClose = $0 } }
        let replacement = Task { try await harness.openNote(text: "replacement", generation: 2) }
        await waitUntil { releaseClose != nil }
        let closing = Task { try await harness.store.close(original.identity) }
        await Task.yield()
        original.session.replaceText("latest draft 繁中")
        releaseClose?.resume()
        releaseClose = nil
        _ = try await replacement.value
        guard case let .retained(receipt) = try await closing.value else {
            return XCTFail("retirement recovered a draft, so close cannot report clean success")
        }
        let durable = try XCTUnwrap(receipt)
        XCTAssertEqual(durable.revision.version, original.session.version)
        let record = try await harness.recovery.load(durable.recordID)
        XCTAssertEqual(record.source, "latest draft 繁中")
        let receiptIndex = try XCTUnwrap(harness.events.lastIndex { event in
            if case let .recoveryPersisted(value) = event {
                return value.recordID == durable.recordID
            }
            return false
        })
        let closedIndex = try XCTUnwrap(harness.events.firstIndex { event in
            if case let .closed(identity) = event {
                return identity == original.identity
            }
            return false
        })
        XCTAssertLessThan(receiptIndex, closedIndex)
        XCTAssertEqual(port.closeCalls, 1)
    }

    func testCleanRetirementStillReturnsClosed() async throws {
        let harness = DocumentIOHarness()
        let original = try await harness.openNote(text: "clean")
        let port = try XCTUnwrap(harness.port(for: original))
        var releaseClose: CheckedContinuation<Void, Never>?
        port.closeGate = { await withCheckedContinuation { releaseClose = $0 } }
        let replacement = Task { try await harness.openNote(text: "replacement", generation: 2) }
        await waitUntil { releaseClose != nil }
        let closing = Task { try await harness.store.close(original.identity) }
        await Task.yield()
        releaseClose?.resume()
        releaseClose = nil
        _ = try await replacement.value
        guard case .closed = try await closing.value else { return XCTFail("clean retirement") }
    }

    func testSavedDraftsHistoricalRecoveryDoesNotMakeCleanRetirementRetained() async throws {
        let harness = DocumentIOHarness()
        let original = try await harness.openNote(text: "baseline")
        let entry = try XCTUnwrap(harness.store.byIdentity[original.identity])
        let port = try XCTUnwrap(harness.port(for: original))
        original.session.replaceText("draft recovered before save")
        _ = try await harness.store.persistRecovery(entry, reason: .backgroundDeadline)
        _ = try await harness.store.save(original.identity)
        XCTAssertNotNil(entry.recoveryReceipt)
        XCTAssertFalse(original.session.isDirty)
        let eventsBefore = harness.events.count
        var releaseClose: CheckedContinuation<Void, Never>?
        port.closeGate = { await withCheckedContinuation { releaseClose = $0 } }
        let replacement = Task { try await harness.openNote(text: "replacement", generation: 2) }
        await waitUntil { releaseClose != nil }
        let closing = Task { try await harness.store.close(original.identity) }
        await Task.yield()
        releaseClose?.resume()
        releaseClose = nil
        _ = try await replacement.value
        guard case .closed = try await closing.value else {
            return XCTFail("an old recovery receipt cannot turn a saved clean document into a retained draft")
        }
        XCTAssertFalse(harness.events.dropFirst(eventsBefore).contains { event in
            if case .recoveryPersisted = event {
                return true
            }
            return false
        })
    }
}
