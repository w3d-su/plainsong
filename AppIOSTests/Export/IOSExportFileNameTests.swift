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
            assetAccess: nil,
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
            assetAccess: nil,
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

    func testPrintPlansThePaperAspectAndHandsThePDFToThePanel() async throws {
        let exporter = IOSDocumentExportController()
        var failure: String?
        var printed: (data: Data, job: String)?
        var aspect: CGFloat?
        exporter.onFailure = { failure = $0 }
        exporter.onPrintAspect = { aspect = $0 }
        exporter.presentPrintOverride = { data, job, _ in printed = (data, job) }
        exporter.begin(
            .print,
            source: DocumentTextChange(
                text: "# Hello\n\nPrint check.\n",
                version: 1,
                fileKind: .markdown,
                fileURL: URL(fileURLWithPath: "/tmp/Hello.md")
            ),
            assetAccess: nil,
            theme: "light",
            assetReader: nil
        )
        let deadline = Date().addingTimeInterval(25)
        while exporter.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(failure, failure ?? "")
        let job = try XCTUnwrap(printed)
        XCTAssertTrue(job.data.starts(with: Data("%PDF".utf8)))
        XCTAssertEqual(job.job, "Hello.pdf")
        XCTAssertNil(exporter.file, "Print never opens the file exporter")
        let planned = try XCTUnwrap(aspect)
        XCTAssertEqual(planned, IOSPrintPage.defaultImageableAspect(), accuracy: 0.0001)
        XCTAssertGreaterThan(planned, 1, "Portrait paper is taller than wide")
    }

    func testCancelledExportPresentsNothing() async throws {
        let exporter = IOSDocumentExportController()
        var failure: String?
        exporter.onFailure = { failure = $0 }
        exporter.begin(
            .html,
            source: DocumentTextChange(
                text: "# Hello\n",
                version: 1,
                fileKind: .markdown,
                fileURL: URL(fileURLWithPath: "/tmp/Hello.md")
            ),
            assetAccess: nil,
            theme: "light",
            assetReader: nil
        )
        exporter.cancel()
        let deadline = Date().addingTimeInterval(20)
        while exporter.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(exporter.isRunning)
        XCTAssertNil(exporter.file)
        XCTAssertFalse(exporter.isPresented)
        XCTAssertNil(failure)
    }

    func testDocumentChangeStopsTheExport() async throws {
        let exporter = IOSDocumentExportController()
        var current = true
        exporter.begin(
            .html,
            source: DocumentTextChange(
                text: "# Hello\n",
                version: 1,
                fileKind: .markdown,
                fileURL: URL(fileURLWithPath: "/tmp/Hello.md")
            ),
            assetAccess: nil,
            theme: "light",
            assetReader: nil,
            isCurrent: { current }
        )
        current = false
        let deadline = Date().addingTimeInterval(20)
        while exporter.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(exporter.file)
        XCTAssertFalse(exporter.isPresented)
    }
}

final class IOSExportThemeTests: XCTestCase {
    func testPrintIsAlwaysLightAndSystemFollowsTheAppearanceAtInvocation() {
        XCTAssertEqual(IOSExportTheme.resolve(kind: .print, preference: "dark", systemIsDark: true), "light")
        XCTAssertEqual(IOSExportTheme.resolve(kind: .pdf, preference: "system", systemIsDark: true), "dark")
        XCTAssertEqual(IOSExportTheme.resolve(kind: .html, preference: "system", systemIsDark: false), "light")
        XCTAssertEqual(IOSExportTheme.resolve(kind: .pdf, preference: "dark", systemIsDark: false), "dark")
        XCTAssertEqual(IOSExportTheme.resolve(kind: .html, preference: "light", systemIsDark: true), "light")
    }

    func testPrintPaperFollowsTheLocaleAndItsPrintableArea() {
        XCTAssertEqual(IOSPrintPage.defaultPaperSize(locale: Locale(identifier: "en_US")), IOSPrintPage.letter)
        XCTAssertEqual(IOSPrintPage.defaultPaperSize(locale: Locale(identifier: "zh_TW")), IOSPrintPage.a4)
        XCTAssertEqual(
            IOSPrintPage.imageableAspect(printableRect: CGRect(x: 18, y: 18, width: 576, height: 756)) ?? 0,
            756.0 / 576.0,
            accuracy: 0.0001
        )
        XCTAssertNil(IOSPrintPage.imageableAspect(printableRect: .zero))
    }
}
