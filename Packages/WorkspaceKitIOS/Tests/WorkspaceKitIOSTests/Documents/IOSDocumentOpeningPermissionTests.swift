import MarkdownCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSDocumentOpeningPermissionTests: XCTestCase {
    func testWritableNoticeDuringOpenReadbackMakesTheFirstSessionWritable() async throws {
        let harness = DocumentIOHarness()
        harness.ports.canWrite = false
        harness.ports.blockOpen = true
        await harness.coordinator.setBlockReads(true)
        let opening = Task { try await harness.openNote(text: "old") }
        await waitUntil { harness.ports.created.first?.parked == 1 }
        let port = try XCTUnwrap(harness.ports.created.first)
        port.emit(.externalChange)
        port.releaseOne()
        await waitUntil { await harness.coordinator.blockedReads() == 1 }
        port.emit(.writePermissionChanged(true))
        await harness.coordinator.setBytes(Data("current".utf8))
        await harness.coordinator.setBlockReads(false)
        await harness.coordinator.unblockReads()
        let handle = try await opening.value
        XCTAssertEqual(handle.session.text, "current")
        XCTAssertEqual(harness.store.state(for: handle.identity)?.canWrite, true)
    }

    func testWritableNoticeAfterOpenReadCaptureStillMakesFirstSessionWritable() async throws {
        let harness = DocumentIOHarness()
        harness.ports.canWrite = false
        harness.ports.blockOpen = true
        await harness.coordinator.setBlockReads(true)
        let opening = Task { try await harness.openNote(text: "old") }
        await waitUntil { harness.ports.created.first?.parked == 1 }
        let port = try XCTUnwrap(harness.ports.created.first)
        port.emit(.externalChange)
        port.releaseOne()
        await waitUntil { await harness.coordinator.blockedReads() == 1 }
        await harness.coordinator.setBytes(Data("current".utf8))
        await harness.coordinator.setCaptureObserver {
            port.emit(.writePermissionChanged(true))
        }
        await harness.coordinator.setBlockReads(false)
        await harness.coordinator.unblockReads()
        let handle = try await opening.value
        XCTAssertEqual(handle.session.text, "current")
        XCTAssertEqual(harness.store.state(for: handle.identity)?.canWrite, true)
        let completedReads = await harness.coordinator.completedReads()
        XCTAssertEqual(completedReads, 1)
    }

    func testWritableNoticeDuringFailedOpenReadbackRetriesAfterPublishing() async throws {
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
        port.emit(.writePermissionChanged(true))
        await harness.coordinator.unblockReads()
        let handle = try await opening.value
        XCTAssertEqual(handle.session.text, "old")
        XCTAssertEqual(harness.store.state(for: handle.identity)?.canWrite, false)

        await waitUntil { await harness.coordinator.blockedReads() == 2 }
        await harness.coordinator.setReadFailure(nil)
        await harness.coordinator.setBytes(Data("old".utf8))
        await harness.coordinator.setBlockReads(false)
        await harness.coordinator.unblockReads()
        await waitUntil { harness.store.state(for: handle.identity)?.canWrite == true }
        XCTAssertNil(harness.store.byIdentity[handle.identity]?.pendingProposal)
        let completedReads = await harness.coordinator.completedReads()
        XCTAssertEqual(completedReads, 1)
    }

    func testClosingUneditedFailedOpenSnapshotDoesNotWaitForWritableVerification() async throws {
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
        port.emit(.writePermissionChanged(true))
        await harness.coordinator.unblockReads()
        let handle = try await opening.value
        await waitUntil { await harness.coordinator.blockedReads() == 2 }
        let verification = try XCTUnwrap(
            harness.store.byIdentity[handle.identity]?.externalReadTasks.values.first
        )

        let closing = Task { try await harness.store.close(handle.identity) }
        await waitUntil(timeout: 0.5) {
            if case .closed = harness.store.state(for: handle.identity) { return true }
            return false
        }
        XCTAssertEqual(port.closeCalls, 1)
        XCTAssertTrue(verification.isCancelled)
        let blockedDuringClose = await harness.coordinator.blockedReads()
        XCTAssertEqual(blockedDuringClose, 2)
        await harness.coordinator.setReadFailure(nil)
        await harness.coordinator.setBytes(Data("old".utf8))
        await harness.coordinator.setBlockReads(false)
        await harness.coordinator.unblockReads()
        guard case .closed = try await closing.value else {
            return XCTFail("closing an untouched opening snapshot must release its writer")
        }
        let drafts = await harness.store.recoveryList()
        XCTAssertTrue(drafts.records.isEmpty)
    }

    func testFailedCloseKeepsWritableVerificationAlive() async throws {
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
        port.emit(.writePermissionChanged(true))
        await harness.coordinator.unblockReads()
        let handle = try await opening.value
        await waitUntil { await harness.coordinator.blockedReads() == 2 }

        port.closeFailure = .closeFailed
        let closeFailed = expectation(description: "close failed without waiting for verification")
        let closing = Task {
            do {
                _ = try await harness.store.close(handle.identity)
                XCTFail("provider close must fail")
            } catch let error as IOSDocumentFailure {
                XCTAssertEqual(error, .closeFailed)
                closeFailed.fulfill()
            } catch {
                XCTFail("unexpected close error: \(error)")
                closeFailed.fulfill()
            }
        }
        await assertFulfillment(of: [closeFailed], timeout: 0.5)
        let blockedAfterClose = await harness.coordinator.blockedReads()
        XCTAssertEqual(blockedAfterClose, 2)
        await harness.coordinator.setReadFailure(nil)
        await harness.coordinator.setBytes(Data("old".utf8))
        await harness.coordinator.setBlockReads(false)
        await harness.coordinator.unblockReads()
        await closing.value
        await waitUntil { harness.store.state(for: handle.identity)?.canWrite == true }
        XCTAssertNil(harness.store.byIdentity[handle.identity]?.pendingProposal)
    }
}
