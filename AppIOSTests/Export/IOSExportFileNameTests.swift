import Foundation
import MarkdownCore
@testable import PlainsongIOS
import UniformTypeIdentifiers
import XCTest

final class IOSExportFileNameTests: XCTestCase {
    func testFrontmatterTitleBecomesTheFileName() {
        let source = """
        ---
        title: Quarterly Review
        ---
        Body
        """
        let name = IOSExportFileName.make(
            source: source,
            fileURL: URL(fileURLWithPath: "/tmp/notes/draft.md"),
            pathExtension: "html"
        )
        XCTAssertEqual(name, "Quarterly Review.html")
    }

    func testPathSeparatorsAndAMissingTitleFallBackToTheDocumentName() {
        let name = IOSExportFileName.make(
            source: "---\ntitle: a/b:c\n---\n",
            fileURL: URL(fileURLWithPath: "/tmp/My Note.md"),
            pathExtension: "pdf"
        )
        XCTAssertEqual(name, "a-b-c.pdf")
        let fallback = IOSExportFileName.make(
            source: "No frontmatter",
            fileURL: URL(fileURLWithPath: "/tmp/My Note.md"),
            pathExtension: "html"
        )
        XCTAssertEqual(fallback, "My Note.html")
    }
}

@MainActor
final class IOSDocumentExportSmokeTests: XCTestCase {
    func testHTMLExportProducesTheRenderedDocument() async throws {
        let exporter = IOSDocumentExportController()
        var failure: String?
        exporter.onFailure = { failure = $0 }
        exporter.begin(
            .html,
            source: DocumentTextChange(
                text: "# Hello\n\nExport check.\n",
                version: 1,
                fileKind: .markdown,
                fileURL: URL(fileURLWithPath: "/tmp/Hello.md")
            ),
            assetRoot: nil,
            theme: "light",
            assetReader: nil
        )
        let deadline = Date().addingTimeInterval(20)
        while exporter.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(failure)
        XCTAssertFalse(exporter.isRunning)
        let file = try XCTUnwrap(exporter.file)
        let html = String(decoding: file.data, as: UTF8.self)
        XCTAssertTrue(html.contains("Hello"), html)
        XCTAssertEqual(exporter.filename, "Hello.html")
        XCTAssertEqual(exporter.contentType, .html)
    }

    func testPDFExportProducesPDFBytes() async throws {
        let exporter = IOSDocumentExportController()
        var failure: String?
        exporter.onFailure = { failure = $0 }
        exporter.begin(
            .pdf,
            source: DocumentTextChange(
                text: "# Hello\n\nExport check.\n",
                version: 1,
                fileKind: .markdown,
                fileURL: URL(fileURLWithPath: "/tmp/Hello.md")
            ),
            assetRoot: nil,
            theme: "light",
            assetReader: nil
        )
        let deadline = Date().addingTimeInterval(25)
        while exporter.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(failure, failure ?? "")
        XCTAssertFalse(exporter.isRunning)
        let file = try XCTUnwrap(exporter.file)
        XCTAssertTrue(file.data.starts(with: Data("%PDF".utf8)))
        XCTAssertEqual(exporter.filename, "Hello.pdf")
        XCTAssertEqual(exporter.contentType, .pdf)
    }
}
