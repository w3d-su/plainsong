import Foundation
import MarkdownCore
@testable import PlainsongIOS
@testable import WorkspaceKitIOS
import XCTest

/// The actual store and production relay share one session. The editor double
/// models a cancelled composition with an unchanged source and revision.
@MainActor
final class IOSDeferredReloadCloseTests: XCTestCase {
    func testDeferredReloadCannotInstallWhileProviderCloseIsSuspended() async throws {
        let fixture = fixture()
        let handle = try await fixture.openWithDeferredReload()
        try await waitUntil { fixture.editor.installed.count == 1 }
        let version = handle.session.version
        let entry = try XCTUnwrap(fixture.store.byIdentity[handle.identity])
        let proposal = try XCTUnwrap(entry.pendingProposal)
        XCTAssertEqual(fixture.store.reloadAdmission(for: proposal), .installable)
        fixture.port.closeLatch = IOSSceneControllerLatch()
        let closing = Task { try await fixture.store.close(handle.identity) }
        try await waitUntil { fixture.port.closeCalls == 1 }
        XCTAssertEqual(fixture.store.reloadAdmission(for: proposal), .held)

        fixture.removeMarkedState()

        XCTAssertEqual(fixture.editor.installed.count, 1, "The deferred operation must not reach the native writer")
        XCTAssertEqual(handle.session.version, version)
        XCTAssertEqual(handle.session.text, "original")
        XCTAssertFalse(handle.session.isDirty)
        fixture.port.closeLatch?.release()
        guard case .closed = try await closing.value else { return XCTFail("Clean close must finish") }
        fixture.editor.emitSnapshot()
        XCTAssertEqual(fixture.editor.installed.count, 1)
        XCTAssertNil(entry.pendingProposal)
        XCTAssertTrue(fixture.lease.isReleased)
        XCTAssertTrue(fixture.port.written.isEmpty)
    }

    func testFailedCloseResumesAnAlreadyDeferredReloadExactlyOnce() async throws {
        let fixture = fixture()
        let handle = try await fixture.openWithDeferredReload()
        try await waitUntil { fixture.editor.installed.count == 1 }
        let entry = try XCTUnwrap(fixture.store.byIdentity[handle.identity])
        fixture.port.closeFailure = true
        fixture.port.closeLatch = IOSSceneControllerLatch()
        let closing = Task { try await fixture.store.close(handle.identity) }
        try await waitUntil { fixture.port.closeCalls == 1 }
        fixture.removeMarkedState()
        XCTAssertEqual(fixture.editor.installed.count, 1)
        fixture.port.closeLatch?.release()
        do {
            _ = try await closing.value
            XCTFail("Provider close failure must remain visible")
        } catch {
            XCTAssertEqual(error as? IOSDocumentFailure, .closeFailed)
        }

        XCTAssertEqual(fixture.editor.installed.count, 2, "Held is not a retired operation ID")
        XCTAssertEqual(handle.session.text, "foreign 繁中")
        XCTAssertFalse(handle.session.isDirty)
        XCTAssertNil(entry.pendingProposal)
        fixture.editor.emitSnapshot()
        fixture.editor.emitSnapshot()
        XCTAssertEqual(fixture.editor.installed.count, 2)
        fixture.port.closeFailure = false
        guard case .closed = try await fixture.store.close(handle.identity) else {
            return XCTFail("The resumed reload must leave a clean, closable document")
        }
        XCTAssertTrue(fixture.port.written.isEmpty)
    }

    func testRevocationDuringCloseCannotResumeTheDeferredReload() async throws {
        let fixture = fixture()
        let handle = try await fixture.openWithDeferredReload()
        try await waitUntil { fixture.editor.installed.count == 1 }
        let entry = try XCTUnwrap(fixture.store.byIdentity[handle.identity])
        let proposal = try XCTUnwrap(entry.pendingProposal)
        fixture.port.closeFailure = true
        fixture.port.closeLatch = IOSSceneControllerLatch()
        let closing = Task { try await fixture.store.close(handle.identity) }
        try await waitUntil { fixture.port.closeCalls == 1 }
        fixture.lease.release()
        fixture.removeMarkedState()
        XCTAssertEqual(fixture.store.reloadAdmission(for: proposal), .refused(.accessChanged))
        fixture.port.closeLatch?.release()
        _ = try? await closing.value
        fixture.editor.emitSnapshot()

        XCTAssertEqual(fixture.editor.installed.count, 1)
        XCTAssertEqual(handle.session.text, "original")
        XCTAssertFalse(handle.session.isDirty)
        XCTAssertTrue(fixture.port.written.isEmpty)
    }

    private func fixture() -> IOSDeferredReloadCloseFixture {
        let fixture = IOSDeferredReloadCloseFixture()
        addTeardownBlock { @MainActor in await fixture.cleanUp() }
        return fixture
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Deferred reload or provider close did not reach its gate")
        throw IOSDocumentFailure.unavailable
    }
}
