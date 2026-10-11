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
/// PDF page, and the content-measured height leaves no trailing blank page. The 20d
/// edge cases live in `ExportPDFWideRunsEdgeAppTests`; shared fixtures and
/// invariants in `ExportPDFWideRunsAppSupport`.
@MainActor
final class ExportPDFWideRunsAppTests: XCTestCase {
    private typealias Support = ExportPDFWideRunsAppSupport

    /// The B1 shape that terminated WebContent: a 1,950,298 pt minified line in the
    /// middle of a long post. With isolation plus the cap the file is written, the
    /// C2 warning names the run's pages and the percentage, and the prose on either
    /// side keeps baseline width at scale 1.
    func testMinifiedLineRunInALongPostWritesWithAShrunkWarning() async throws {
        let support = ExportHTMLCommandAppTests()
        let (before, beforeMarkers) = Support.prose(prefix: "BEFOREPROSE", count: 300)
        let (after, afterMarkers) = Support.prose(prefix: "AFTERPROSE", count: 300)
        // The sentinel ends the line: WebKit paints a line's tail a few points
        // past the right edge the geometry measurement reports, so a capture cut
        // exactly at the measured edge used to drop the last glyphs —
        // `widePageSlack` of capture overscan restores them (`docs/perf-log.md`).
        let line = String(repeating: "W", count: 240_000) + "MINIFIEDSENTINEL"
        // A bare fence sends the 240k-char line through highlight.js auto-detect
        // (~113 s — past the 15 s render timeout); `text` renders the same
        // 1,950,298 pt line in under a second.
        let source = [before, "```text\n" + line + "\n```", after].joined(separator: "\n\n")
        let (directController, directPDF) = try await Support.capture(source)
        defer { directController.invalidate() }
        let directDocument = try XCTUnwrap(PDFDocument(data: directPDF.data))
        Support.assertNoBlankPage(directDocument)
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
        XCTAssertFalse(shrunkPages.isEmpty, "A 1,950,298 pt run must shrink at least one page")
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
            Support.markers(beforeMarkers, ["MINIFIEDSENTINEL"], afterMarkers),
            in: Support.text(of: data)
        )
    }

    /// A ~114,000 pt wide table of a few hundred rows in the middle of a long post:
    /// the run's pages hold only the table, prose pages keep baseline width and
    /// scale 1, and one planned page comes back as exactly one PDF page.
    func testVeryWideTableRunIsolatesAndCapsEveryPage() async throws {
        let (before, beforeMarkers) = Support.prose(prefix: "TBLBEFORE", count: 150)
        let (after, afterMarkers) = Support.prose(prefix: "TBLAFTER", count: 150)
        let columnMarkers = (0 ..< 40).map { String(format: "WIDETBLCOL%02dSENTINEL", $0) }
        let header = columnMarkers.map { $0 + String(repeating: "x", count: 520) }
        let rowMarkers = (0 ..< 200).map { String(format: "TBLROW%04dSENTINEL", $0) }
        let rows = rowMarkers.map { "| \($0) |" }
        let table = Support.tableSource(headerRow: header, bodyRows: rows)
        let source = [before, table, after].joined(separator: "\n\n")
        let (controller, pdf) = try await Support.capture(source)
        defer { controller.invalidate() }
        XCTAssertGreaterThan(pdf.contentSize.width, 100_000)
        XCTAssertLessThanOrEqual(pdf.maximumPageHeight, 14400)
        XCTAssertEqual(pdf.pageCount, pdf.plannedPageCount)
        let document = try XCTUnwrap(PDFDocument(data: pdf.data))
        XCTAssertEqual(document.pageCount, pdf.plannedPageCount)
        Support.assertRunPagesShrinkProsePagesDoNot(pdf: pdf, document: document)
        Support.assertNoPageMixesMarkers(
            document,
            runMarkerPrefixes: ["WIDETBLCOL", "TBLROW"],
            proseMarkerPrefixes: ["TBLBEFORE", "TBLAFTER"]
        )
        try ExportPDFMechanismSpikeTests.assertEverySentinelAppearsOnceInOrder(
            Support.markers(beforeMarkers, columnMarkers, rowMarkers, afterMarkers),
            in: Support.text(of: pdf.data)
        )
    }

    /// A ~24,000 pt table in the middle: the run's pages land near scale 0.58, the
    /// neighbouring prose pages stay at scale 1, and WebKit does not split a planned
    /// capture on its own (planned == captured).
    func testMidWidthTableRunScalesNeighboursStayWhole() async throws {
        let (before, beforeMarkers) = Support.prose(prefix: "MIDBEFORE", count: 150)
        let (after, afterMarkers) = Support.prose(prefix: "MIDAFTER", count: 150)
        let columnMarkers = (0 ..< 24).map { String(format: "MIDTBLCOL%02dSENTINEL", $0) }
        let header = columnMarkers.map { $0 + String(repeating: "x", count: 100) }
        let rowMarkers = (0 ..< 60).map { String(format: "MIDTBLROW%04dSENTINEL", $0) }
        let rows = rowMarkers.map { "| \($0) |" }
        let table = Support.tableSource(headerRow: header, bodyRows: rows)
        let source = [before, table, after].joined(separator: "\n\n")
        let (controller, pdf) = try await Support.capture(source)
        defer { controller.invalidate() }
        XCTAssertGreaterThan(pdf.contentSize.width, 20000)
        XCTAssertEqual(pdf.pageCount, pdf.plannedPageCount)
        let document = try XCTUnwrap(PDFDocument(data: pdf.data))
        XCTAssertEqual(document.pageCount, pdf.plannedPageCount)
        XCTAssertEqual(pdf.minimumScale, 14400 / pdf.contentSize.width, accuracy: 0.01)
        Support.assertRunPagesShrinkProsePagesDoNot(pdf: pdf, document: document)
        Support.assertNoPageMixesMarkers(
            document,
            runMarkerPrefixes: ["MIDTBLCOL", "MIDTBLROW"],
            proseMarkerPrefixes: ["MIDBEFORE", "MIDAFTER"]
        )
        try ExportPDFMechanismSpikeTests.assertEverySentinelAppearsOnceInOrder(
            Support.markers(beforeMarkers, columnMarkers, rowMarkers, afterMarkers),
            in: Support.text(of: pdf.data)
        )
    }

    /// The B2 shape: 300 paragraphs, a quote containing a list and a 30-column table,
    /// then 300 paragraphs. The last page holds content and no page is left blank.
    func testQuoteListTableShapeLeavesNoBlankTail() async throws {
        let (before, beforeMarkers) = Support.wrappingProse(prefix: "B2BEFORE", count: 300)
        let (after, afterMarkers) = Support.wrappingProse(prefix: "B2AFTER", count: 300)
        let columnMarkers = (0 ..< 30).map { String(format: "B2COL%02dSENTINEL", $0) }
        var bodyCells = ["B2CELLSENTINEL"]
        bodyCells.append(contentsOf: [String](repeating: "cell", count: columnMarkers.count - 1))
        let bodyRow = "| " + bodyCells.joined(separator: " | ") + " |"
        let table = Support.tableSource(headerRow: columnMarkers, bodyRows: [bodyRow])
        var quoteLines = [
            "> - B2LISTSENTINEL quoted list item",
            ">",
        ]
        quoteLines.append(contentsOf: table.split(separator: "\n").map { ">   \($0)" })
        let quote = quoteLines.joined(separator: "\n")
        let source = [before, quote, after].joined(separator: "\n\n")
        let (controller, pdf) = try await Support.capture(source)
        defer { controller.invalidate() }
        let lastChildBottom = try await controller.webView.evaluateJavaScript("""
        (() => {
          const root = document.getElementById("preview-root");
          const style = getComputedStyle(root);
          const padB = parseFloat(style.paddingBottom) || 0;
          const borderB = parseFloat(style.borderBottomWidth) || 0;
          return root.lastElementChild.getBoundingClientRect().bottom
            + window.scrollY + padB + borderB;
        })()
        """) as? Double
        XCTAssertEqual(pdf.contentSize.height, CGFloat(lastChildBottom ?? -1), accuracy: 60)
        XCTAssertEqual(pdf.droppedTrailingBlankPages, 0)
        XCTAssertEqual(pdf.pageCount, pdf.plannedPageCount)
        let document = try XCTUnwrap(PDFDocument(data: pdf.data))
        XCTAssertEqual(document.pageCount, pdf.plannedPageCount)
        Support.assertNoBlankPage(document)
        let last = try XCTUnwrap(document.page(at: document.pageCount - 1)?.string)
        XCTAssertFalse(last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        try ExportPDFMechanismSpikeTests.assertEverySentinelAppearsOnceInOrder(
            Support.markers(
                beforeMarkers, ["B2LISTSENTINEL"], columnMarkers,
                ["B2CELLSENTINEL"], afterMarkers
            ),
            in: Support.text(of: pdf.data)
        )
    }

    /// A wide code line near the end of a long post: the run's page is the last
    /// content, and the file ends without a trailing blank page.
    func testWideCodeLineNearTheEndLeavesNoBlankTail() async throws {
        let (before, beforeMarkers) = Support.prose(prefix: "CODEBEFORE", count: 200)
        let line = String(repeating: "W", count: 6000) + "WIDECODESENTINEL"
        let tail = "LASTPARAGRAPHSENTINEL closing prose."
        let source = [before, "```\n" + line + "\n```", tail].joined(separator: "\n\n")
        let (controller, pdf) = try await Support.capture(source)
        defer { controller.invalidate() }
        XCTAssertEqual(pdf.pageCount, pdf.plannedPageCount)
        let document = try XCTUnwrap(PDFDocument(data: pdf.data))
        XCTAssertEqual(document.pageCount, pdf.plannedPageCount)
        Support.assertNoBlankPage(document)
        let last = try XCTUnwrap(document.page(at: document.pageCount - 1)?.string)
        XCTAssertTrue(last.contains("LASTPARAGRAPHSENTINEL"))
        try ExportPDFMechanismSpikeTests.assertEverySentinelAppearsOnceInOrder(
            Support.markers(beforeMarkers, ["WIDECODESENTINEL", "LASTPARAGRAPHSENTINEL"]),
            in: Support.text(of: pdf.data)
        )
    }

    /// The M1 boundary shape: the ~4,700 pt table that Print isolates (it is wider
    /// than `baseline / printWideFraction`) is narrower than PDF's `maximumSide`
    /// threshold, so PDF forms no run — every page is scale 1, the table's pages
    /// widen to their own extents, and prose may share a page with the table.
    func testPrintWideTableDoesNotIsolateForPDF() async throws {
        let (before, beforeMarkers) = Support.prose(prefix: "PRWIDEBEFORE", count: 150)
        let (after, afterMarkers) = Support.prose(prefix: "PRWIDEAFTER", count: 150)
        let columnMarkers = (0 ..< 10).map { String(format: "PRWIDECOL%02dSENTINEL", $0) }
        let header = columnMarkers.map { $0 + String(repeating: "x", count: 90) }
        let rowMarkers = (0 ..< 60).map { String(format: "PRWIDEROW%04dSENTINEL", $0) }
        let rows = rowMarkers.map { "| \($0) |" }
        let table = Support.tableSource(headerRow: header, bodyRows: rows)
        let source = [before, table, after].joined(separator: "\n\n")
        let (controller, pdf) = try await Support.capture(source)
        defer { controller.invalidate() }
        // Wide for Print (> 800 / 0.9) but under the PDF threshold: no run, no
        // mandatory breaks, no scaling.
        XCTAssertGreaterThan(pdf.contentSize.width, 900)
        XCTAssertLessThan(pdf.contentSize.width, 14400)
        XCTAssertEqual(pdf.pageCount, pdf.plannedPageCount)
        XCTAssertEqual(pdf.minimumScale, 1)
        let document = try XCTUnwrap(PDFDocument(data: pdf.data))
        XCTAssertEqual(document.pageCount, pdf.plannedPageCount)
        Support.assertNoBlankPage(document)
        var tablePages = 0
        var mixedPages = 0
        for index in 0 ..< document.pageCount {
            let box = try XCTUnwrap(document.page(at: index)).bounds(for: .mediaBox)
            let text = document.page(at: index)?.string ?? ""
            let holdsTable = text.contains("PRWIDECOL") || text.contains("PRWIDEROW")
            let holdsProse = text.contains("PRWIDEBEFORE") || text.contains("PRWIDEAFTER")
            if holdsTable {
                tablePages += 1
                // The page grows to the table's own width — under 14,400 — and is
                // still emitted at scale 1, not isolated onto mandatory boundaries.
                XCTAssertGreaterThan(box.width, 900)
                XCTAssertEqual(pdf.pageScales[index], 1)
            }
            if holdsTable, holdsProse {
                mixedPages += 1
            }
        }
        XCTAssertGreaterThan(tablePages, 0, "No page held the table")
        XCTAssertGreaterThan(
            mixedPages, 0,
            "With no run, prose should share at least one page with the table"
        )
        try ExportPDFMechanismSpikeTests.assertEverySentinelAppearsOnceInOrder(
            Support.markers(beforeMarkers, columnMarkers, rowMarkers, afterMarkers),
            in: Support.text(of: pdf.data)
        )
    }

    /// The MDX kitchen sink still exports as one page.
    func testKitchenSinkMdxStillOnePage() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "kitchen-sink", withExtension: "mdx"))
        let source = try String(contentsOf: url, encoding: .utf8)
        let (controller, pdf) = try await Support.capture(source, fileKind: .mdx)
        defer { controller.invalidate() }
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertEqual(pdf.plannedPageCount, 1)
        let document = try XCTUnwrap(PDFDocument(data: pdf.data))
        XCTAssertEqual(document.pageCount, 1)
    }

    /// Lows: the measured baseline the planner paginates against is the root's
    /// export border edge — a future `#preview-root` style change must fail here.
    func testMeasuredBaselineEqualsTheRootExportWidth() async throws {
        let controller = try await Support.preparedController("# Baseline\n\nSome prose.\n")
        defer { controller.invalidate() }
        _ = try await controller.captureExportPDF()
        let measured = try await controller.measureUnsplittableSpans()
        let edge = try await controller.webView.evaluateJavaScript(
            "Math.ceil(document.getElementById('preview-root').getBoundingClientRect().right + window.scrollX)"
        ) as? Double
        XCTAssertEqual(measured.baselineWidth, CGFloat(edge ?? -1), accuracy: 1)
        XCTAssertGreaterThan(measured.baselineWidth, 700)
    }
}
