import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSConflictCopyCoordinatorTests: XCTestCase {
    func testCancelAndRetiredPickerNeverMintADestinationGrant() async throws {
        let fixture = IOSConflictCopyFixture()
        defer { fixture.stop() }
        _ = try await fixture.openConflict()
        let first = try fixture.prepare()
        fixture.copy.cancelPicker(first.id)
        XCTAssertNil(fixture.copy.completePicker(first, urls: [fixture.workspace.destinationURL]))
        let draft = try XCTUnwrap(fixture.copy.draft)
        let second = try XCTUnwrap(fixture.copy.requestFolderPicker(draftID: draft.id, filename: "second.md"))
        fixture.copy.cancelDraft(draft.id)
        XCTAssertNil(fixture.copy.completePicker(second, urls: [fixture.workspace.destinationURL]))
        XCTAssertEqual(fixture.workspace.base.selected.count, 1)
        XCTAssertTrue(fixture.documents.copyRequests.isEmpty)
        XCTAssertEqual(fixture.copy.lastOutcome, .cancelled)
    }

    func testDuplicatePickerCallbackCreatesOnlyOneCopy() async throws {
        let fixture = IOSConflictCopyFixture()
        defer { fixture.stop() }
        _ = try await fixture.openConflict()
        let request = try fixture.prepare()
        let task = try XCTUnwrap(fixture.copy.completePicker(request, urls: [fixture.workspace.destinationURL]))
        XCTAssertNil(fixture.copy.completePicker(request, urls: [fixture.workspace.destinationURL]))
        let outcome = await task.value
        XCTAssertEqual(outcome, .saved(filename: request.filename))
        XCTAssertEqual(fixture.documents.copyRequests.count, 1)
        XCTAssertEqual(fixture.documents.createdCopies.count, 1)
    }

    func testPickerIssuanceRejectsAnAlteredFilenameAndMultipleURLs() async throws {
        let fixture = IOSConflictCopyFixture()
        defer { fixture.stop() }
        _ = try await fixture.openConflict()
        let request = try fixture.prepare()
        let altered = IOSConflictCopyPickerRequest(id: request.id, draftID: request.draftID, filename: "../escape.md")
        XCTAssertNil(fixture.copy.completePicker(altered, urls: [fixture.workspace.destinationURL]))
        XCTAssertEqual(fixture.copy.pickerRequest?.id, request.id)
        XCTAssertNil(fixture.copy.completePicker(
            request,
            urls: [fixture.workspace.destinationURL, fixture.workspace.destinationURL]
        ))
        XCTAssertNil(fixture.copy.completePicker(request, urls: [fixture.workspace.destinationURL]))
        XCTAssertTrue(fixture.documents.copyRequests.isEmpty)
        XCTAssertEqual(fixture.workspace.base.selected.count, 1)
    }

    func testStaleSourceBindingAndGenerationAreRejectedBeforeDestinationAccess() async throws {
        for mutation in 0 ..< 3 {
            let fixture = IOSConflictCopyFixture()
            defer { fixture.stop() }
            let handle = try await fixture.openConflict()
            let request = try fixture.prepare()
            switch mutation {
            case 0: handle.session.replaceTextFromAuthorizedEditor("newer N+1")
            case 1: fixture.controller.bindingID = UUID()
            default: _ = fixture.workspace.invalidate(handle.location.workspaceID)
            }
            let task = try XCTUnwrap(fixture.copy.completePicker(request, urls: [fixture.workspace.destinationURL]))
            let outcome = await task.value
            XCTAssertEqual(outcome, .refused(mutation == 0 ? .sourceChanged : .originChanged, copyMayExist: false))
            XCTAssertEqual(fixture.workspace.base.selected.count, 1)
            XCTAssertTrue(fixture.documents.copyRequests.isEmpty)
        }
    }

    func testAReplacedEditorBindingWithTheSameRevisionCannotReceiveTheCopy() async throws {
        let fixture = IOSConflictCopyFixture()
        defer { fixture.stop() }
        let handle = try await fixture.openConflict()
        let request = try fixture.prepare()
        fixture.editor.attach(IOSSourceEditorDocumentBinding(
            bindingID: UUID(), identity: handle.identity, session: handle.session,
            accessGeneration: handle.location.accessGeneration, canWrite: false
        ))
        let task = try XCTUnwrap(fixture.copy.completePicker(request, urls: [fixture.workspace.destinationURL]))
        let outcome = await task.value
        XCTAssertEqual(outcome, .refused(.originChanged, copyMayExist: false))
        XCTAssertTrue(fixture.documents.copyRequests.isEmpty)
    }

    func testResolvedConflictAndMarkedTextRefuseTheOldPicker() async throws {
        for markedText in [false, true] {
            let fixture = IOSConflictCopyFixture()
            defer { fixture.stop() }
            let handle = try await fixture.openConflict()
            let request = try fixture.prepare()
            if markedText {
                fixture.editor.hasMarkedText = true
            } else {
                fixture.documents.base.states[handle.identity] = .ready(canWrite: true, accessGeneration: 1)
            }
            let task = try XCTUnwrap(fixture.copy.completePicker(request, urls: [fixture.workspace.destinationURL]))
            let outcome = await task.value
            XCTAssertEqual(outcome, .refused(.originChanged, copyMayExist: false))
            XCTAssertTrue(fixture.documents.copyRequests.isEmpty)
        }
    }

    func testSourceChangeWhileDestinationGrantOpensRetiresOnlyThatDestination() async throws {
        let fixture = IOSConflictCopyFixture()
        defer { fixture.stop() }
        let handle = try await fixture.openConflict()
        let request = try fixture.prepare()
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        fixture.workspace.openLatch = latch
        let task = try XCTUnwrap(fixture.copy.completePicker(request, urls: [fixture.workspace.destinationURL]))
        try await waitUntil { fixture.workspace.destinationGrant != nil }
        handle.session.replaceTextFromAuthorizedEditor("newer source during folder admission")
        latch.release()
        let outcome = await task.value
        XCTAssertEqual(outcome, .refused(.sourceChanged, copyMayExist: false))
        XCTAssertEqual(
            fixture.workspace.base.invalidated,
            try [XCTUnwrap(fixture.workspace.destinationGrant).workspaceID]
        )
        XCTAssertFalse(try XCTUnwrap(fixture.workspace.base.leases.first).isReleased)
        XCTAssertTrue(fixture.documents.copyRequests.isEmpty)
        XCTAssertEqual(handle.session.text, "newer source during folder admission")
    }

    func testSourceChangeDuringDestinationRefreshIsRejectedBeforeCreatingCopy() async throws {
        let fixture = IOSConflictCopyFixture()
        defer { fixture.stop() }
        let handle = try await fixture.openConflict()
        let request = try fixture.prepare()
        fixture.workspace
            .onDestinationRefresh = { _ in handle.session.replaceTextFromAuthorizedEditor("newer after refresh") }
        let task = try XCTUnwrap(fixture.copy.completePicker(request, urls: [fixture.workspace.destinationURL]))
        let outcome = await task.value
        XCTAssertEqual(outcome, .refused(.sourceChanged, copyMayExist: false))
        XCTAssertTrue(fixture.documents.copyRequests.isEmpty)
        XCTAssertEqual(
            fixture.workspace.base.leases.filter { $0.grant.workspaceID != handle.location.workspaceID }
                .allSatisfy(\.isReleased),
            true
        )
    }

    func testExistingDestinationNameAndConcurrentCreateNeverOverwrite() async throws {
        for listed in [true, false] {
            let fixture = IOSConflictCopyFixture()
            defer { fixture.stop() }
            let handle = try await fixture.openConflict()
            let request = try fixture.prepare()
            if listed {
                fixture.workspace.base.directoryPaths = [request.filename]
            } else {
                fixture.documents.copyError = IOSDocumentFailure.access(.alreadyExists)
            }
            let task = try XCTUnwrap(fixture.copy.completePicker(request, urls: [fixture.workspace.destinationURL]))
            let outcome = await task.value
            XCTAssertEqual(outcome, .refused(.alreadyExists, copyMayExist: !listed))
            XCTAssertEqual(fixture.documents.copyRequests.count, listed ? 0 : 1)
            XCTAssertTrue(fixture.documents.createdCopies.isEmpty)
            XCTAssertTrue(handle.session.isDirty)
            XCTAssertTrue(fixture.documents.base.saved.isEmpty)
            XCTAssertTrue(fixture.documents.base.closed.isEmpty)
        }
    }

    func testRevokedDestinationGenerationCannotStartACopy() async throws {
        let fixture = IOSConflictCopyFixture()
        defer { fixture.stop() }
        let handle = try await fixture.openConflict()
        let request = try fixture.prepare()
        fixture.workspace.onDestinationRefresh = { grant in _ = fixture.workspace.invalidate(grant.workspaceID) }
        let task = try XCTUnwrap(fixture.copy.completePicker(request, urls: [fixture.workspace.destinationURL]))
        let outcome = await task.value
        XCTAssertEqual(outcome, .refused(.destinationChanged, copyMayExist: false))
        XCTAssertTrue(fixture.documents.copyRequests.isEmpty)
        XCTAssertFalse(fixture.workspace.base.invalidated.contains(handle.location.workspaceID))
        XCTAssertTrue(fixture.controller.grantIsCurrent)
    }
}

