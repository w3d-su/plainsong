import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSRecoveryRestoreTests: XCTestCase {
    func testNewerLiveRevisionRefusesRestoreBeforeAnyGrantOrClose() async throws {
        let fixture = try await openedFixture()
        let record = recoveryRecord()
        let capture = try fixture.controller.captureRecoveryRestore(record)
        let original = try XCTUnwrap(fixture.controller.handle)
        original.session.replaceTextFromAuthorizedEditor("newer 繁中")
        await assertFailure(.sourceChanged) {
            try await self.restore(fixture, capture: capture)
        }
        XCTAssertEqual(fixture.store.opened.count, 1)
        XCTAssertTrue(fixture.store.closed.isEmpty)
        XCTAssertEqual(fixture.workspace.selected.count, 1)
        XCTAssertEqual(original.session.text, "newer 繁中")
    }

    func testRecordReadSuspendsWithEditorDisabledAndRejectsNewerSource() async throws {
        let fixture = try await openedFixture()
        let capture = try fixture.controller.captureRecoveryRestore(recoveryRecord())
        let session = try XCTUnwrap(fixture.controller.handle?.session)
        let latch = IOSSceneControllerLatch()
        let entered = expectation(description: "recovery read parked")
        let task = Task { @MainActor in
            try await fixture.controller.restoreRecovery(capture, in: self.folder, loadRecord: { _ in
                XCTAssertFalse(fixture.editor.snapshot.canWrite)
                entered.fulfill()
                await latch.wait()
                return capture.record
            }, isCurrent: { true })
        }
        await fulfillment(of: [entered], timeout: 2)
        session.replaceTextFromAuthorizedEditor("N+1")
        latch.release()
        await assertFailure(.sourceChanged) { try await task.value }
        XCTAssertTrue(fixture.store.closed.isEmpty)
        XCTAssertEqual(fixture.workspace.selected.count, 1)
        XCTAssertEqual(session.text, "N+1")
    }

    func testRetainedClosePreservesOriginalConflictBindingAndAdmission() async throws {
        let fixture = try await openedFixture()
        let original = try XCTUnwrap(fixture.controller.handle)
        let binding = fixture.controller.bindingID
        let grant = try XCTUnwrap(fixture.controller.currentGrant)
        let ticket = fixture.controller.admission.active
        original.session.replaceTextFromAuthorizedEditor("unsaved conflict")
        fixture.store.states[original.identity] = .conflict(accessGeneration: 1, recovery: nil)
        fixture.store.closeOutcome = .retained(recovery: nil)
        let capture = try fixture.controller.captureRecoveryRestore(recoveryRecord())
        await assertFailure(.closeFailed) { try await self.restore(fixture, capture: capture) }
        XCTAssertTrue(fixture.controller.handle?.session === original.session)
        XCTAssertEqual(fixture.controller.bindingID, binding)
        XCTAssertEqual(fixture.controller.admission.active, ticket)
        XCTAssertEqual(original.session.text, "unsaved conflict")
        if case .conflict = fixture.store.state(for: original.identity) {} else {
            XCTFail("conflict cleared")
        }
        XCTAssertFalse(fixture.workspace.invalidated.contains(grant.workspaceID))
        XCTAssertEqual(fixture.store.opened.count, 1)
        XCTAssertEqual(fixture.workspace.invalidated.count, 1, "only provisional destination is retired")
    }

    func testDestinationCollisionRefusesBeforeClosingOriginal() async throws {
        let fixture = try await openedFixture()
        let capture = try fixture.controller.captureRecoveryRestore(recoveryRecord())
        fixture.workspace.directoryPaths = [capture.filename]
        await assertFailure(.access(.alreadyExists)) { try await self.restore(fixture, capture: capture) }
        XCTAssertTrue(fixture.store.closed.isEmpty)
        XCTAssertEqual(fixture.store.opened.count, 1)
        XCTAssertEqual(fixture.controller.handle?.session.text, "original")
    }

    func testSourceChangeDuringSafeCloseCannotInstallOlderRecovery() async throws {
        let fixture = try await openedFixture()
        let original = try XCTUnwrap(fixture.controller.handle)
        let capture = try fixture.controller.captureRecoveryRestore(recoveryRecord())
        fixture.store.onClose = { original.session.replaceTextFromAuthorizedEditor("newer during close") }
        await assertFailure(.sourceChanged) { try await self.restore(fixture, capture: capture) }
        XCTAssertEqual(fixture.store.opened.count, 1)
        XCTAssertEqual(original.session.text, "newer during close")
        XCTAssertNil(fixture.controller.admission.active)
    }

    func testDestinationRevokedDuringCloseCannotCreateAFile() async throws {
        let fixture = try await openedFixture()
        let capture = try fixture.controller.captureRecoveryRestore(recoveryRecord())
        fixture.store.onClose = {
            let destination = fixture.workspace.grants.values.first { $0.rootURL == self.folder }!
            _ = fixture.workspace.invalidate(destination.workspaceID)
        }
        do {
            try await restore(fixture, capture: capture)
            XCTFail("revoked destination must refuse")
        } catch let error as IOSWorkspaceFailure {
            XCTAssertEqual(error, .grantChanged)
        }
        XCTAssertEqual(fixture.store.opened.count, 1)
        XCTAssertNil(fixture.controller.handle)
    }

    func testDocumentRoundTripInvalidatesTheOldRestoreCapture() async throws {
        let fixture = try await openedFixture()
        let capture = try fixture.controller.captureRecoveryRestore(recoveryRecord())
        try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        await assertFailure(.documentChanged) { try await self.restore(fixture, capture: capture) }
        XCTAssertEqual(fixture.store.opened.count, 2)
        XCTAssertEqual(fixture.workspace.selected.count, 2)
    }

    func testReplacingTheNativeBindingRejectsTheOldRestoreCapture() async throws {
        let fixture = try await openedFixture()
        let capture = try fixture.controller.captureRecoveryRestore(recoveryRecord())
        let old = fixture.editor.binding
        fixture.editor.attach(IOSSourceEditorDocumentBinding(
            bindingID: UUID(), identity: old.identity, session: old.session,
            accessGeneration: old.accessGeneration, canWrite: true
        ))
        await assertFailure(.documentChanged) { try await self.restore(fixture, capture: capture) }
        XCTAssertTrue(fixture.store.closed.isEmpty)
        XCTAssertEqual(fixture.workspace.selected.count, 1)
    }

    func testCancelledIssuanceAfterRecordReadCannotCloseOrCreate() async throws {
        let fixture = try await openedFixture()
        let capture = try fixture.controller.captureRecoveryRestore(recoveryRecord())
        var current = true
        await assertFailure(.documentChanged) {
            try await fixture.controller.restoreRecovery(capture, in: self.folder, loadRecord: { _ in
                current = false
                return capture.record
            }, isCurrent: { current })
        }
        XCTAssertTrue(fixture.store.closed.isEmpty)
        XCTAssertEqual(fixture.store.opened.count, 1)
    }

    func testCanonicallyEqualChangedRecoveryBytesCannotBeRestored() async throws {
        let fixture = try await openedFixture()
        let original = recoveryRecord(source: "é")
        let capture = try fixture.controller.captureRecoveryRestore(original)
        let changed = IOSRecoveryRecord(
            recordID: original.recordID, operationID: original.operationID, documentID: original.documentID,
            revisionVersion: original.revisionVersion, workspaceID: original.workspaceID,
            accessGeneration: original.accessGeneration, resourceID: original.resourceID,
            relativePathUTF8: original.relativePathUTF8, fileURLPath: original.fileURLPath,
            source: "e\u{301}", baseline: original.baseline, reason: original.reason
        )
        XCTAssertEqual(original.source, changed.source)
        await assertFailure(.sourceChanged) {
            try await fixture.controller.restoreRecovery(capture, in: self.folder,
                                                         loadRecord: { _ in changed }, isCurrent: { true })
        }
        XCTAssertTrue(fixture.store.closed.isEmpty)
        XCTAssertEqual(fixture.workspace.selected.count, 1)
    }

    private let folder = URL(fileURLWithPath: "/synthetic/recovered", isDirectory: true)

    private func openedFixture() async throws -> IOSSceneControllerFixture {
        let fixture = IOSSceneControllerFixture()
        try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        return fixture
    }

    private func restore(_ fixture: IOSSceneControllerFixture, capture: IOSRecoveryRestoreCapture) async throws {
        try await fixture.controller.restoreRecovery(capture, in: folder,
                                                     loadRecord: { _ in capture.record }, isCurrent: { true })
    }

    private func assertFailure(_ expected: IOSDocumentFailure,
                               operation: @MainActor () async throws -> Void) async
    {
        do {
            try await operation()
            XCTFail("expected \(expected)")
        } catch {
            XCTAssertEqual(error as? IOSDocumentFailure, expected)
        }
    }
}

func recoveryRecord(source: String = "# 復原稿\n繁中 👩🏽‍💻", recordID: UUID = UUID()) -> IOSRecoveryRecord {
    IOSRecoveryRecord(
        recordID: recordID, operationID: UUID(), documentID: UUID(), revisionVersion: 4,
        workspaceID: UUID(), accessGeneration: 8, resourceID: nil,
        relativePathUTF8: Data("original.mdx".utf8), fileURLPath: "/ungranted/original.mdx",
        source: source, baseline: "saved original", reason: .backgroundDeadline
    )
}
