import Foundation
import MarkdownCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSDocumentRetirementTests: XCTestCase {
    func testGenerationReplacementDrainsWriterAndRecoversEditsDuringPortClose() async throws {
        let harness = DocumentIOHarness()
        harness.ports.openedData = Data("baseline".utf8)
        let lease = harness.directoryLease(generation: 1)
        let original = try await harness.store.open(
            harness.location(relativePath: "Note.md", generation: 1), lease: lease
        )
        let oldPort = try XCTUnwrap(harness.port(for: original))
        original.session.replaceText("save snapshot")
        oldPort.blocksSaves = true
        let entered = expectation(description: "old provider write entered")
        oldPort.onSaveEntered = { entered.fulfill() }
        let oldSave = Task { try await harness.store.save(original.identity) }
        await fulfillment(of: [entered], timeout: 2)
        original.session.replaceText("dirty during writer drain")
        var closeContinuation: CheckedContinuation<Void, Never>?
        oldPort.closeGate = {
            XCTAssertEqual(oldPort.inFlight, 0, "retirement must drain writes before provider close")
            await withCheckedContinuation { closeContinuation = $0 }
        }
        let replacementTask = Task { try await harness.openNote(text: "replacement bytes", generation: 2) }
        await waitUntil {
            let recovery = await harness.recovery.list()
            return recovery.records.contains { $0.source == "dirty during writer drain" }
        }
        XCTAssertEqual(harness.ports.created.count, 1)
        XCTAssertFalse(lease.isReleased)
        oldPort.releaseOne()
        let oldAcknowledgement = try await oldSave.value
        await waitUntil { closeContinuation != nil }
        XCTAssertEqual(harness.ports.created.count, 1, "new writer must wait through old port close")
        original.session.replaceText("latest during retirement close 繁中")
        let version = original.session.version
        closeContinuation?.resume()
        closeContinuation = nil
        let replacement = try await replacementTask.value
        XCTAssertTrue(lease.isReleased)
        XCTAssertEqual(oldPort.closeCalls, 1)
        XCTAssertEqual(oldPort.inFlight, 0)
        let recovery = await harness.recovery.list()
        XCTAssertTrue(recovery.records.contains {
            $0.documentID == original.identity.rawValue
                && $0.source == "latest during retirement close 繁中" && $0.revisionVersion == version
        })
        XCTAssertEqual(original.session.text, "latest during retirement close 繁中")
        XCTAssertEqual(original.session.version, version)
        XCTAssertEqual(replacement.session.text, "replacement bytes")
        XCTAssertFalse(replacement.session.isDirty)
        oldPort.replay(oldAcknowledgement.operationID)
        XCTAssertEqual(replacement.session.text, "replacement bytes")
        XCTAssertFalse(replacement.session.isDirty)
        replacement.session.replaceText("new generation save")
        _ = try await harness.store.save(replacement.identity)
        XCTAssertFalse(replacement.session.isDirty)
        XCTAssertEqual(harness.ports.created.count, 2)
    }

    func testRetirementDoesNotAdmitNewExternalReadsDuringProviderClose() async throws {
        let harness = DocumentIOHarness()
        harness.ports.openedData = Data("baseline".utf8)
        let lease = harness.directoryLease(generation: 1)
        let original = try await harness.store.open(
            harness.location(relativePath: "Note.md", generation: 1), lease: lease
        )
        let entry = try XCTUnwrap(harness.store.byIdentity[original.identity])
        let port = try XCTUnwrap(harness.port(for: original))
        var closeContinuation: CheckedContinuation<Void, Never>?
        port.closeGate = { await withCheckedContinuation { closeContinuation = $0 } }
        let replacing = Task { try await harness.openNote(text: "new authority", generation: 2) }
        await waitUntil { closeContinuation != nil }
        await harness.coordinator.setBlockReads(true)
        port.emit(.externalChange)
        XCTAssertTrue(entry.externalReadTasks.isEmpty,
                      "retiring ports must not start reads after their existing reads were drained")
        XCTAssertFalse(lease.isReleased)
        closeContinuation?.resume()
        closeContinuation = nil
        let replacement = try await replacing.value
        // Release a faulty implementation's read too, so the negative probe cannot leak it.
        await harness.coordinator.setBlockReads(false)
        await harness.coordinator.unblockReads()
        XCTAssertTrue(lease.isReleased)
        XCTAssertEqual(replacement.session.text, "new authority")
    }

    func testRecoveryFailureRefusesReplacementAndRetainsTheOldLeaseAndSource() async throws {
        let recovery = ScriptedRecovery()
        let harness = DocumentIOHarness(recovery: recovery)
        harness.ports.openedData = Data("baseline".utf8)
        let lease = harness.directoryLease(generation: 1)
        let original = try await harness.store.open(
            harness.location(relativePath: "Note.md", generation: 1), lease: lease
        )
        original.session.replaceText("must not disappear")
        await recovery.setFailNext(true)
        do {
            _ = try await harness.openNote(text: "replacement", generation: 2)
            XCTFail("failed retirement recovery must refuse replacement")
        } catch let failure as IOSDocumentFailure { XCTAssertEqual(failure, .recoveryFailed) }
        XCTAssertEqual(harness.ports.created.count, 1)
        XCTAssertFalse(lease.isReleased)
        XCTAssertEqual(original.session.text, "must not disappear")
        XCTAssertTrue(original.session.isDirty)
        XCTAssertNotNil(harness.store.snapshot(for: original.identity))
        let replacement = try await harness.openNote(text: "replacement", generation: 2)
        let records = await recovery.list()
        XCTAssertTrue(records.records.contains { $0.source == "must not disappear" })
        XCTAssertTrue(lease.isReleased)
        XCTAssertEqual(replacement.session.text, "replacement")
    }

    func testOlderGenerationCannotRetireTheCurrentResource() async throws {
        let harness = DocumentIOHarness()
        let current = try await harness.openNote(text: "generation two", generation: 2)
        do {
            _ = try await harness.openNote(text: "stale", generation: 1)
            XCTFail("an older generation cannot replace the current entry")
        } catch let failure as IOSDocumentFailure { XCTAssertEqual(failure, .documentChanged) }
        XCTAssertEqual(harness.ports.created.count, 1)
        XCTAssertEqual(current.session.text, "generation two")
    }

    func testCloseSaveKeepsWriteAdmissionBlockedUntilTheProviderFinishes() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "baseline")
        let port = try XCTUnwrap(harness.port(for: handle))
        handle.session.replaceText("saved during close")
        port.blocksSaves = true
        let entered = expectation(description: "close snapshot entered provider")
        port.onSaveEntered = { entered.fulfill() }
        let closing = Task { try await harness.store.close(handle.identity) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(harness.store.state(for: handle.identity)?.canWrite, false,
                       "the internal close save must not reopen user save admission")
        do {
            _ = try await harness.store.save(handle.identity)
            XCTFail("close still owns the writer")
        } catch let failure as IOSDocumentFailure {
            XCTAssertEqual(failure, .conflict)
        }
        port.releaseOne()
        guard case .closed = try await closing.value else { return XCTFail("clean close snapshot") }
        XCTAssertEqual(handle.session.text, "saved during close")
        XCTAssertFalse(handle.session.isDirty)
        XCTAssertEqual(port.written.count, 1)
    }

    func testConcurrentCloseRequestsShareOneProviderClose() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "clean")
        let port = try XCTUnwrap(harness.port(for: handle))
        var closeContinuation: CheckedContinuation<Void, Never>?
        port.closeGate = { await withCheckedContinuation { closeContinuation = $0 } }
        let first = Task { try await harness.store.close(handle.identity) }
        await waitUntil { closeContinuation != nil }
        let second = Task { try await harness.store.close(handle.identity) }
        await Task.yield()
        XCTAssertEqual(port.closeCalls, 1)
        closeContinuation?.resume()
        closeContinuation = nil
        guard case .closed = try await first.value else { return XCTFail("first close") }
        guard case .closed = try await second.value else { return XCTFail("second close") }
        XCTAssertEqual(port.closeCalls, 1)
    }
}