extension IOSConflictCopyCoordinatorTests {
    func testParkedCopyOfNRetainsNewerNPlusOneAndReportsEarlierCopy() async throws {
        let fixture = IOSConflictCopyFixture()
        defer { fixture.stop() }
        let handle = try await fixture.openConflict()
        let source = handle.session.text
        let request = try fixture.prepare()
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        fixture.documents.copyLatch = latch
        let task = try XCTUnwrap(fixture.copy.completePicker(request, urls: [fixture.workspace.destinationURL]))
        try await waitUntil { fixture.documents.copyRequests.count == 1 }
        handle.session.replaceTextFromAuthorizedEditor("newer N+1 must survive")
        latch.release()
        let outcome = await task.value
        XCTAssertEqual(outcome, .refused(.sourceChanged, copyMayExist: true))
        XCTAssertEqual(fixture.documents.createdCopies.first?.1, source)
        XCTAssertEqual(handle.session.text, "newer N+1 must survive")
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertNil(fixture.copy.notice)
        fixture.copy.nameSheetDidDismiss(request.draftID)
        XCTAssertTrue(fixture.copy.notice?.message.contains("earlier text") == true)
        XCTAssertTrue(fixture.documents.base.saved.isEmpty)
    }

    func testCancellationKeepsDestinationLeaseAndTransitionUntilProviderDrains() async throws {
        let fixture = IOSConflictCopyFixture()
        defer { fixture.stop() }
        let handle = try await fixture.openConflict()
        let request = try fixture.prepare()
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        fixture.documents.copyLatch = latch
        let task = try XCTUnwrap(fixture.copy.completePicker(request, urls: [fixture.workspace.destinationURL]))
        try await waitUntil { fixture.documents.copyRequests.count == 1 }
        let lease = try XCTUnwrap(fixture.documents.copyRequests.first?.lease)
        fixture.copy.cancelInFlightCopy()
        XCTAssertFalse(lease.isReleased)
        XCTAssertTrue(fixture.workspace.base.invalidated.isEmpty)
        XCTAssertTrue(fixture.controller.transitioning)
        XCTAssertTrue(fixture.copy.isSaving)
        XCTAssertFalse(fixture.copy.requestSaveCopy())
        latch.release()
        let outcome = await task.value
        XCTAssertEqual(outcome, .refused(.cancelled, copyMayExist: true))
        XCTAssertTrue(lease.isReleased)
        XCTAssertFalse(fixture.controller.transitioning)
        XCTAssertEqual(fixture.workspace.base.invalidated, [lease.grant.workspaceID])
        XCTAssertFalse(try XCTUnwrap(fixture.workspace.base.leases.first).isReleased)
        XCTAssertEqual(fixture.controller.currentGrant?.workspaceID, handle.location.workspaceID)
    }

