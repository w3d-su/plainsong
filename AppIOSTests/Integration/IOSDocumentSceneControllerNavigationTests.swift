import EditorKitIOS
import Foundation
@testable import PlainsongIOS
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
}
