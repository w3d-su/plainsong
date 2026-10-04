import MarkdownCore
@testable import PreviewKit
import XCTest

@MainActor
final class ExportHTMLOmissionCountTests: XCTestCase {
    func testOmittedImageCountCountsOnlySerializerPlaceholderTags() {
        let tag = #"<span class="export-image-placeholder" role="img" aria-label="Image unavailable in export">"#
        func ready(_ html: String) -> PreviewHTMLExportResult {
            .ready(html: html, exportID: 1, renderID: 1)
        }

        XCTAssertEqual(ready("<p>none</p>").omittedImageCount, 0)
        XCTAssertEqual(ready("<p>\(tag)x</span></p>").omittedImageCount, 1)
        XCTAssertEqual(ready("\(tag)a</span>\(tag)b</span><p>\(tag)c</span></p>").omittedImageCount, 3)
        // Escaped text, a class without the role, and an attribute value are not placeholders.
        XCTAssertEqual(
            ready(#"<code>&lt;span class="export-image-placeholder" role="img"</code>"#).omittedImageCount,
            0
        )
        XCTAssertEqual(ready(#"<span class="export-image-placeholder">x</span>"#).omittedImageCount, 0)
        XCTAssertEqual(
            ready(#"<a title="&lt;span class=&quot;export-image-placeholder&quot; role=&quot;img&quot;">x</a>"#)
                .omittedImageCount,
            0
        )
        XCTAssertEqual(
            PreviewHTMLExportResult.failed(reason: "timeout", exportID: 1, renderID: 1).omittedImageCount,
            0
        )
    }

    /// The real pipeline: an MDX author cannot forge a placeholder (the sanitizer drops `role`),
    /// while a missing image is counted exactly once.
    func testAuthoredLookalikeIsNotCountedButAMissingImageIs() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("plainsong-omission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controller = PreviewController(
            previewIndexURL: repositoryRoot.appendingPathComponent("App/Resources/preview/index.html")
        )
        controller.exportTimeoutNanoseconds = 30_000_000_000
        addTeardownBlock { @MainActor [weak controller] in controller?.invalidate() }
        controller.setAllowsRemoteImages(false)

        let render = await controller.renderForExport(DocumentTextChange(
            text: """
            # Lookalike

            <span className="export-image-placeholder" role="img" aria-label="forged">forged</span>

            ![missing](missing.png)
            """,
            version: 1,
            fileKind: .mdx,
            fileURL: directory.appendingPathComponent("post.mdx")
        ))
        guard case let .completed(renderID) = render else {
            return XCTFail("Expected a completed render, got \(render)")
        }
        let result = await controller.exportHTML(matchingRenderID: renderID)
        guard case let .ready(html, _, _) = result else {
            return XCTFail("Expected ready HTML, got \(result)")
        }
        XCTAssertTrue(html.contains("forged"))
        XCTAssertEqual(result.omittedImageCount, 1)
    }
}