    func testCopyTransitionRefusesNavigationAndReloadWithoutTouchingOriginalConflict() async throws {
        let fixture = IOSConflictCopyFixture()
        defer { fixture.stop() }
        let handle = try await fixture.openConflict()
        let source = handle.session.text
        let version = handle.session.version
        let request = try fixture.prepare()
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        fixture.documents.copyLatch = latch
        let task = try XCTUnwrap(fixture.copy.completePicker(request, urls: [fixture.workspace.destinationURL]))
        try await waitUntil { fixture.documents.copyRequests.count == 1 }
        do {
            try await fixture.controller.openPickedURL(URL(fileURLWithPath: "/synthetic/other.md"), scope: .singleFile)
            XCTFail("Copy fence must refuse navigation")
        } catch { XCTAssertEqual(error as? IOSDocumentFailure, .unavailable) }
        XCTAssertEqual(fixture.documents.resolutionRequests, 0)
        do {
            try await fixture.controller.resolveExternal(.reload)
            XCTFail("Copy fence must refuse conflict resolution")
        } catch { XCTAssertEqual(error as? IOSDocumentFailure, .unavailable) }
        XCTAssertEqual(fixture.documents.resolutionRequests, 0)
        latch.release()
        let outcome = await task.value
        XCTAssertEqual(outcome, .saved(filename: request.filename))
        XCTAssertTrue(fixture.controller.handle?.session === handle.session)
        XCTAssertEqual(handle.session.text, source)
        XCTAssertEqual(handle.session.version, version)
        XCTAssertTrue(handle.session.isDirty)
        guard case .conflict = fixture.controller.snapshot.documentState
        else { return XCTFail("Original conflict was cleared") }
        XCTAssertFalse(fixture.editor.snapshot.canWrite)
        XCTAssertTrue(fixture.editor.appliedEdits.isEmpty)
        XCTAssertTrue(fixture.documents.base.closed.isEmpty)
        do {
            _ = try await fixture.controller.saveCurrentDocument()
            XCTFail("Save Copy must not remove the original write barrier")
        } catch { XCTAssertEqual(error as? IOSDocumentFailure, .conflict) }
        XCTAssertTrue(fixture.documents.base.saved.isEmpty)
    }

