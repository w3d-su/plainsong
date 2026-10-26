import EditorKitIOS
import Foundation
@testable import PlainsongIOS
import WorkspaceKitIOS
import XCTest

extension IOSDocumentSceneControllerTests {
    @MainActor
    func testScheduledRelativeLinkCannotLeaveItsOriginBindingForANewerInstallation() async throws {
        let fixture = IOSSceneControllerFixture()
        let root = URL(fileURLWithPath: "/synthetic", isDirectory: true)
        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try await fixture.controller.openPickedURL(root, scope: .directory)
        try await fixture.controller.openSelectedURL(first, scope: .singleFile)
        let handle = try XCTUnwrap(fixture.controller.handle)
        let replacementBinding = UUID()
        XCTAssertNotNil(fixture.controller.documentLocation(for: second))

        fixture.preview.emit(.relativeLinkRequested(documentID: handle.identity, href: "second.md"))
        // Rebind synchronously before the scheduled MainActor task can run.
        // The same grant and target descriptor remain valid, so a missing
        // origin-binding fence would actually close/reopen through the store.
        fixture.controller.bindingID = replacementBinding
        fixture.editor.attach(IOSSourceEditorDocumentBinding(
            bindingID: replacementBinding, identity: handle.identity, session: handle.session,
            accessGeneration: handle.location.accessGeneration, canWrite: true
        ))
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(fixture.store.opened.count, 1)
        XCTAssertTrue(fixture.store.closed.isEmpty)
        XCTAssertTrue(fixture.controller.handle?.session === handle.session)
        XCTAssertEqual(fixture.controller.handle?.location.relativePath, "first.md")
        XCTAssertEqual(fixture.controller.bindingID, replacementBinding)
        XCTAssertFalse(fixture.controller.transitioning)
    }

    @MainActor
    func testMissingRelativeLinkReportsAnErrorWithoutMakingTheCurrentDocumentUnavailable() async throws {
        let fixture = IOSSceneControllerFixture()
        let root = URL(fileURLWithPath: "/synthetic", isDirectory: true)
        try await fixture.controller.openPickedURL(root, scope: .directory)
        try await fixture.controller.openSelectedURL(root.appendingPathComponent("first.md"), scope: .singleFile)
        let handle = try XCTUnwrap(fixture.controller.handle)
        let binding = fixture.controller.bindingID
        let ticket = fixture.controller.admission.active
        handle.session.replaceTextFromAuthorizedEditor("keep this draft")
        let failure = expectation(description: "Missing link reports a presentation error")
        var message: String?
        fixture.controller.onNavigationFailure = {
            message = $0
            failure.fulfill()
        }

        fixture.preview.emit(.relativeLinkRequested(documentID: handle.identity, href: "missing.md"))
        await fulfillment(of: [failure], timeout: 2)

        XCTAssertEqual(message, "The linked document could not be opened.")
        XCTAssertNil(fixture.controller.snapshot.unavailableReason)
        XCTAssertTrue(fixture.controller.handle?.session === handle.session)
        XCTAssertEqual(handle.session.text, "keep this draft")
        XCTAssertTrue(handle.session.isDirty)
        XCTAssertEqual(fixture.controller.snapshot.document?.revision.documentID, handle.identity)
        XCTAssertEqual(fixture.controller.bindingID, binding)
        XCTAssertEqual(fixture.controller.admission.active, ticket)
        XCTAssertTrue(fixture.editor.snapshot.canWrite)
        XCTAssertEqual(
            IOSShellChromeSnapshot(scene: fixture.controller.snapshot, editor: fixture.editor.snapshot).status,
            .ready
        )
        XCTAssertEqual(fixture.store.opened.count, 1)
        XCTAssertTrue(fixture.store.closed.isEmpty)
    }

    @MainActor
    func testRelativeLinkRefusedDuringATransitionPreservesTheCurrentDocumentAndTransition() async throws {
        let fixture = IOSSceneControllerFixture()
        let root = URL(fileURLWithPath: "/synthetic", isDirectory: true)
        try await fixture.controller.openPickedURL(root, scope: .directory)
        try await fixture.controller.openSelectedURL(root.appendingPathComponent("first.md"), scope: .singleFile)
        let handle = try XCTUnwrap(fixture.controller.handle)
        let binding = fixture.controller.bindingID
        let ticket = fixture.controller.admission.active
        try fixture.controller.beginTransition()
        defer { fixture.controller.finishTransition() }
        let failure = expectation(description: "Busy link reports a presentation error")
        fixture.controller.onNavigationFailure = { _ in failure.fulfill() }

        fixture.preview.emit(.relativeLinkRequested(documentID: handle.identity, href: "second.md"))
        await fulfillment(of: [failure], timeout: 2)

        XCTAssertNil(fixture.controller.snapshot.unavailableReason)
        XCTAssertTrue(fixture.controller.handle?.session === handle.session)
        XCTAssertEqual(fixture.controller.bindingID, binding)
        XCTAssertEqual(fixture.controller.admission.active, ticket)
        XCTAssertTrue(fixture.controller.transitioning)
        XCTAssertEqual(fixture.store.opened.count, 1)
        XCTAssertTrue(fixture.store.closed.isEmpty)
    }

    @MainActor
    func testRelativeLinkFailureCannotReplaceAGrantRevocationErrorOrRestoreWriteAccess() async throws {
        let fixture = IOSSceneControllerFixture()
        try await fixture.controller.openPickedURL(fixture.selectedURL, scope: .singleFile)
        let handle = try XCTUnwrap(fixture.controller.handle)
        let grant = try XCTUnwrap(fixture.controller.currentGrant)
        _ = fixture.workspace.invalidate(grant.workspaceID)
        let unavailable = try XCTUnwrap(fixture.controller.snapshot.unavailableReason)
        let failure = expectation(description: "Revoked link reports a presentation error")
        fixture.controller.onNavigationFailure = { _ in failure.fulfill() }

        fixture.preview.emit(.relativeLinkRequested(documentID: handle.identity, href: "missing.md"))
        await fulfillment(of: [failure], timeout: 2)

        XCTAssertEqual(fixture.controller.snapshot.unavailableReason, unavailable)
        XCTAssertFalse(fixture.editor.snapshot.canWrite)
        XCTAssertTrue(fixture.controller.handle?.session === handle.session)
        XCTAssertEqual(fixture.store.opened.count, 1)
        XCTAssertTrue(fixture.store.closed.isEmpty)
    }
}
