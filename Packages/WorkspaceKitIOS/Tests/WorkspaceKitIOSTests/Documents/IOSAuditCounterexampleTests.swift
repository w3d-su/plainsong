import Foundation
import MarkdownCore
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSAuditCounterexampleTests: XCTestCase {
    func testPendingExternalReadMustFenceOriginalFileWrites() async throws {
        let h = DocumentIOHarness()
        let handle = try await h.openNote(text: "baseline")
        let port = try XCTUnwrap(h.port(for: handle))
        handle.session.replaceText("dirty local")
        await h.coordinator.setBytes(Data("external edit".utf8))
        await h.coordinator.setBlockReads(true)
        port.emit(.externalChange)
        await waitUntil { await h.coordinator.blockedReads() == 1 }
        do { _ = try await h.store.save(handle.identity) } catch {}
        let writesDuringRead = port.written.count
        await h.coordinator.unblockReads()
        await waitUntil { await h.coordinator.completedReads() == 1 }
        XCTAssertEqual(writesDuringRead, 0, "Pending external change must block original-file writes")
    }

    func testEditWhilePortCloseIsSuspendedMustRetainDraft() async throws {
        let h = DocumentIOHarness()
        h.ports.openedData = Data("baseline".utf8)
        let location = h.location(relativePath: "Note.md", generation: 1)
        let lease = h.directoryLease(generation: 1)
        let handle = try await h.store.open(location, lease: lease)
        let port = try XCTUnwrap(h.port(for: handle))
        var closeContinuation: CheckedContinuation<Void, Never>?
        port.closeGate = {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                closeContinuation = c
            }
        }
        let closing = Task { try await h.store.close(handle.identity) }
        await waitUntil { closeContinuation != nil }
        handle.session.replaceText("new edit during suspended close")
        let version = handle.session.version
        closeContinuation?.resume()
        closeContinuation = nil
        let outcome = try await closing.value
        if case .closed = outcome {
            XCTFail("Close retired a newer unsaved draft")
        }
        XCTAssertFalse(lease.isReleased)
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertEqual(handle.session.text, "new edit during suspended close")
        XCTAssertEqual(handle.session.version, version)
        XCTAssertEqual(port.openCalls, 2, "the retained draft keeps its provider usable")
        XCTAssertEqual(h.store.state(for: handle.identity)?.canWrite, true)
        let recovery = await h.recovery.list()
        XCTAssertTrue(recovery.records.contains { $0.source == "new edit during suspended close" })
    }
}