    func testAlreadyStartedReloadExcludesCopyAdmissionUntilItsReadDrains() async throws {
        let fixture = IOSConflictCopyFixture()
        defer { fixture.stop() }
        _ = try await fixture.openConflict()
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        fixture.documents.resolutionLatch = latch
        let reload = Task { try await fixture.controller.resolveExternal(.reload) }
        try await waitUntil { fixture.documents.resolutionRequests == 1 }
        // Requires the shared integration hook: resolveExternal must own the
        // same transition while its asynchronous provider read is outstanding.
        XCTAssertTrue(fixture.controller.transitioning)
        XCTAssertFalse(fixture.copy.requestSaveCopy())
        XCTAssertTrue(fixture.documents.copyRequests.isEmpty)
        latch.release()
        try await reload.value
        XCTAssertFalse(fixture.controller.transitioning)
    }

    func testTerminalNoticeTransfersOnceOnlyAfterNameSheetDismissal() async throws {
        let fixture = IOSConflictCopyFixture()
        defer { fixture.stop() }
        _ = try await fixture.openConflict()
        let request = try fixture.prepare()
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        fixture.documents.copyLatch = latch
        let task = try XCTUnwrap(fixture.copy.completePicker(request, urls: [fixture.workspace.destinationURL]))
        try await waitUntil { fixture.documents.copyRequests.count == 1 }
        let lease = try XCTUnwrap(fixture.documents.copyRequests.first?.lease)
        XCTAssertNil(fixture.copy.notice)
        XCTAssertNil(fixture.copy.validationNotice)
        XCTAssertFalse(lease.isReleased)
        latch.release()
        let outcome = await task.value
        XCTAssertEqual(outcome, .saved(filename: request.filename))
        XCTAssertTrue(lease.isReleased)
        XCTAssertNil(fixture.copy.draft)
        XCTAssertNil(fixture.copy.notice)
        XCTAssertNil(fixture.copy.validationNotice)
        fixture.copy.nameSheetDidDismiss(UUID())
        XCTAssertNil(fixture.copy.notice)
        fixture.copy.nameSheetDidDismiss(request.draftID)
        XCTAssertEqual(fixture.copy.notice?.title, "Copy Saved")
        fixture.copy.notice = nil
        fixture.copy.nameSheetDidDismiss(request.draftID)
        XCTAssertNil(fixture.copy.notice)
    }

    func testFilenameValidationRejectsTraversalAndKeepsMarkdownAndMDXDefaultsUnique() throws {
        for name in [
            "../copy.md",
            "/copy.md",
            "folder/copy.md",
            "copy\\file.md",
            ".hidden.md",
            "copy.txt",
            "copy\n.md",
        ] {
            XCTAssertThrowsError(try IOSConflictCopyFilename.validate(name))
        }
        XCTAssertEqual(try IOSConflictCopyFilename.validate(" 繁中 Copy.mdx "), "繁中 Copy.mdx")
        let url = URL(fileURLWithPath: "/synthetic/Article.mdx")
        let first = IOSConflictCopyFilename.suggested(for: url, issuance: UUID())
        let second = IOSConflictCopyFilename.suggested(for: url, issuance: UUID())
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasSuffix(".mdx"))
        XCTAssertNoThrow(try IOSConflictCopyFilename.validate(first))
    }

    func testEarlySheetDismissalDefersTerminalNoticeUntilProviderDrains() async throws {
        let fixture = IOSConflictCopyFixture()
        defer { fixture.stop() }
        _ = try await fixture.openConflict()
        let request = try fixture.prepare()
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        fixture.documents.copyLatch = latch
        let task = try XCTUnwrap(fixture.copy.completePicker(request, urls: [fixture.workspace.destinationURL]))
        try await waitUntil { fixture.documents.copyRequests.count == 1 }
        let lease = try XCTUnwrap(fixture.documents.copyRequests.first?.lease)
        fixture.copy.nameSheetDidDismiss(request.draftID)
        XCTAssertNil(fixture.copy.notice)
        XCTAssertFalse(lease.isReleased)
        latch.release()
        _ = await task.value
        XCTAssertTrue(lease.isReleased)
        XCTAssertEqual(fixture.copy.notice?.title, "Copy Saved")
        fixture.copy.notice = nil
        fixture.copy.nameSheetDidDismiss(request.draftID)
        XCTAssertNil(fixture.copy.notice)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Controlled provider did not reach its explicit latch")
        throw IOSDocumentFailure.unavailable
    }
}
