import Foundation
import MarkdownCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSDocumentReloadAdmissionTests: XCTestCase {
    func testCurrentPendingReloadRemainsInstallableWhenWritingIsDisabled() async throws {
        let (harness, handle, proposal) = try await pendingReload()
        XCTAssertFalse(try XCTUnwrap(harness.store.state(for: handle.identity)).canWrite)
        XCTAssertEqual(harness.store.reloadAdmission(for: proposal), .installable)
    }

    func testClosingHoldsTheCurrentProposalAndFailedCloseRestoresAdmission() async throws {
        let (harness, handle, proposal) = try await pendingReload()
        let port = try XCTUnwrap(harness.port(for: handle))
        let gate = DocumentCloseGate()
        port.closeGate = { await gate.wait() }
        port.closeFailure = .closeFailed
        let closing = Task { try await harness.store.close(handle.identity) }
        await waitUntil { port.closeCalls == 1 }
        XCTAssertEqual(harness.store.reloadAdmission(for: proposal), .held)
        await gate.release()
        _ = try? await closing.value
        XCTAssertEqual(harness.store.reloadAdmission(for: proposal), .installable)
        XCTAssertEqual(handle.session.text, "original")
        XCTAssertFalse(handle.session.isDirty)
        XCTAssertTrue(port.written.isEmpty)
    }

    func testSuccessfulCloseRefusesThePreviouslyPublishedProposal() async throws {
        let (harness, handle, proposal) = try await pendingReload()
        guard case .closed = try await harness.store.close(handle.identity) else {
            return XCTFail("A clean pending proposal must not force a provider write or retention")
        }
        XCTAssertEqual(harness.store.reloadAdmission(for: proposal), .refused(.documentChanged))
        XCTAssertEqual(handle.session.text, "original")
        XCTAssertTrue(try XCTUnwrap(harness.port(for: handle)).written.isEmpty)
    }

    func testSupersedingReadRevokesTheOldProposalBeforeTheNextReadCompletes() async throws {
        let (harness, handle, proposal) = try await pendingReload()
        let port = try XCTUnwrap(harness.port(for: handle))
        await harness.coordinator.setBlockReads(true)
        port.emit(.externalChange)
        await waitUntil { await harness.coordinator.blockedReads() == 1 }
        XCTAssertEqual(harness.store.reloadAdmission(for: proposal), .refused(.documentChanged))
        await harness.coordinator.unblockReads()
    }

    func testRevokedLeaseAndNewerSourceRefuseTheDeferredProposal() async throws {
        let (harness, handle, proposal) = try await pendingReload()
        let entry = try XCTUnwrap(harness.store.byIdentity[handle.identity])
        handle.session.replaceTextFromAuthorizedEditor("newer draft")
        XCTAssertEqual(harness.store.reloadAdmission(for: proposal), .refused(.sourceChanged))
        entry.lease.release()
        XCTAssertEqual(harness.store.reloadAdmission(for: proposal), .refused(.accessChanged))
    }

    func testExplicitReloadRemainsInstallableWhileTheOriginalWriterIsFenced() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote()
        let entry = try XCTUnwrap(harness.store.byIdentity[handle.identity])
        harness.store.fenceUnavailable(entry, .access(.offline))

        try await harness.store.resolveExternal(handle.identity, choice: .reload)

        let proposal = try XCTUnwrap(entry.pendingProposal)
        XCTAssertTrue(entry.fenced)
        XCTAssertEqual(harness.store.reloadAdmission(for: proposal), .installable)
    }

    private func pendingReload() async throws -> (DocumentIOHarness, IOSDocumentHandle, IOSDocumentReloadProposal) {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote()
        let entry = try XCTUnwrap(harness.store.byIdentity[handle.identity])
        try XCTUnwrap(harness.port(for: handle)).emit(.externalChange)
        await waitUntil { entry.pendingProposal != nil }
        return try (harness, handle, XCTUnwrap(entry.pendingProposal))
    }
}

private actor DocumentCloseGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
