import EditorKitIOS
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

    @MainActor
    func testSuccessfulShutdownReleasesItsAdmissionInvalidatesTheGrantAndStopsObservers() async throws {
        let fixture = IOSSceneControllerFixture()
        try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        let identity = try XCTUnwrap(fixture.controller.handle?.identity)
        let grant = try XCTUnwrap(fixture.controller.currentGrant)
        let shutdown = await fixture.controller.shutdown()
        XCTAssertTrue(shutdown)

        XCTAssertNil(fixture.controller.admission.active)
        XCTAssertNil(fixture.controller.handle)
        XCTAssertNil(fixture.controller.currentGrant)
        XCTAssertEqual(fixture.store.closed, [identity])
        XCTAssertEqual(fixture.store.flushCount, 1)
        XCTAssertEqual(fixture.workspace.invalidated, [grant.workspaceID])
        XCTAssertEqual(fixture.preview.invalidateCount, 1)
        XCTAssertTrue(fixture.store.observations.allSatisfy(\.0.isCancelled))
        XCTAssertTrue(fixture.editor.observations.allSatisfy(\.0.isCancelled))
        let repeatedShutdown = await fixture.controller.shutdown()
        XCTAssertTrue(repeatedShutdown)
        XCTAssertEqual(fixture.store.closed, [identity])
        XCTAssertEqual(fixture.preview.invalidateCount, 1)
    }

    @MainActor
    func testRetainedShutdownKeepsItsWriterGrantAdmissionAndUnsavedSource() async throws {
        let fixture = IOSSceneControllerFixture()
        try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        let handle = try XCTUnwrap(fixture.controller.handle)
        let grant = try XCTUnwrap(fixture.controller.currentGrant)
        let ticket = fixture.controller.admission.active
        handle.session.replaceTextFromAuthorizedEditor("retained unsaved source")
        fixture.store.closeOutcome = .retained(recovery: nil)

        let shutdown = await fixture.controller.shutdown()
        XCTAssertFalse(shutdown)

        XCTAssertTrue(fixture.controller.handle?.session === handle.session)
        XCTAssertEqual(fixture.controller.handle?.session.text, "retained unsaved source")
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertEqual(fixture.controller.currentGrant?.workspaceID, grant.workspaceID)
        XCTAssertEqual(fixture.controller.admission.active, ticket)
        XCTAssertTrue(fixture.workspace.invalidated.isEmpty)
        XCTAssertEqual(fixture.preview.invalidateCount, 0)
        XCTAssertFalse(fixture.controller.isDisposed)
    }

    @MainActor
    func testSharedAdmissionRejectsSecondControllerBeforeItsStoreCanOpen() async throws {
        let admission = IOSSceneWriterAdmission()
        let first = IOSSceneControllerFixture(admission: admission)
        let second = IOSSceneControllerFixture(admission: admission)
        try await first.controller.openPickedURL(first.selectedURL, scope: .singleFile)
        let ticket = admission.active
        do {
            try await second.controller.openPickedURL(second.selectedURL, scope: .singleFile)
            XCTFail("A recreated scene cannot race the original writer")
        } catch let error as IOSDocumentFailure {
            XCTAssertEqual(error, .unavailable)
        }

        XCTAssertTrue(second.store.opened.isEmpty)
        XCTAssertNil(second.controller.handle)
        XCTAssertEqual(first.store.opened.count, 1)
        XCTAssertEqual(admission.active, ticket)
        let secondShutdown = await second.controller.shutdown()
        XCTAssertTrue(secondShutdown)
        XCTAssertEqual(admission.active, ticket)
        let firstShutdown = await first.controller.shutdown()
        XCTAssertTrue(firstShutdown)
        XCTAssertNil(admission.active)
    }

    @MainActor
    func testClearingAnUnownedInstallationCannotReleaseAnotherControllersTicket() async throws {
        let admission = IOSSceneWriterAdmission()
        let first = IOSSceneControllerFixture(admission: admission)
        let other = IOSSceneControllerFixture(admission: admission)
        try await first.controller.openPickedURL(first.selectedURL, scope: .singleFile)
        let ticket = admission.active

        other.controller.clearInstallation()

        XCTAssertEqual(admission.active, ticket)
        XCTAssertEqual(first.controller.handle?.identity, ticket?.documentID)
        XCTAssertTrue(other.store.closed.isEmpty)
    }

    @MainActor
    func testPreviewCheckboxUsesNativeWriterPreservesSelectionAndSupportsNativeUndo() async throws {
        let editor = IOSSourceEditorController()
        let fixture = IOSSceneControllerFixture(editorBinding: editor)
        let source = "# Heading\n- [ ] item\nTail\n"
        fixture.store.initialText = source
        try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        let handle = try XCTUnwrap(fixture.controller.handle)
        let bindingID = try XCTUnwrap(fixture.controller.bindingID)
        XCTAssertTrue(fixture.controller.setCommandFocus(true, expected: handle.identity, bindingID: bindingID))
        let selection = (source as NSString).range(of: "Tail")
        editor.textView.selectedRange = selection
        let capture = try XCTUnwrap(editor.captureSnapshot())

        fixture.controller.applyPreviewCheckbox(revision: capture.revision, line: 2, checked: true)

        XCTAssertEqual(handle.session.text, "# Heading\n- [x] item\nTail\n")
        XCTAssertEqual(editor.textView.text, handle.session.text)
        XCTAssertEqual(editor.textView.selectedRange, selection)
        XCTAssertEqual(handle.session.version, capture.revision.version + 1)
        editor.undo()
        XCTAssertEqual(handle.session.text, source)
        XCTAssertEqual(editor.textView.text, source)
    }

    @MainActor
    func testStaleCheckboxRevisionCannotSubmitToTheWriterOrChangeSource() async throws {
        let fixture = IOSSceneControllerFixture()
        fixture.store.initialText = "- [ ] item\n"
        try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        let oldRevision = fixture.editor.snapshot.revision
        fixture.editor.binding.session.replaceTextFromAuthorizedEditor("- [ ] newer item\n")
        let current = fixture.editor.binding.session.text

        fixture.controller.applyPreviewCheckbox(revision: oldRevision, line: 1, checked: true)

        XCTAssertTrue(fixture.editor.appliedEdits.isEmpty)
        XCTAssertEqual(fixture.editor.binding.session.text, current)
    }

    @MainActor
    func testReadOnlyAndMarkedTextCheckboxRequestsHaveNoWriterOrSelectionEffects() async throws {
        let fixture = IOSSceneControllerFixture()
        fixture.store.initialText = "- [ ] item\n"
        try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        let handle = try XCTUnwrap(fixture.controller.handle)
        fixture.editor.selection = NSRange(location: 6, length: 4)
        let revision = fixture.editor.snapshot.revision
        fixture.store.states[handle.identity] = .ready(canWrite: false, accessGeneration: 1)
        fixture.controller.updateEditorAccess()
        fixture.controller.applyPreviewCheckbox(revision: revision, line: 1, checked: true)
        fixture.store.states[handle.identity] = .ready(canWrite: true, accessGeneration: 1)
        fixture.controller.updateEditorAccess()
        fixture.editor.hasMarkedText = true
        fixture.controller.applyPreviewCheckbox(revision: revision, line: 1, checked: true)

        XCTAssertTrue(fixture.editor.appliedEdits.isEmpty)
        XCTAssertEqual(fixture.editor.binding.session.text, "- [ ] item\n")
        XCTAssertEqual(fixture.editor.selection, NSRange(location: 6, length: 4))
        XCTAssertTrue(fixture.editor.hasMarkedText)
    }

    @MainActor
    func testCheckboxWriterRefusalDoesNotBypassNativeAuthorityByMutatingTheSession() async throws {
        let fixture = IOSSceneControllerFixture()
        fixture.store.initialText = "- [ ] item\n"
        try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        fixture.editor.selection = NSRange(location: 6, length: 4)
        let capture = fixture.editor.snapshot
        fixture.controller.applyPreviewCheckbox(revision: capture.revision, line: 1, checked: true)

        let proposal = try XCTUnwrap(fixture.editor.appliedEdits.first)
        XCTAssertEqual(fixture.editor.appliedEdits.count, 1)
        XCTAssertEqual(proposal.bindingID, capture.bindingID)
        XCTAssertEqual(proposal.baseRevision, capture.revision)
        XCTAssertEqual(proposal.accessGeneration, capture.accessGeneration)
        XCTAssertEqual(proposal.selectionGeneration, capture.selectionGeneration)
        XCTAssertEqual(proposal.result.replacementRange, NSRange(location: 3, length: 1))
        XCTAssertEqual(proposal.result.replacementString, "x")
        XCTAssertEqual(proposal.result.newSelection, capture.selection)
        XCTAssertEqual(fixture.editor.binding.session.text, "- [ ] item\n")
        XCTAssertEqual(fixture.editor.selection, capture.selection)
    }
}
