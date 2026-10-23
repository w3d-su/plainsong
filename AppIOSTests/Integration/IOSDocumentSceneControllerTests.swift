import Foundation
import MarkdownCore
@testable import PlainsongIOS
import WorkspaceCore
import WorkspaceKitIOS
import XCTest

final class IOSDocumentSceneControllerTests: XCTestCase {
    @MainActor
    func testConcurrentOpenWhileProviderIsParkedDoesNotMintASecondGrantOrWriter() async throws {
        let fixture = IOSSceneControllerFixture()
        let latch = IOSSceneControllerLatch()
        fixture.store.openLatch = latch
        let started = expectation(description: "First provider open is parked")
        fixture.store.onOpen = { started.fulfill() }
        let first = Task { @MainActor in
            try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        }
        await fulfillment(of: [started], timeout: 2)

        do {
            try await fixture.controller.openPickedURL(
                URL(fileURLWithPath: "/synthetic/second.md"), scope: .singleFile
            )
            XCTFail("A parked open already owns the scene transition")
        } catch let error as IOSDocumentFailure {
            XCTAssertEqual(error, .unavailable)
        }
        XCTAssertEqual(fixture.workspace.selected.count, 1)
        XCTAssertEqual(fixture.store.opened.count, 1)
        XCTAssertNotNil(fixture.controller.admission.active)
        latch.release()
        try await first.value
        XCTAssertEqual(fixture.editor.attachCount, 1)
    }

