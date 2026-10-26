import Foundation
import MarkdownCore
@testable import PlainsongIOS
@testable import WorkspaceKitIOS
import XCTest

/// Real conflict/recovery state and the production relay share the stored session.
@MainActor
final class IOSConflictReloadCloseTests: XCTestCase {
    func testExplicitConflictReloadResumesOnceAfterRetainedClose() async throws {
        let (fixture, recovery, handle, entry, closing) = try await heldConflictReload()
        var installedWhileClosing: [Bool] = []
        fixture.editor.onInstall = { installedWhileClosing.append(entry.isClosing) }
        let version = handle.session.version

        await recovery.releasePersist()
        guard case .retained = try await closing.value else {
            return XCTFail("The close result must preserve its durable local draft")
        }

        XCTAssertEqual(fixture.editor.installed.count, 1)
        XCTAssertEqual(installedWhileClosing, [false])
        XCTAssertEqual(handle.session.text, "foreign 繁中")
        XCTAssertEqual(handle.session.version, version + 1)
        XCTAssertFalse(handle.session.isDirty)
        XCTAssertFalse(entry.fenced)
        XCTAssertNil(entry.pendingProposal)
        XCTAssertFalse(entry.closed)
        XCTAssertFalse(fixture.lease.isReleased)
        XCTAssertTrue(fixture.port.written.isEmpty)
        fixture.editor.emitSnapshot()
        XCTAssertEqual(fixture.editor.installed.count, 1)
        guard case .closed = try await fixture.store.close(handle.identity) else {
            return XCTFail("The acknowledged reload must leave a clean, closable document")
        }
        XCTAssertTrue(fixture.port.written.isEmpty)
    }

    func testNewerSourceDuringRetainedCloseCannotInstallTheExplicitReload() async throws {
        let (fixture, recovery, handle, entry, closing) = try await heldConflictReload()
        handle.session.replaceTextFromAuthorizedEditor("newer local draft 繁中")

        await recovery.releasePersist()
        guard case .retained = try await closing.value else { return XCTFail("Keep the newer draft") }
        fixture.editor.emitSnapshot()

        XCTAssertTrue(fixture.editor.installed.isEmpty)
        XCTAssertEqual(handle.session.text, "newer local draft 繁中")
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertTrue(entry.fenced)
        XCTAssertTrue(fixture.port.written.isEmpty)
    }

    func testRevocationDuringRetainedCloseCannotInstallTheExplicitReload() async throws {
        let (fixture, recovery, handle, entry, closing) = try await heldConflictReload()
        fixture.lease.release()

        await recovery.releasePersist()
        guard case .retained = try await closing.value else { return XCTFail("Keep the revoked draft") }
        fixture.editor.emitSnapshot()

        XCTAssertTrue(fixture.editor.installed.isEmpty)
        XCTAssertEqual(handle.session.text, "local draft")
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertTrue(entry.fenced)
        XCTAssertTrue(fixture.port.written.isEmpty)
    }

    func testProviderLossRetiresAnAlreadyDeferredExplicitReload() async throws {
        let (fixture, _, _, handle) = try await conflict()
        let entry = try XCTUnwrap(fixture.store.byIdentity[handle.identity])
        fixture.editor.hasMarkedText = true
        try await fixture.store.resolveExternal(handle.identity, choice: .reload)
        let proposal = try XCTUnwrap(entry.pendingProposal)
        XCTAssertEqual(fixture.editor.installed.count, 1)
        XCTAssertEqual(entry.explicitReloadOperationID, proposal.operationID)

        fixture.port.emit(.offline)
        fixture.removeMarkedState()

        XCTAssertNil(entry.pendingProposal)
        XCTAssertNil(entry.explicitReloadOperationID)
        XCTAssertEqual(fixture.editor.installed.count, 1, "A new provider loss must retire the native deferred read")
        XCTAssertEqual(handle.session.text, "local draft")
        XCTAssertTrue(handle.session.isDirty)
        guard case .unavailable(_, .access(.offline)) = fixture.store.state(for: handle.identity) else {
            return XCTFail("The provider loss must remain visible after the stale relay delivery")
        }
        XCTAssertTrue(fixture.port.written.isEmpty)
    }

