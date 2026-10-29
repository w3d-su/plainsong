import Foundation
import PDFKit
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
        try assertPDFDrawsTheTealImage(data)
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

    /// The HTML omission note only proves the placeholder step. The PDF has to contain
    /// the image resource and a pixel from the teal fixture.
    private func assertPDFDrawsTheTealImage(_ data: Data) throws {
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let reference = try XCTUnwrap(page.pageRef)
        XCTAssertTrue(pageHasImageXObject(reference), "the local image must be drawn into the PDF")
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let rendered = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
        let teal = try tealPixelCount(in: XCTUnwrap(rendered.cgImage))
        XCTAssertGreaterThan(teal, 0, "the exported PDF should still show the teal image")
    }

    private func pageHasImageXObject(_ page: CGPDFPage) -> Bool {
        guard let dictionary = page.dictionary else { return false }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return false }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return false }
        var found = false
        withUnsafeMutablePointer(to: &found) { pointer in
            CGPDFDictionaryApplyFunction(xobjects, { _, object, info in
                guard let info else { return }
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
                guard let streamDictionary = CGPDFStreamGetDictionary(stream) else { return }
                var subtype: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(streamDictionary, "Subtype", &subtype), let subtype else { return }
                if String(cString: subtype) == "Image" {
                    info.assumingMemoryBound(to: Bool.self).pointee = true
                }
            }, pointer)
        }
        return found
    }

    private func tealPixelCount(in image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            if red < 90, green > 80, blue > 80, green > red + 30, blue > red + 30 {
                count += 1
            }
        }
        return count
    }

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
