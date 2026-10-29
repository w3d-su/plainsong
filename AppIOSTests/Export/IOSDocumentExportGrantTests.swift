import Foundation
@testable import PlainsongIOS
import UIKit
import WorkspaceKitIOS
import XCTest

/// B1: production export under a real folder grant reads local images through the same
/// access service the live preview uses. A single-file grant does not promote its parent.
@MainActor
final class IOSDocumentExportGrantTests: XCTestCase {
    func testFolderGrantHTMLExportEmbedsTheLocalImage() async throws {
        let fixture = try makeFixture()
        try await fixture.controller.openPickedURL(fixture.root, scope: .directory)
        try await fixture.controller.openSelectedURL(fixture.post, scope: .singleFile)

        let html = try await export(.html, runtime: fixture.runtime)

        XCTAssertTrue(html.contains("data:image/png;base64,"), html)
        // The stylesheet always defines the class. Only the element means an image was omitted.
        XCTAssertFalse(html.contains(Self.omittedImageTag), html)
        XCTAssertEqual(fixture.runtime.exporter.completionNote ?? "", "")
    }

    func testFolderGrantPDFExportHasNoPlaceholderNote() async throws {
        let fixture = try makeFixture()
        try await fixture.controller.openPickedURL(fixture.root, scope: .directory)
        try await fixture.controller.openSelectedURL(fixture.post, scope: .singleFile)

        let data = try await exportData(.pdf, runtime: fixture.runtime)

        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        XCTAssertEqual(fixture.runtime.exporter.completionNote ?? "", "")
    }

    func testSingleFileGrantExportUsesAPlaceholder() async throws {
        let fixture = try makeFixture()
        try await fixture.controller.openPickedURL(fixture.post, scope: .singleFile)

        let html = try await export(.html, runtime: fixture.runtime)

        XCTAssertFalse(html.contains("data:image/png;base64,"))
        XCTAssertTrue(html.contains(Self.omittedImageTag), html)
        XCTAssertEqual(fixture.runtime.exporter.completionNote, "1 image was replaced with a placeholder.")
    }

    private static let omittedImageTag = #"<span class="export-image-placeholder" role="img""#

    private func export(_ kind: IOSDocumentExportKind, runtime: IOSProductionRuntime) async throws -> String {
        try await String(decoding: exportData(kind, runtime: runtime), as: UTF8.self)
    }

    private func exportData(_ kind: IOSDocumentExportKind, runtime: IOSProductionRuntime) async throws -> Data {
        runtime.beginExport(kind)
        XCTAssertTrue(runtime.exporter.isRunning)
        let deadline = Date().addingTimeInterval(30)
        while runtime.exporter.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(runtime.scene.presentedError?.message)
        XCTAssertTrue(runtime.exporter.isPresented)
        return try XCTUnwrap(runtime.exporter.file).data
    }

    private func makeFixture() throws -> ExportFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExportGrant-\(UUID())")
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let post = root.appendingPathComponent("post.md")
        try Data("# Export\n\n![pixel](assets/x.png)\n".utf8).write(to: post)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        let png = try XCTUnwrap(renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData())
        try png.write(to: assets.appendingPathComponent("x.png"))

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
                try? FileManager.default.removeItem(at: root)
            }
        }
        return ExportFixture(runtime: runtime, controller: controller, root: root, post: post)
    }
}

@MainActor
private struct ExportFixture {
    let runtime: IOSProductionRuntime
    let controller: IOSDocumentSceneController
    let root: URL
    let post: URL
}
