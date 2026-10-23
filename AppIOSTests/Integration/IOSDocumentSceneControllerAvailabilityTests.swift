import Foundation
import MarkdownCore
@testable import PlainsongIOS
import WorkspaceCore
import WorkspaceKitIOS
import XCTest

extension IOSDocumentSceneControllerTests {
    @MainActor
    func testPickedURLRetainedClosePreservesTheOfflineReasonAndCurrentWriter() async throws {
        try await assertOfflineReasonSurvivesRetainedClose(for: .pickedFile)
    }

    @MainActor
    func testSelectedURLRetainedClosePreservesTheOfflineReasonAndCurrentWriter() async throws {
        try await assertOfflineReasonSurvivesRetainedClose(for: .selectedFile)
    }

    @MainActor
    func testCreateDocumentRetainedClosePreservesTheOfflineReasonAndCurrentWriter() async throws {
        try await assertOfflineReasonSurvivesRetainedClose(for: .create)
    }

    @MainActor
    func testSuccessfulPickedFileClearsTheRetiredWritersOfflineReason() async throws {
        try await assertOfflineReasonClearsAfterSafeRetirement(for: .pickedFile)
    }

    @MainActor
    func testSuccessfulPickedFolderClearsTheRetiredWritersOfflineReason() async throws {
        try await assertOfflineReasonClearsAfterSafeRetirement(for: .pickedFolder)
    }

    @MainActor
    func testSuccessfulSelectedFileClearsTheRetiredWritersOfflineReason() async throws {
        try await assertOfflineReasonClearsAfterSafeRetirement(for: .selectedFile)
    }

    @MainActor
    func testSuccessfulNewDocumentClearsTheRetiredWritersOfflineReason() async throws {
        try await assertOfflineReasonClearsAfterSafeRetirement(for: .create)
    }

    @MainActor
    func testRevocationDuringCloseCannotBeClearedByASuccessfulWriterRetirement() async throws {
        let fixture = try await offlineFolderFixture()
        let old = try XCTUnwrap(fixture.controller.handle)
        let grant = try XCTUnwrap(fixture.controller.currentGrant)
        let latch = IOSSceneControllerLatch()
        fixture.store.closeLatch = latch
        let entered = expectation(description: "Close holds the old writer before revocation")
        fixture.store.onClose = { entered.fulfill() }
        let transition = Task { @MainActor in
            try await fixture.controller.openSelectedURL(
                grant.rootURL.appendingPathComponent("second.md"), scope: .singleFile
            )
        }
        await fulfillment(of: [entered], timeout: 2)
        _ = fixture.workspace.invalidate(grant.workspaceID)
        let revokedReason = try XCTUnwrap(fixture.controller.snapshot.unavailableReason)
        latch.release()
        do {
            try await transition.value
            XCTFail("The retired writer cannot authorize a new open on the revoked grant")
        } catch let failure as IOSWorkspaceFailure {
            XCTAssertEqual(failure, .grantChanged)
        }
        XCTAssertEqual(fixture.controller.snapshot.unavailableReason, revokedReason)
        XCTAssertFalse(fixture.controller.grantIsCurrent)
        XCTAssertNil(fixture.controller.handle)
        XCTAssertNil(fixture.controller.admission.active)
        XCTAssertEqual(fixture.store.closed, [old.identity])
        XCTAssertEqual(fixture.store.opened.count, 1)
        XCTAssertFalse(fixture.controller.transitioning)
    }

