import Foundation
import MarkdownCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSClosingReloadDeliveryTests: XCTestCase {
    func testCleanCloseDoesNotDeliverDrainedReadToAttachedEditor() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "baseline")
        let entry = try XCTUnwrap(harness.store.byIdentity[handle.identity])
        let port = try XCTUnwrap(harness.port(for: handle))
        var installedWhileClosing: [Bool] = []
        let observation = installReloads(harness, handle: handle) {
            installedWhileClosing.append(entry.isClosing)
        }
        defer { observation.cancel() }
        await harness.coordinator.setBytes(Data("foreign bytes 繁中".utf8))
        await harness.coordinator.setBlockReads(true)
        port.emit(.externalChange)
        await waitUntil { await harness.coordinator.blockedReads() == 1 }
        let closing = Task { try await harness.store.close(handle.identity) }
        await waitUntil { entry.isClosing }
        await harness.coordinator.unblockReads()

        guard case .closed = try await closing.value else {
            return XCTFail("An attached reload observer must not turn clean close into retention")
        }
        XCTAssertTrue(installedWhileClosing.isEmpty)
        XCTAssertEqual(handle.session.text, "baseline")
        XCTAssertFalse(handle.session.isDirty)
        XCTAssertTrue(entry.closed)
        XCTAssertTrue(entry.lease.isReleased)
        XCTAssertNil(entry.pendingProposal)
        XCTAssertTrue(port.written.isEmpty)
        let recovery = await harness.recovery.list()
        XCTAssertTrue(recovery.records.isEmpty)
    }

    func testFailedProviderCloseDeliversHeldReloadAfterClosingEnds() async throws {
        let harness = DocumentIOHarness()
        let handle = try await harness.openNote(text: "baseline")
        let entry = try XCTUnwrap(harness.store.byIdentity[handle.identity])
        let port = try XCTUnwrap(harness.port(for: handle))
        port.closeFailure = .closeFailed
        var installedWhileClosing: [Bool] = []
        let observation = installReloads(harness, handle: handle) {
            installedWhileClosing.append(entry.isClosing)
        }
        defer { observation.cancel() }
        await harness.coordinator.setBytes(Data("foreign bytes 繁中".utf8))
        await harness.coordinator.setBlockReads(true)
        port.emit(.externalChange)
        await waitUntil { await harness.coordinator.blockedReads() == 1 }
        let closing = Task { try await harness.store.close(handle.identity) }
        await waitUntil { entry.isClosing }
        await harness.coordinator.unblockReads()

        do {
            _ = try await closing.value
            XCTFail("The provider close failure must remain visible")
        } catch {
            XCTAssertEqual(error as? IOSDocumentFailure, .closeFailed)
        }
        XCTAssertEqual(installedWhileClosing, [false])
        XCTAssertEqual(handle.session.text, "foreign bytes 繁中")
        XCTAssertFalse(handle.session.isDirty)
        XCTAssertFalse(entry.closed)
        XCTAssertFalse(entry.lease.isReleased)
        XCTAssertNil(entry.pendingProposal)
        XCTAssertTrue(port.written.isEmpty)
    }

    private func installReloads(
        _ harness: DocumentIOHarness,
        handle: IOSDocumentHandle,
        onInstall: @escaping @MainActor () -> Void
    ) -> any IOSObservation {
        harness.store.observe { event in
            guard case let .externalReloadRequested(proposal) = event else { return }
            guard proposal.capturedRevision.documentID == handle.identity,
                  proposal.capturedRevision.version == handle.session.version
            else { return }
            onInstall()
            // Match IOSDocumentReloadRelay's synchronous native install/ack pair.
            handle.session.replaceTextFromAuthorizedEditor(proposal.text)
            harness.store.acknowledgeExternalReload(
                operationID: proposal.operationID,
                outcome: .installed(IOSDocumentRevision(
                    documentID: handle.identity, version: handle.session.version
                ))
            )
        }
    }
}
