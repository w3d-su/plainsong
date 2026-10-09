import AppKit
import MarkdownCore
import PDFKit
@testable import Plainsong
@testable import PreviewKit
@testable import WorkspaceKit
import XCTest

/// E1 + B2 hosted coverage (`docs/export-gates.md` D4, owner decision 2026-10-09):
/// very wide content is isolated onto its own pages, every page stays under the flat
/// 14,400 CSS pt cap whatever its width, one planned page comes back as exactly one
/// PDF page, and the content-measured height leaves no trailing blank page.
@MainActor
final class ExportPDFWideRunsAppTests: XCTestCase {
    /// The B1 shape that terminated WebContent: a ~1.1M pt minified line in the
    /// middle of a long post. With isolation plus the cap the file is written, the
    /// C2 warning names the run's pages and the percentage, and the prose on either
    /// side keeps baseline width at scale 1.
    func testMinifiedLineRunInALongPostWritesWithAShrunkWarning() async throws {
        let support = ExportHTMLCommandAppTests()
        let (before, beforeMarkers) = Self.prose(prefix: "BEFOREPROSE", count: 300)
        let (after, afterMarkers) = Self.prose(prefix: "AFTERPROSE", count: 300)
        // The sentinel leads the line: at scale ~0.007 the line's last glyphs sit
        // within a fraction of a point of the 14,400 pt media-box edge and WebKit's
        // PDF output drops the tail dozen, so an end-of-line sentinel cannot be
        // extracted even though the DOM carries it (`docs/perf-log.md`).
        let line = "MINIFIEDSENTINEL" + String(repeating: "W", count: 240_000)
        // A bare fence sends the 240k-char line through highlight.js auto-detect
        // (~113 s — past the 15 s render timeout); `text` renders the same
        // 1.14M pt line in under a second.
        let source = [before, "```text\n" + line + "\n```", after].joined(separator: "\n\n")
        let fixture = try support.makeFixture(text: source)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.exportsDirectory.appendingPathComponent("minified-run.pdf")
        let recorder = fixture.record(returning: [destination])
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsPDF()).value
        guard case let .exported(_, _, shrunkPages) = recorder.results.first?.result else {
            return XCTFail("Expected a committed export, got \(recorder.results)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let data = try Data(contentsOf: destination)
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertFalse(shrunkPages.isEmpty, "A ~1.1M pt run must shrink at least one page")
        let notice = try XCTUnwrap(fixture.appState.exportHTMLNotice)
        XCTAssertEqual(notice.group, .exportedWithShrunkPages)
        XCTAssertEqual(notice.severity, .warning)
        for page in shrunkPages {
            XCTAssertTrue(
                notice.message.contains("Page \(page.pageNumber)"),
                "The notice must name page \(page.pageNumber): \(notice.message)"
            )
        }
        XCTAssertTrue(notice.message.contains("%"))
        // Only the run's pages shrink; prose pages keep the baseline width.
        for index in 0 ..< document.pageCount {
            let box = try XCTUnwrap(document.page(at: index)).bounds(for: .mediaBox)
            XCTAssertLessThanOrEqual(box.width, 14400.5)
            XCTAssertLessThanOrEqual(box.height, 14400.5)
            if shrunkPages.contains(where: { $0.pageNumber == index + 1 }) {
                continue
            }
            XCTAssertLessThan(
                box.width, 1100,
                "Prose page \(index + 1) must keep the baseline width, got \(box.width)"
            )
        }
        try ExportPDFMechanismSpikeTests.assertEverySentinelAppearsOnceInOrder(
            beforeMarkers + ["MINIFIEDSENTINEL"] + afterMarkers,
            in: Self.text(of: data)
        )
    }

    /// A ~114,000 pt wide table of a few hundred rows in the middle of a long post:
    /// the run's pages hold only the table, prose pages keep baseline width and
    /// scale 1, and one planned page comes back as exactly one PDF page.
    func testVeryWideTableRunIsolatesAndCapsEveryPage() async throws {
        let (before, beforeMarkers) = Self.prose(prefix: "TBLBEFORE", count: 150)
        let (after, afterMarkers) = Self.prose(prefix: "TBLAFTER", count: 150)
        let columnMarkers = (0 ..< 40).map { String(format: "WIDETBLCOL%02dSENTINEL", $0) }
        let header = columnMarkers.map { $0 + String(repeating: "x", count: 520) }
        let rowMarkers = (0 ..< 200).map { String(format: "TBLROW%04dSENTINEL", $0) }
        let rows = rowMarkers.map { "| \($0) |" }
        let table = Self.tableSource(headerRow: header, bodyRows: rows)
        let source = [before, table, after].joined(separator: "\n\n")
        let (controller, pdf) = try await capture(source)
        defer { controller.invalidate() }
        XCTAssertGreaterThan(pdf.contentSize.width, 100_000)
        XCTAssertLessThanOrEqual(pdf.maximumPageHeight, 14400)
        XCTAssertEqual(pdf.pageCount, pdf.plannedPageCount)
        let document = try XCTUnwrap(PDFDocument(data: pdf.data))
        XCTAssertEqual(document.pageCount, pdf.plannedPageCount)
        Self.assertRunPagesShrinkProsePagesDoNot(pdf: pdf, document: document)
        try ExportPDFMechanismSpikeTests.assertEverySentinelAppearsOnceInOrder(
            beforeMarkers + columnMarkers + rowMarkers + afterMarkers,
            in: Self.text(of: pdf.data)
        )
    }

    /// A ~24,000 pt table in the middle: the run's pages land near scale 0.58, the
    /// neighbouring prose pages stay at scale 1, and WebKit does not split a planned
    /// capture on its own (planned == captured).
    func testMidWidthTableRunScalesNeighboursStayWhole() async throws {
        let (before, beforeMarkers) = Self.prose(prefix: "MIDBEFORE", count: 150)
        let (after, afterMarkers) = Self.prose(prefix: "MIDAFTER", count: 150)
        let columnMarkers = (0 ..< 24).map { String(format: "MIDTBLCOL%02dSENTINEL", $0) }
        let header = columnMarkers.map { $0 + String(repeating: "x", count: 100) }
        let rowMarkers = (0 ..< 60).map { String(format: "MIDTBLROW%04dSENTINEL", $0) }
        let rows = rowMarkers.map { "| \($0) |" }
        let table = Self.tableSource(headerRow: header, bodyRows: rows)
        let source = [before, table, after].joined(separator: "\n\n")
        let (controller, pdf) = try await capture(source)
        defer { controller.invalidate() }
        XCTAssertGreaterThan(pdf.contentSize.width, 20000)
        XCTAssertEqual(pdf.pageCount, pdf.plannedPageCount)
        let document = try XCTUnwrap(PDFDocument(data: pdf.data))
        XCTAssertEqual(document.pageCount, pdf.plannedPageCount)
        XCTAssertEqual(pdf.minimumScale, 14400 / pdf.contentSize.width, accuracy: 0.01)
        Self.assertRunPagesShrinkProsePagesDoNot(pdf: pdf, document: document)
        try ExportPDFMechanismSpikeTests.assertEverySentinelAppearsOnceInOrder(
            beforeMarkers + columnMarkers + rowMarkers + afterMarkers,
            in: Self.text(of: pdf.data)
        )
    }

    /// The B2 shape: 300 paragraphs, a quote containing a list and a 30-column table,
    /// then 300 paragraphs. The last page holds content and no page is left blank.
    func testQuoteListTableShapeLeavesNoBlankTail() async throws {
        let (before, beforeMarkers) = Self.prose(prefix: "B2BEFORE", count: 300)
        let (after, afterMarkers) = Self.prose(prefix: "B2AFTER", count: 300)
        let columnMarkers = (0 ..< 30).map { String(format: "B2COL%02dSENTINEL", $0) }
        let quote = [
            "> - B2LISTSENTINEL quoted list item",
            ">",
            "> | " + columnMarkers.joined(separator: " | ") + " |",
            "> | " + [String](repeating: "---", count: columnMarkers.count).joined(separator: " | ") + " |",
            "> | B2CELLSENTINEL | " + [String](repeating: "cell", count: columnMarkers.count - 1)
                .joined(separator: " | ") + " |",
        ].joined(separator: "\n")
        let source = [before, quote, after].joined(separator: "\n\n")
        let (controller, pdf) = try await capture(source)
        defer { controller.invalidate() }
        XCTAssertEqual(pdf.pageCount, pdf.plannedPageCount)
        let document = try XCTUnwrap(PDFDocument(data: pdf.data))
        XCTAssertEqual(document.pageCount, pdf.plannedPageCount)
        Self.assertNoBlankPage(document)
        let last = try XCTUnwrap(document.page(at: document.pageCount - 1)?.string)
        XCTAssertFalse(last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        try ExportPDFMechanismSpikeTests.assertEverySentinelAppearsOnceInOrder(
            beforeMarkers + ["B2LISTSENTINEL"] + columnMarkers + ["B2CELLSENTINEL"]
                + afterMarkers,
            in: Self.text(of: pdf.data)
        )
    }

    /// A wide code line near the end of a long post: the run's page is the last
    /// content, and the file ends without a trailing blank page.
    func testWideCodeLineNearTheEndLeavesNoBlankTail() async throws {
        let (before, beforeMarkers) = Self.prose(prefix: "CODEBEFORE", count: 200)
        let line = String(repeating: "W", count: 6000) + "WIDECODESENTINEL"
        let tail = "LASTPARAGRAPHSENTINEL closing prose."
        let source = [before, "```\n" + line + "\n```", tail].joined(separator: "\n\n")
        let (controller, pdf) = try await capture(source)
        defer { controller.invalidate() }
        XCTAssertEqual(pdf.pageCount, pdf.plannedPageCount)
        let document = try XCTUnwrap(PDFDocument(data: pdf.data))
        XCTAssertEqual(document.pageCount, pdf.plannedPageCount)
        Self.assertNoBlankPage(document)
        let last = try XCTUnwrap(document.page(at: document.pageCount - 1)?.string)
        XCTAssertTrue(last.contains("LASTPARAGRAPHSENTINEL"))
        try ExportPDFMechanismSpikeTests.assertEverySentinelAppearsOnceInOrder(
            beforeMarkers + ["WIDECODESENTINEL", "LASTPARAGRAPHSENTINEL"],
            in: Self.text(of: pdf.data)
        )
    }

    /// The MDX kitchen sink still exports as one page.
    func testKitchenSinkMdxStillOnePage() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "kitchen-sink", withExtension: "mdx"))
        let source = try String(contentsOf: url, encoding: .utf8)
        let (controller, pdf) = try await capture(source, fileKind: .mdx)
        defer { controller.invalidate() }
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertEqual(pdf.plannedPageCount, 1)
        let document = try XCTUnwrap(PDFDocument(data: pdf.data))
        XCTAssertEqual(document.pageCount, 1)
    }

    /// Lows: the measured baseline the planner paginates against is the root's
    /// export border edge — a future `#preview-root` style change must fail here.
    func testMeasuredBaselineEqualsTheRootExportWidth() async throws {
        let controller = try await preparedController("# Baseline\n\nSome prose.\n")
        defer { controller.invalidate() }
        _ = try await controller.captureExportPDF()
        let measured = try await controller.measureUnsplittableSpans()
        let edge = try await controller.webView.evaluateJavaScript(
            "Math.ceil(document.getElementById('preview-root').getBoundingClientRect().right + window.scrollX)"
        ) as? Double
        XCTAssertEqual(measured.baselineWidth, CGFloat(edge ?? -1), accuracy: 1)
        XCTAssertGreaterThan(measured.baselineWidth, 700)
    }

    /// Run pages shrink to fit (scale < 1); every other page keeps the baseline
    /// width at scale 1 — prose never shrinks for somebody else's overflow.
    private static func assertRunPagesShrinkProsePagesDoNot(
        pdf: ExportPDFDocument,
        document: PDFDocument,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(pdf.pageScales.count, document.pageCount, file: file, line: line)
        for index in 0 ..< document.pageCount {
            let scale = pdf.pageScales[index]
            let box = document.page(at: index)?.bounds(for: .mediaBox) ?? .zero
            if scale < 1 {
                XCTAssertEqual(
                    box.width, 14400, accuracy: 1,
                    "Run page \(index + 1) must fill the user space", file: file, line: line
                )
            } else {
                XCTAssertEqual(
                    pdf.pageWidths[index], box.width, accuracy: 1,
                    file: file, line: line
                )
                XCTAssertLessThan(
                    box.width, 1100,
                    "Page \(index + 1) outside the run must keep baseline width",
                    file: file, line: line
                )
            }
            XCTAssertLessThanOrEqual(box.height, 14400.5, file: file, line: line)
        }
    }

    /// No output page is left blank: every page carries some text or drawing.
    private static func assertNoBlankPage(
        _ document: PDFDocument,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for index in 0 ..< document.pageCount {
            let text = document.page(at: index)?.string ?? ""
            XCTAssertFalse(
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Page \(index + 1) is blank",
                file: file, line: line
            )
        }
    }

    private static func prose(prefix: String, count: Int) -> (markdown: String, markers: [String]) {
        let markers = (0 ..< count).map { String(format: "%@%04d", prefix, $0) }
        let markdown = markers.map { "\($0) prose paragraph." }.joined(separator: "\n\n")
        return (markdown, markers)
    }

    /// One wide header row plus short single-cell body rows; the header drives the
    /// `max-content` table width while the rows give the run its height.
    private static func tableSource(headerRow: [String], bodyRows: [String]) -> String {
        let header = "| " + headerRow.joined(separator: " | ") + " |\n"
        let delimiter = "| " + [String](repeating: "---", count: headerRow.count)
            .joined(separator: " | ") + " |\n"
        return header + delimiter + bodyRows.joined(separator: "\n") + "\n"
    }

    private func capture(
        _ markdown: String,
        fileKind: FileKind = .markdown
    ) async throws -> (PreviewController, ExportPDFDocument) {
        let controller = try await preparedController(markdown, fileKind: fileKind)
        let start = Date()
        let pdf = try await controller.captureExportPDF()
        let seconds = Date().timeIntervalSince(start)
        print(String(
            format: "E1 CAPTURE pages=%d planned=%d widest=%.1fpt minScale=%.3f time=%.2fs content=%.0fx%.0f",
            pdf.pageCount, pdf.plannedPageCount, pdf.pageWidths.max() ?? 0,
            pdf.minimumScale, seconds, pdf.contentSize.width, pdf.contentSize.height
        ))
        return (controller, pdf)
    }

    private func preparedController(
        _ markdown: String,
        fileKind: FileKind = .markdown
    ) async throws -> PreviewController {
        let controller = try await PreviewController.makeHTMLExportController()
        controller.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        controller.setAllowsRemoteImages(false)
        controller.setTheme("light")
        let render = await controller.renderForExport(DocumentTextChange(
            text: markdown, version: 1, fileKind: fileKind, fileURL: nil
        ))
        guard case let .completed(renderID) = render else {
            controller.invalidate()
            throw ExportPDFCaptureError.captureFailed("render")
        }
        guard case .ready = await controller.exportHTML(matchingRenderID: renderID) else {
            controller.invalidate()
            throw ExportPDFCaptureError.captureFailed("barrier")
        }
        return controller
    }

    private static func text(of data: Data) -> String {
        guard let document = PDFDocument(data: data) else { return "" }
        return (0 ..< document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }
}