    @MainActor
    private func assertOfflineReasonSurvivesRetainedClose(for entry: AvailabilityTransition) async throws {
        let fixture = try await offlineFolderFixture()
        let old = try XCTUnwrap(fixture.controller.handle)
        let grant = try XCTUnwrap(fixture.controller.currentGrant)
        let binding = fixture.controller.bindingID
        let ticket = fixture.controller.admission.active
        let reason = try XCTUnwrap(fixture.controller.snapshot.unavailableReason)
        old.session.replaceTextFromAuthorizedEditor("retained offline draft 繁中")
        let version = old.session.version
        let latch = IOSSceneControllerLatch()
        fixture.store.closeLatch = latch
        fixture.store.closeOutcome = .retained(recovery: nil)
        let entered = expectation(description: "Retained close is parked")
        fixture.store.onClose = { entered.fulfill() }
        let transition = Task { @MainActor in
            try await self.performAvailabilityTransition(entry, fixture: fixture, grant: grant)
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(fixture.controller.transitioning)
        XCTAssertEqual(fixture.controller.snapshot.unavailableReason, reason)
        XCTAssertTrue(fixture.controller.handle?.session === old.session)
        XCTAssertFalse(fixture.editor.snapshot.canWrite)
        latch.release()
        do {
            try await transition.value
            XCTFail("A retained close cannot replace the current writer")
        } catch let failure as IOSDocumentFailure {
            XCTAssertEqual(failure, .closeFailed)
        }
        XCTAssertEqual(fixture.controller.snapshot.unavailableReason, reason)
        XCTAssertTrue(fixture.controller.handle?.session === old.session)
        XCTAssertTrue(fixture.editor.binding.session === old.session)
        XCTAssertEqual(fixture.controller.bindingID, binding)
        XCTAssertEqual(fixture.controller.admission.active, ticket)
        XCTAssertEqual(old.session.text, "retained offline draft 繁中")
        XCTAssertEqual(old.session.version, version)
        XCTAssertTrue(old.session.isDirty)
        XCTAssertEqual(fixture.store.opened.count, 1)
        XCTAssertEqual(fixture.store.closed, [old.identity])
        XCTAssertEqual(fixture.workspace.selected.count, 1)
        XCTAssertTrue(fixture.workspace.invalidated.isEmpty)
        XCTAssertFalse(fixture.controller.transitioning)
    }

    @MainActor
    private func assertOfflineReasonClearsAfterSafeRetirement(for entry: AvailabilityTransition) async throws {
        let fixture = try await offlineFolderFixture()
        let old = try XCTUnwrap(fixture.controller.handle)
        let grant = try XCTUnwrap(fixture.controller.currentGrant)
        let reason = try XCTUnwrap(fixture.controller.snapshot.unavailableReason)
        let latch = IOSSceneControllerLatch()
        fixture.store.closeLatch = latch
        let entered = expectation(description: "Successful close is parked")
        fixture.store.onClose = { entered.fulfill() }
        let transition = Task { @MainActor in
            try await self.performAvailabilityTransition(entry, fixture: fixture, grant: grant)
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(fixture.controller.snapshot.unavailableReason, reason,
                       "A pending close has not retired the old writer")
        latch.release()
        try await transition.value
        XCTAssertNil(fixture.controller.snapshot.unavailableReason)
        XCTAssertEqual(fixture.store.closed, [old.identity])
        XCTAssertTrue(fixture.controller.grantIsCurrent)
        XCTAssertFalse(fixture.controller.transitioning)
        if case .pickedFolder = entry {
            XCTAssertNil(fixture.controller.handle)
            XCTAssertNil(fixture.controller.admission.active)
            XCTAssertNotNil(fixture.controller.snapshot.workspace)
            XCTAssertEqual(fixture.store.opened.count, 1)
        } else {
            let opened = try XCTUnwrap(fixture.controller.handle)
            XCTAssertNotEqual(opened.identity, old.identity)
            XCTAssertTrue(fixture.editor.binding.session === opened.session)
            XCTAssertEqual(fixture.controller.admission.active?.documentID, opened.identity)
            XCTAssertEqual(fixture.store.opened.count, 2)
        }
    }

    @MainActor
    private func offlineFolderFixture() async throws -> IOSSceneControllerFixture {
        let fixture = IOSSceneControllerFixture()
        let root = URL(fileURLWithPath: "/synthetic", isDirectory: true)
        try await fixture.controller.openPickedURL(root, scope: .directory)
        try await fixture.controller.openSelectedURL(root.appendingPathComponent("first.md"), scope: .singleFile)
        let grant = try XCTUnwrap(fixture.controller.currentGrant)
        fixture.workspace.emit(.unavailable(workspaceID: grant.workspaceID, reason: .offline))
        XCTAssertNotNil(fixture.controller.snapshot.unavailableReason)
        return fixture
    }

    @MainActor
    private func performAvailabilityTransition(
        _ entry: AvailabilityTransition, fixture: IOSSceneControllerFixture, grant: IOSWorkspaceGrant
    ) async throws {
        switch entry {
        case .pickedFile:
            try await fixture.controller.openPickedURL(
                URL(fileURLWithPath: "/synthetic/new.md"), scope: .singleFile
            )
        case .pickedFolder:
            try await fixture.controller.openPickedURL(
                URL(fileURLWithPath: "/synthetic/new-folder", isDirectory: true), scope: .directory
            )
        case .selectedFile:
            try await fixture.controller.openSelectedURL(
                grant.rootURL.appendingPathComponent("second.md"), scope: .singleFile
            )
        case .create:
            try await fixture.controller.createDocument(at: IOSFileLocation(
                workspaceID: grant.workspaceID, accessGeneration: grant.accessGeneration,
                relativePath: "", fileURL: grant.rootURL, resourceID: nil
            ))
        }
    }
}

private enum AvailabilityTransition {
    case pickedFile
    case pickedFolder
    case selectedFile
    case create
}
