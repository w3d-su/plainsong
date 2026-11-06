import Foundation
@testable import PlainsongIOS
import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSRecentProductionWorkflowTests: XCTestCase {
    func testProductionRecentsRestoresTheSameAccessServiceAndRefreshesTheFilesTree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecentFactory-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("原生文章.mdx")
        let source = "# 最近文章\n"
        try Data(source.utf8).write(to: file)
        let fixture = try makeRuntime(root: root)
        let runtime = fixture.runtime
        let controller = fixture.controller
        let access = fixture.access
        try await controller.openPickedURL(root, scope: .directory)
        let recordID = try XCTUnwrap(access.recentItems().first {
            $0.displayName == root.lastPathComponent && $0.scope == .directory
        }?.recordID)
        try await controller.openSelectedURL(file, scope: .singleFile)
        let original = try XCTUnwrap(controller.handle)
        runtime.scene.navigationPath = [.document]
        runtime.authoring.find.replacement = "Retire authoring capture"
        try XCTUnwrap(runtime.scene.surfaces.showRecentWorkspaces)()
        let presentationID = try XCTUnwrap(runtime.recentPresentation.presentationID)
        XCTAssertTrue(runtime.recentPresentation.didAppear(presentationID))
        XCTAssertEqual(runtime.authoring.find.replacement, "")
        let presenter = try XCTUnwrap(runtime.recentPresentation.presenter)
        XCTAssertTrue(presenter.rows.contains { $0.id == recordID && $0.scope == .directory })
        presenter.open(recordID: recordID)
        for _ in 0 ..< 500 {
            if !presenter.isBusy {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(presenter.isBusy)
        XCTAssertNil(presenter.errorMessage)
        XCTAssertFalse(runtime.recentPresentation.isPresented)
        XCTAssertNil(controller.handle)
        XCTAssertNil(controller.admission.active)
        XCTAssertTrue(controller.workspace === access)
        XCTAssertTrue(controller.grantIsCurrent)
        let restored = try XCTUnwrap(controller.currentGrant)
        XCTAssertEqual(restored.scope, .directory)
        XCTAssertEqual(restored.rootURL.path, root.path)
        XCTAssertTrue(controller.snapshot.workspace?.entries.contains {
            $0.location.relativePath == file.lastPathComponent
        } == true)
        runtime.recentPresentation.didDismiss(presentationID)
        XCTAssertTrue(runtime.scene.navigationPath.isEmpty)
        try await controller.openSelectedURL(file, scope: .singleFile)
        XCTAssertNotEqual(controller.handle?.identity, original.identity)
        XCTAssertEqual(controller.handle?.session.text, source)
        XCTAssertEqual(runtime.editor.textView.text, source)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
    }

    private func makeRuntime(root: URL) throws -> ProductionFixture {
        let runtime = try IOSProductionComposition
            .makeProduction(recoveryDirectory: root.appendingPathComponent("Recovery"))
        let controller = try XCTUnwrap(runtime.controller as? IOSDocumentSceneController)
        let access = try XCTUnwrap(controller.workspace as? IOSWorkspaceAccessService)
        let beforeIDs = Set(access.recentItems().map(\.recordID))
        addTeardownBlock { @MainActor in
            runtime.stopObserving()
            runtime.scene.stopObserving()
            let closed = await runtime.shutdown()
            XCTAssertTrue(closed)
            for item in access.recentItems() where !beforeIDs.contains(item.recordID) {
                access.removeRecent(recordID: item.recordID)
            }
            if closed {
                try FileManager.default.removeItem(at: root)
            }
        }
        return ProductionFixture(runtime: runtime, controller: controller, access: access)
    }
}

@MainActor
private struct ProductionFixture {
    let runtime: IOSProductionRuntime
    let controller: IOSDocumentSceneController
    let access: IOSWorkspaceAccessService
}
