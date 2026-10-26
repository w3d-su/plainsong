import Foundation
import MarkdownCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSDocumentDeferredCloseTests: XCTestCase {
    func testNoticeQueuedBeforeTheCloseSavePreventsOverwritingUnknownExternalBytes() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "baseline")
        let port = try XCTUnwrap(harness.port(for: handle))
        let entry = try XCTUnwrap(harness.store.byIdentity[handle.identity])
        handle.session.replaceText("unsaved local draft")
        await harness.coordinator.setBytes(Data("remote bytes".utf8))
        var queuedNotice = false
        let observation = harness.store.observe { event in
            guard case .stateChanged = event, entry.isClosing, !queuedNotice else { return }
            queuedNotice = true
            port.emit(.externalChange)
        }
        defer { observation.cancel() }

        guard case let .retained(receipt) = try await harness.store.close(handle.identity) else {
            return XCTFail("The queued notice must fence the unstarted close save")
        }
        XCTAssertTrue(queuedNotice)
        XCTAssertNotNil(receipt)
        XCTAssertTrue(entry.fenced)
        XCTAssertFalse(entry.closed)
        XCTAssertFalse(entry.lease.isReleased)
        XCTAssertEqual(port.closeCalls, 0)
        XCTAssertTrue(port.written.isEmpty)
        XCTAssertEqual(handle.session.text, "unsaved local draft")
        XCTAssertTrue(handle.session.isDirty)
        let recovery = await harness.recovery.list()
        XCTAssertTrue(recovery.records.contains { $0.source == "unsaved local draft" })
    }

    func testDeferredOwnNoticeIsReadAfterTheCloseSaveAndDoesNotFalselyRetain() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "baseline")
        let port = try XCTUnwrap(harness.port(for: handle))
        let entry = try XCTUnwrap(harness.store.byIdentity[handle.identity])
        handle.session.replaceText("saved snapshot")
        port.blocksSaves = true
        let entered = expectation(description: "close save entered")
        port.onSaveEntered = { entered.fulfill() }
        await harness.coordinator.setBytes(Data("saved snapshot".utf8))
        await harness.coordinator.setBlockReads(true)
        let closing = Task { try await harness.store.close(handle.identity) }
        await fulfillment(of: [entered], timeout: 2)
        port.emit(.externalChange)
        XCTAssertTrue(entry.hasDeferredExternalChange)
        XCTAssertTrue(entry.externalReadTasks.isEmpty)
        XCTAssertEqual(port.inFlight, 1)
        port.releaseOne()
        await waitUntil { await harness.coordinator.blockedReads() == 1 }
        XCTAssertTrue(entry.isClosing)
        XCTAssertEqual(port.closeCalls, 0)
        XCTAssertEqual(port.written.map { String(data: $0, encoding: .utf8) }, ["saved snapshot"])
        await harness.coordinator.unblockReads()

        guard case .closed = try await closing.value else {
            return XCTFail("Verified own bytes must permit close")
        }
        let completedReads = await harness.coordinator.completedReads()
        XCTAssertEqual(completedReads, 1)
        XCTAssertEqual(port.closeCalls, 1)
        XCTAssertTrue(entry.closed)
        XCTAssertTrue(entry.lease.isReleased)
        XCTAssertFalse(entry.hasDeferredExternalChange)
        XCTAssertNil(entry.externalToken)
        XCTAssertFalse(handle.session.isDirty)
    }

    func testNoticeDuringProviderCloseReopensAndBlocksRetainedAutosaveUntilReadCompletes() async throws {
        let harness = DocumentIOHarness(timing: .fastAutosave)
        let handle = try await harness.openNote(text: "baseline")
        let port = try XCTUnwrap(harness.port(for: handle))
        let entry = try XCTUnwrap(harness.store.byIdentity[handle.identity])
        var closeGate: CheckedContinuation<Void, Never>?
        port.closeGate = { await withCheckedContinuation { closeGate = $0 } }
        let closing = Task { try await harness.store.close(handle.identity) }
        await waitUntil { closeGate != nil }
        let autosaveGeneration = entry.autosaveGeneration
        handle.session.replaceText("draft during provider close")
        await waitUntil { entry.autosaveGeneration > autosaveGeneration }
        await entry.autosaveTask?.value
        let exitedAutosaveGeneration = entry.autosaveGeneration
        await harness.coordinator.setBytes(Data("remote bytes".utf8))
        await harness.coordinator.setBlockReads(true)
        let queuedNotice = Task { @MainActor in port.emit(.externalChange) }
        await queuedNotice.value
        XCTAssertTrue(entry.hasDeferredExternalChange)
        XCTAssertTrue(entry.externalReadTasks.isEmpty)
        XCTAssertNil(entry.externalToken)
        XCTAssertTrue(port.written.isEmpty)
        closeGate?.resume()
        closeGate = nil

        guard case let .retained(receipt) = try await closing.value else {
            return XCTFail("A notice during provider close must retain and reopen")
        }
        XCTAssertNotNil(receipt)
        await waitUntil { await harness.coordinator.blockedReads() == 1 }
        XCTAssertEqual(port.closeCalls, 1)
        XCTAssertEqual(port.openCalls, 2)
        XCTAssertFalse(entry.closed)
        XCTAssertFalse(entry.portClosed)
        XCTAssertFalse(entry.lease.isReleased)
        XCTAssertFalse(entry.fenced, "The observation token alone must block this unknown read")
        XCTAssertNotNil(entry.externalToken)
        XCTAssertEqual(entry.autosaveGeneration, exitedAutosaveGeneration)
        handle.session.replaceText("latest retained draft 繁中")
        let version = handle.session.version
        await waitUntil { entry.autosaveGeneration > exitedAutosaveGeneration }
        await entry.autosaveTask?.value
        XCTAssertTrue(port.written.isEmpty, "Unknown external bytes cannot authorize retained autosave")
        await harness.coordinator.unblockReads()
        await waitUntil { entry.externalReadTasks.isEmpty }
        XCTAssertTrue(entry.fenced)
        XCTAssertEqual(harness.store.state(for: handle.identity)?.canWrite, false)
        XCTAssertTrue(port.written.isEmpty)
        XCTAssertEqual(handle.session.text, "latest retained draft 繁中")
        XCTAssertEqual(handle.session.version, version)
        XCTAssertTrue(handle.session.isDirty)
        let recovery = await harness.recovery.list()
        XCTAssertTrue(recovery.records.contains { $0.source == "latest retained draft 繁中" })
    }

    func testCloseDoesNotReopenAPortAfterItsLeaseIsReleasedDuringProviderClose() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "baseline")
        let port = try XCTUnwrap(harness.port(for: handle))
        let entry = try XCTUnwrap(harness.store.byIdentity[handle.identity])
        var closeGate: CheckedContinuation<Void, Never>?
        port.closeGate = { await withCheckedContinuation { closeGate = $0 } }
        let closing = Task { try await harness.store.close(handle.identity) }
        await waitUntil { closeGate != nil }
        handle.session.replaceText("keep after authority loss")
        port.emit(.externalChange)
        entry.lease.release()
        closeGate?.resume()
        closeGate = nil

        guard case let .retained(receipt) = try await closing.value else {
            return XCTFail("Authority loss must retain the source without reopening the provider")
        }
        XCTAssertNotNil(receipt)
        XCTAssertEqual(port.openCalls, 1)
        XCTAssertEqual(port.closeCalls, 1)
        XCTAssertTrue(entry.portClosed)
        XCTAssertFalse(entry.closed)
        XCTAssertTrue(entry.hasDeferredExternalChange)
        XCTAssertTrue(entry.externalReadTasks.isEmpty)
        XCTAssertTrue(port.written.isEmpty)
        XCTAssertEqual(handle.session.text, "keep after authority loss")
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertEqual(harness.store.state(for: handle.identity)?.canWrite, false)
        let completedReads = await harness.coordinator.completedReads()
        XCTAssertEqual(completedReads, 0)
        let recovery = await harness.recovery.list()
        XCTAssertTrue(recovery.records.contains { $0.source == "keep after authority loss" })
    }

    func testCloseDrainIncludesATaskRegisteredByAnEarlierDrainingTask() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "baseline")
        let entry = try XCTUnwrap(harness.store.byIdentity[handle.identity])
        let firstToken = UUID()
        let secondToken = UUID()
        var firstGate: CheckedContinuation<Void, Never>?
        var secondGate: CheckedContinuation<Void, Never>?
        var finished = false
        let first = Task { @MainActor in
            defer { entry.externalReadTasks[firstToken] = nil }
            await withCheckedContinuation { firstGate = $0 }
            let second = Task { @MainActor in
                defer { entry.externalReadTasks[secondToken] = nil }
                await withCheckedContinuation { secondGate = $0 }
            }
            entry.externalReadTasks[secondToken] = second
        }
        entry.externalReadTasks[firstToken] = first
        await waitUntil { firstGate != nil }
        let releasing = Task { @MainActor in
            firstGate?.resume()
            firstGate = nil
            await waitUntil { secondGate != nil }
            await first.value
            await Task.yield()
            await Task.yield()
            XCTAssertFalse(finished, "Drain must wait for the newly registered task too")
            secondGate?.resume()
            secondGate = nil
        }
        await harness.store.drainExternalReadsForClose(entry)
        finished = true
        await releasing.value
        XCTAssertTrue(entry.externalReadTasks.isEmpty)
    }
}