    func testProviderLossDuringExplicitReadRefusesItsLateProposal() async throws {
        let (fixture, access, _, handle) = try await conflict()
        let entry = try XCTUnwrap(fixture.store.byIdentity[handle.identity])
        await access.blockReads()
        let reloading = Task { try await fixture.store.resolveExternal(handle.identity, choice: .reload) }
        try await waitUntil { await access.hasBlockedRead }

        fixture.port.emit(.offline)
        await access.releaseReads()
        do {
            try await reloading.value
            XCTFail("A fresh provider-loss fence must reject the older in-flight read")
        } catch {
            XCTAssertEqual(error as? IOSDocumentFailure, .documentChanged)
        }
        fixture.editor.emitSnapshot()

        XCTAssertNil(entry.pendingProposal)
        XCTAssertNil(entry.explicitReloadOperationID)
        XCTAssertTrue(fixture.editor.installed.isEmpty)
        XCTAssertEqual(handle.session.text, "local draft")
        XCTAssertTrue(handle.session.isDirty)
        guard case .unavailable(_, .access(.offline)) = fixture.store.state(for: handle.identity) else {
            return XCTFail("Late bytes cannot clear newer provider unavailability")
        }
        XCTAssertTrue(fixture.port.written.isEmpty)
    }

    func testNewerExternalReadFailureRetiresTheHeldExplicitReload() async throws {
        let (fixture, access, recovery, handle) = try await conflict()
        let entry = try XCTUnwrap(fixture.store.byIdentity[handle.identity])
        await access.blockNextReadWithFailure()
        fixture.port.emitExternalChange()
        try await waitUntil { await access.hasBlockedFailingRead }
        fixture.editor.hasMarkedText = true
        try await fixture.store.resolveExternal(handle.identity, choice: .reload)
        XCTAssertNotNil(entry.pendingProposal)
        XCTAssertEqual(fixture.editor.installed.count, 1)
        await recovery.blockPersist()
        let closing = Task { try await fixture.store.close(handle.identity) }
        try await waitUntil { entry.isClosing }

        await access.releaseFailingRead()
        try await waitUntil { await recovery.hasBlockedPersist }
        XCTAssertNil(entry.pendingProposal, "Retire the older successful read before awaiting recovery")
        XCTAssertNil(entry.explicitReloadOperationID)
        fixture.removeMarkedState()
        await recovery.releasePersist()
        guard case .retained = try await closing.value else { return XCTFail("Preserve the local draft") }
        fixture.editor.emitSnapshot()

        XCTAssertEqual(fixture.editor.installed.count, 1, "A newer read failure cannot replay the earlier proposal")
        XCTAssertEqual(handle.session.text, "local draft")
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertTrue(entry.fenced)
        guard case .unavailable(_, .access(.offline)) = fixture.store.state(for: handle.identity) else {
            return XCTFail("The newer read-failure fence must survive retained close")
        }
        XCTAssertTrue(fixture.port.written.isEmpty)
    }

    private func heldConflictReload() async throws -> (
        IOSDeferredReloadCloseFixture, IOSConflictReloadCloseRecovery, IOSDocumentHandle,
        IOSDocumentEntry, Task<IOSDocumentCloseOutcome, Error>
    ) {
        let (fixture, access, recovery, handle) = try await conflict()
        let entry = try XCTUnwrap(fixture.store.byIdentity[handle.identity])
        await access.blockReads()
        await recovery.blockPersist()
        let reloading = Task { try await fixture.store.resolveExternal(handle.identity, choice: .reload) }
        try await waitUntil { await access.hasBlockedRead }
        let closing = Task { try await fixture.store.close(handle.identity) }
        try await waitUntil { await recovery.hasBlockedPersist }
        XCTAssertTrue(entry.isClosing)
        await access.releaseReads()
        try await reloading.value
        XCTAssertNotNil(entry.pendingProposal)
        XCTAssertTrue(fixture.editor.installed.isEmpty, "Closing must still hold the explicit proposal")
        return (fixture, recovery, handle, entry, closing)
    }

    private func conflict() async throws -> (
        IOSDeferredReloadCloseFixture, IOSConflictReloadCloseAccess, IOSConflictReloadCloseRecovery, IOSDocumentHandle
    ) {
        let access = IOSConflictReloadCloseAccess()
        let recovery = IOSConflictReloadCloseRecovery()
        let fixture = IOSDeferredReloadCloseFixture(coordinatedAccess: access, recovery: recovery)
        addTeardownBlock { @MainActor in
            await access.releaseReads()
            await access.releaseFailingRead()
            await recovery.releasePersist()
            await fixture.cleanUp()
            await recovery.cleanUp()
        }
        let handle = try await fixture.open()
        handle.session.replaceTextFromAuthorizedEditor("local draft")
        fixture.port.emitExternalChange()
        try await waitUntil {
            if case .conflict = fixture.store.state(for: handle.identity) {
                return true
            }
            return false
        }
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertTrue(fixture.editor.installed.isEmpty)
        return (fixture, access, recovery, handle)
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Conflict, coordinated read or recovery did not reach its gate")
        throw IOSDocumentFailure.unavailable
    }
}
