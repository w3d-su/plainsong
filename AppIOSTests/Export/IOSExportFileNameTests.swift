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
        XCTAssertEqual(job.job, "Hello")
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

    func testCancelLetsTheNextExportStartAndIgnoresTheOldRun() async {
        let exporter = IOSDocumentExportController()
        let gate = ExportResumeGate()
        let replacementGate = ExportResumeGate()
        var entered = false
        var resumed = false
        exporter.onPrepareForTesting = {
            entered = true
            await gate.wait()
            resumed = true
        }
        let source = DocumentTextChange(
            text: "# Hello\n",
            version: 1,
            fileKind: .markdown,
            fileURL: URL(fileURLWithPath: "/tmp/Hello.md")
        )
        exporter.begin(.html, source: source, assetAccess: nil, theme: "light", assetReader: nil)
        for _ in 0 ..< 100 where !entered {
            await Task.yield()
        }
        XCTAssertTrue(entered)
        exporter.cancel()
        XCTAssertFalse(exporter.isRunning)
        XCTAssertNil(exporter.status)

        var replacementEntered = false
        var replacementResumed = false
        exporter.onPrepareForTesting = {
            replacementEntered = true
            await replacementGate.wait()
            replacementResumed = true
        }
        exporter.begin(.html, source: source, assetAccess: nil, theme: "light", assetReader: nil)
        XCTAssertTrue(exporter.isRunning)
        XCTAssertEqual(exporter.status, "Preparing HTML…")
        for _ in 0 ..< 100 where !replacementEntered {
            await Task.yield()
        }
        XCTAssertTrue(replacementEntered)
        gate.resume()
        for _ in 0 ..< 100 where !resumed {
            await Task.yield()
        }
        XCTAssertTrue(resumed)
        XCTAssertTrue(exporter.isRunning, "the cancelled run must not clear the export that replaced it")
        XCTAssertEqual(exporter.status, "Preparing HTML…")
        exporter.cancel()
        replacementGate.resume()
        for _ in 0 ..< 100 where !replacementResumed {
            await Task.yield()
        }
        XCTAssertTrue(replacementResumed)
        XCTAssertFalse(exporter.isRunning)
        XCTAssertNil(exporter.file)
        XCTAssertFalse(exporter.isPresented)
    }
}

@MainActor
private final class ExportResumeGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
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
        let letter = IOSPrintPage.defaultImageableRect(locale: Locale(identifier: "en_US"))
        XCTAssertEqual(letter, CGRect(x: 36, y: 36, width: 540, height: 720))
        XCTAssertEqual(
            IOSPrintPage.defaultImageableAspect(locale: Locale(identifier: "en_US")),
            720.0 / 540.0,
            accuracy: 0.0001
        )
        let a4 = IOSPrintPage.defaultImageableRect(locale: Locale(identifier: "zh_TW"))
        XCTAssertEqual(a4.origin, CGPoint(x: 36, y: 36))
        XCTAssertEqual(a4.width, IOSPrintPage.a4.width - 72, accuracy: 0.001)
        XCTAssertEqual(a4.height, IOSPrintPage.a4.height - 72, accuracy: 0.001)
    }
}