    @MainActor
    func testRetainedCloseKeepsTheOldSessionAndTicketWithoutOpeningTheNewSelection() async throws {
        let fixture = IOSSceneControllerFixture()
        try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        let old = try XCTUnwrap(fixture.controller.handle)
        let oldTicket = fixture.controller.admission.active
        old.session.replaceTextFromAuthorizedEditor("unsaved draft")
        let latch = IOSSceneControllerLatch()
        fixture.store.closeLatch = latch
        fixture.store.closeOutcome = .retained(recovery: nil)
        let started = expectation(description: "Close is parked")
        fixture.store.onClose = { started.fulfill() }
        let transition = Task { @MainActor in
            try await fixture.controller.openPickedURL(
                URL(fileURLWithPath: "/synthetic/new.md"), scope: .singleFile
            )
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(fixture.editor.snapshot.canWrite)
        XCTAssertEqual(fixture.workspace.selected.count, 1)
        XCTAssertEqual(fixture.store.opened.count, 1)
        latch.release()
        do {
            try await transition.value
            XCTFail("A retained writer cannot be replaced")
        } catch let error as IOSDocumentFailure {
            XCTAssertEqual(error, .closeFailed)
        }

        XCTAssertTrue(fixture.controller.handle?.session === old.session)
        XCTAssertTrue(fixture.editor.binding.session === old.session)
        XCTAssertEqual(fixture.controller.admission.active, oldTicket)
        XCTAssertEqual(fixture.controller.handle?.session.text, "unsaved draft")
        XCTAssertEqual(fixture.editor.attachCount, 1)
        XCTAssertEqual(fixture.workspace.selected.count, 1)
        XCTAssertEqual(fixture.store.opened.count, 1)
        XCTAssertFalse(fixture.controller.transitioning)
    }

    @MainActor
    func testFacadeSelectionOutsideCurrentSnapshotCannotBecomeANewPickerGrant() async throws {
        let fixture = IOSSceneControllerFixture()
        try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        let oldTicket = fixture.controller.admission.active
        do {
            try await fixture.controller.openSelectedURL(
                URL(fileURLWithPath: "/synthetic/sibling.md"), scope: .singleFile
            )
            XCTFail("A row descriptor cannot mint a sibling grant")
        } catch let error as IOSDocumentFailure {
            XCTAssertEqual(error, .access(.outsideGrant))
        }

        XCTAssertEqual(fixture.workspace.selected.count, 1)
        XCTAssertEqual(fixture.store.opened.count, 1)
        XCTAssertTrue(fixture.store.closed.isEmpty)
        XCTAssertEqual(fixture.controller.admission.active, oldTicket)
    }

    @MainActor
    func testSameDescriptorDoesNotReopenReattachOrResetTheNativeSession() async throws {
        let fixture = IOSSceneControllerFixture()
        try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        let old = try XCTUnwrap(fixture.controller.handle)
        let bindingID = fixture.controller.bindingID
        old.session.replaceTextFromAuthorizedEditor("preserve native draft")
        try await fixture.controller.openSelectedURL(fixture.selectedURL, scope: .singleFile)

        XCTAssertEqual(fixture.workspace.selected.count, 1)
        XCTAssertEqual(fixture.store.opened.count, 1)
        XCTAssertTrue(fixture.store.closed.isEmpty)
        XCTAssertEqual(fixture.editor.attachCount, 1)
        XCTAssertEqual(fixture.controller.bindingID, bindingID)
        XCTAssertTrue(fixture.editor.binding.session === old.session)
        XCTAssertEqual(old.session.text, "preserve native draft")
    }

    @MainActor
    func testGrantInvalidationCannotBeUndoneByAnOlderReadyNotification() async throws {
        let fixture = IOSSceneControllerFixture()
        try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        let handle = try XCTUnwrap(fixture.controller.handle)
        let grant = try XCTUnwrap(fixture.controller.currentGrant)
        let ticket = fixture.controller.admission.active
        XCTAssertTrue(fixture.editor.snapshot.canWrite)

        let invalidGeneration = fixture.workspace.invalidate(grant.workspaceID)
        XCTAssertFalse(fixture.editor.snapshot.canWrite)
        XCTAssertEqual(fixture.editor.snapshot.accessGeneration, invalidGeneration)
        fixture.store.emitReady(for: handle.identity, generation: grant.accessGeneration)

        XCTAssertFalse(fixture.editor.snapshot.canWrite)
        XCTAssertTrue(fixture.controller.handle?.session === handle.session)
        XCTAssertEqual(fixture.controller.admission.active, ticket)
        XCTAssertEqual(fixture.workspace.selected.count, 1)
        XCTAssertNil(fixture.controller.snapshot.workspace)
    }

    @MainActor
    func testInvalidationDuringParkedOpenRetainsTheWriterWithoutMakingItWritable() async throws {
        let fixture = IOSSceneControllerFixture()
        let latch = IOSSceneControllerLatch()
        fixture.store.openLatch = latch
        let started = expectation(description: "Open captures a grant before suspension")
        fixture.store.onOpen = { started.fulfill() }
        let opening = Task { @MainActor in
            try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        }
        await fulfillment(of: [started], timeout: 2)
        let grant = try XCTUnwrap(fixture.controller.currentGrant)
        _ = fixture.workspace.invalidate(grant.workspaceID)
        latch.release()
        do {
            try await opening.value
            XCTFail("The returned provider handle belongs to an invalidated grant")
        } catch let error as IOSWorkspaceFailure {
            XCTAssertEqual(error, .grantChanged)
        }

        let retained = try XCTUnwrap(fixture.controller.handle)
        XCTAssertFalse(fixture.editor.snapshot.canWrite)
        XCTAssertTrue(fixture.editor.binding.session === retained.session)
        XCTAssertEqual(fixture.controller.admission.active?.documentID, retained.identity)
        XCTAssertEqual(fixture.workspace.selected.count, 1)
        XCTAssertEqual(fixture.store.opened.count, 1)
        XCTAssertTrue(fixture.store.closed.isEmpty)
        XCTAssertFalse(fixture.controller.transitioning)
    }

    @MainActor
    func testOlderSaveCompletionOnlyRebasesBaselineAndCannotReloadNewerSource() async throws {
        let fixture = IOSSceneControllerFixture()
        try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        let handle = try XCTUnwrap(fixture.controller.handle)
        handle.session.replaceTextFromAuthorizedEditor("captured N")
        let version = handle.session.version
        let latch = IOSSceneControllerLatch()
        fixture.store.saveLatch = latch
        let started = expectation(description: "Save captured N")
        fixture.store.onSave = { started.fulfill() }
        let saving = Task { @MainActor in try await fixture.controller.saveCurrentDocument() }
        await fulfillment(of: [started], timeout: 2)
        handle.session.replaceTextFromAuthorizedEditor("newer N+1")
        latch.release()
        let receipt = try await saving.value

        XCTAssertEqual(receipt.revision.version, version)
        XCTAssertEqual(receipt.savedText, "captured N")
        XCTAssertEqual(handle.session.text, "newer N+1")
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertTrue(fixture.editor.binding.session === handle.session)
        XCTAssertTrue(fixture.editor.installed.isEmpty)
        XCTAssertEqual(fixture.editor.attachCount, 1)
    }

    @MainActor
    func testMarkedTextRefusesPickerTransitionBeforeAnyGrantOrCloseOperation() async throws {
        let fixture = IOSSceneControllerFixture()
        try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        fixture.editor.hasMarkedText = true
        let oldTicket = fixture.controller.admission.active
        do {
            try await fixture.controller.openPickedURL(
                URL(fileURLWithPath: "/synthetic/new.md"), scope: .singleFile
            )
            XCTFail("Native composition must remain installed")
        } catch let error as IOSDocumentFailure {
            XCTAssertEqual(error, .sourceChanged)
        }

        XCTAssertEqual(fixture.workspace.selected.count, 1)
        XCTAssertTrue(fixture.store.closed.isEmpty)
        XCTAssertEqual(fixture.controller.admission.active, oldTicket)
        XCTAssertTrue(fixture.editor.hasMarkedText)
    }
}
