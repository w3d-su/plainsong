import AppKit
import MarkdownCore
import PDFKit
@testable import Plainsong
@testable import PreviewKit
@testable import WorkspaceKit
import XCTest

/// E1 + B2 hosted coverage on the Print path (`docs/export-gates.md` D4, owner
/// decision 2026-10-09): a table wider than `baseline / printWideFraction` is
/// isolated onto its own sheets on A4 portrait and landscape, prose sheets keep the
/// baseline width, and the content-measured height leaves no blank sheet. These
/// drive the `printOperationRunner` seam, never the real CUPS path.
@MainActor
final class ExportPrintWideRunsAppTests: XCTestCase {
    /// A ~4,700 pt table in the middle of a long post on A4 portrait: the run's
    /// sheets hold only the table, prose sheets keep the baseline width, and every
    /// marker survives once and in order on the captured print PDF.
    func testWideTableRunIsolatesOnA4Portrait() async throws {
        try await assertWideTablePrint(orientation: .portrait)
    }

    /// The same table on landscape paper: imageable bounds swap, the planner's soft
    /// budget changes shape, but the run is still isolated and prose stays at
    /// baseline width.
    func testWideTableRunIsolatesOnA4Landscape() async throws {
        try await assertWideTablePrint(orientation: .landscape)
    }

    /// The B2 shape on Print: 300 paragraphs, a quote containing a list and a wide
    /// table, 300 paragraphs — the captured print PDF holds no blank sheet.
    func testQuoteListTableShapePrintsNoBlankSheets() async throws {
        let support = ExportHTMLCommandAppTests()
        let (before, beforeMarkers) = ExportPDFWideRunsAppSupport.wrappingProse(
            prefix: "PB2BEFORE", count: 300
        )
        let (after, afterMarkers) = ExportPDFWideRunsAppSupport.wrappingProse(
            prefix: "PB2AFTER", count: 300
        )
        let columnMarkers = (0 ..< 30).map { String(format: "PB2COL%02dSENTINEL", $0) }
        var bodyCells = ["PB2CELLSENTINEL"]
        bodyCells.append(contentsOf: [String](repeating: "cell", count: columnMarkers.count - 1))
        let bodyRow = "| " + bodyCells.joined(separator: " | ") + " |"
        let table = ExportPDFWideRunsAppSupport.tableSource(
            headerRow: columnMarkers, bodyRows: [bodyRow]
        )
        var quoteLines = [
            "> - PB2LISTSENTINEL quoted list item",
            ">",
        ]
        quoteLines.append(contentsOf: table.split(separator: "\n").map { ">   \($0)" })
        let quote = quoteLines.joined(separator: "\n")
        let fixture = try support.makeFixture(text: [
            before, quote, after,
        ].joined(separator: "\n\n"))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let document = try await printFixture(fixture, orientation: .portrait)
        let controller = try await ExportPDFWideRunsAppSupport.preparedController(
            [before, quote, after].joined(separator: "\n\n")
        )
        defer { controller.invalidate() }
        let captured = try await controller.captureExportPDF(pageAspect: 1.29)
        XCTAssertEqual(captured.droppedTrailingBlankPages, 0)
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
        XCTAssertEqual(
            captured.contentSize.height, CGFloat(lastChildBottom ?? -1), accuracy: 60
        )
        ExportPDFWideRunsAppSupport.assertNoBlankPage(document)
        let text = Self.text(of: document)
        // Prose and the quote's list lead the table in extraction order; inside the
        // table itself PDFKit's reading order is not DOM order, so its markers are
        // asserted once-only rather than in a fixed sequence.
        try ExportPDFMechanismSpikeTests.assertEverySentinelAppearsOnceInOrder(
            Self.markers(beforeMarkers, ["PB2LISTSENTINEL"], afterMarkers),
            in: text
        )
        for marker in Self.markers(columnMarkers, ["PB2CELLSENTINEL"]) {
            XCTAssertEqual(
                ExportPDFMechanismSpikeTests.occurrences(of: marker, in: text as NSString).count,
                1, marker
            )
        }
    }

    func testAdjacentWideCodeBlocksUseDistinctA4SheetWidths() async throws {
        let support = ExportHTMLCommandAppTests()
        let narrow = "SMALLCODESENTINEL" + String(repeating: "A", count: 126)
        let wide = "LARGECODESENTINEL" + String(repeating: "B", count: 393)
        let source = ["```text\n\(narrow)\n```", "```text\n\(wide)\n```"]
            .joined(separator: "\n\n")
        let fixture = try support.makeFixture(text: source)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let document = try await printFixture(fixture, orientation: .portrait)
        XCTAssertEqual(document.pageCount, 2)
        let controller = try await ExportPDFWideRunsAppSupport.preparedController(source)
        defer { controller.invalidate() }
        try await controller.applyExportOverflowStyle()
        let contentSize = try await controller.settleExportGeometry()
        let measurement = try await controller.measureUnsplittableSpans()
        let measuredWidths = try await controller.webView.evaluateJavaScript("""
        (() => Array.from(document.querySelectorAll("pre")).map(pre => {
          const rect = pre.getBoundingClientRect();
          return rect.left + Math.max(rect.width, pre.scrollWidth);
        }))()
        """)
        let measuredRightEdges = try XCTUnwrap(measuredWidths as? [Double])
        let measuredBlockWidths = measuredRightEdges.map { rightEdge in
            let width = min(max(CGFloat(rightEdge), measurement.baselineWidth), contentSize.width)
            return width > ExportPDFPagePlanner.maximumSide
                ? width + ExportPDFPagePlanner.widePageSlack
                : width
        }
        XCTAssertEqual(measuredBlockWidths.count, 2)
        XCTAssertEqual(measuredBlockWidths[0], 1265, accuracy: 60)
        XCTAssertEqual(measuredBlockWidths[1], 3401, accuracy: 60)
        let narrowPage = try XCTUnwrap((0 ..< document.pageCount).first { index in
            document.page(at: index)?.string?.contains("SMALLCODESENTINEL") == true
        })
        let widePage = try XCTUnwrap((0 ..< document.pageCount).first { index in
            document.page(at: index)?.string?.contains("LARGECODESENTINEL") == true
        })
        let narrowWidth = try XCTUnwrap(document.page(at: narrowPage)).bounds(for: .mediaBox).width
        let wideWidth = try XCTUnwrap(document.page(at: widePage)).bounds(for: .mediaBox).width
        XCTAssertLessThan(narrowWidth, wideWidth)
        XCTAssertEqual(narrowWidth, measuredBlockWidths[0], accuracy: 60)
        XCTAssertEqual(wideWidth, measuredBlockWidths[1], accuracy: 60)
    }

    /// kitchen-sink.mdx prints the same number of sheets it did before the run
    /// work — a regression pin. On explicit A4 portrait the pre-20c planner
    /// measured 2 sheets; 20c's clipped-placeholder run pushed it to 4 (a blank
    /// sheet, a 14 pt strip, then the body). With clipped text ignored the count
    /// returns to 2.
    func testKitchenSinkMdxPrintKeepsItsSheetCount() async throws {
        let support = ExportHTMLCommandAppTests()
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "kitchen-sink", withExtension: "mdx"))
        let source = try String(contentsOf: url, encoding: .utf8)
        let fixture = try support.makeFixture(name: "kitchen-sink.mdx", text: source)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let document = try await printFixture(fixture, orientation: .portrait)
        XCTAssertEqual(document.pageCount, Self.kitchenSinkPrintSheetCount)
    }

    /// X2: an ordinary Astro post whose two long `import` lines render as clipped
    /// `.mdx-esm-placeholder` pills must print on one sheet — text the pill hides
    /// behind `overflow: hidden` is not painted, so it cannot form a wide run.
    /// Before the clip fix the measured text edge produced a run and three sheets.
    func testMdxPostWithTwoLongImportLinesPrintsOnOneSheet() async throws {
        let support = ExportHTMLCommandAppTests()
        let source = """
        ---
        title: Two imports
        ---
        import { Tabs, TabItem, Aside, Card, CardGrid, LinkButton, FileTree, Steps } from '@astrojs/starlight/components';
        import MyLongComponentName from '../../../components/demo/MyLongComponentNameForPlaceholderClipping.astro';

        # Two imports

        IMPORTBODYSENTINEL A short post body.
        """
        let fixture = try support.makeFixture(name: "imports-post.mdx", text: source)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let document = try await printFixture(fixture, orientation: .portrait)
        XCTAssertEqual(document.pageCount, 1)
        // No run: the one page keeps the baseline width — a clipped-placeholder
        // run would have widened its page to the hidden text's right edge.
        let box = try XCTUnwrap(document.page(at: 0)?.bounds(for: .mediaBox))
        XCTAssertLessThan(box.width, 900)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("IMPORTBODYSENTINEL") == true)
    }

    /// The shared wide-table Print body: run pages hold the table markers and are
    /// wider than baseline; every other page keeps the baseline width.
    private func assertWideTablePrint(
        orientation: NSPrintInfo.PaperOrientation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let support = ExportHTMLCommandAppTests()
        let (before, beforeMarkers) = Self.prose(prefix: "PRTBEFORE", count: 150)
        let (after, afterMarkers) = Self.prose(prefix: "PRTAFTER", count: 150)
        let columnMarkers = (0 ..< 10).map { String(format: "PRTBLCOL%02dSENTINEL", $0) }
        let header = columnMarkers.map { $0 + String(repeating: "x", count: 90) }
        let rowMarkers = (0 ..< 60).map { String(format: "PRTBLROW%04dSENTINEL", $0) }
        let table = ExportPDFWideRunsAppSupport.tableSource(
            headerRow: header, bodyRows: rowMarkers.map { "| \($0) |" }
        )
        let fixture = try support.makeFixture(
            text: [before, table, after].joined(separator: "\n\n")
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let document = try await printFixture(fixture, orientation: orientation)
        var runSheets = 0
        for index in 0 ..< document.pageCount {
            let page: PDFPage = try XCTUnwrap(document.page(at: index), file: file, line: line)
            let box = page.bounds(for: .mediaBox)
            XCTAssertLessThanOrEqual(box.width, 14400.5, file: file, line: line)
            XCTAssertLessThanOrEqual(box.height, 14400.5, file: file, line: line)
            let text = page.string ?? ""
            // Isolation is about the markers too, not only the width: a run sheet
            // holds table markers and no prose, a prose sheet the reverse — a
            // sheet with both mixes the run, a sheet with neither is blank.
            let holdsTable = text.contains("PRTBLCOL") || text.contains("PRTBLROW")
            let holdsProse = text.contains("PRTBEFORE") || text.contains("PRTAFTER")
            XCTAssertNotEqual(
                holdsTable, holdsProse,
                "\(orientation) sheet \(index + 1) mixes run and prose markers (or is blank)",
                file: file, line: line
            )
            if holdsTable {
                runSheets += 1
                XCTAssertGreaterThan(
                    box.width, 1100,
                    "\(orientation) run sheet \(index + 1) must be wider than baseline",
                    file: file, line: line
                )
            } else {
                XCTAssertLessThan(
                    box.width, 1100,
                    "\(orientation) prose sheet \(index + 1) must keep baseline width",
                    file: file, line: line
                )
            }
        }
        XCTAssertGreaterThan(runSheets, 0, "\(orientation): no sheet held the table", file: file, line: line)
        let text = Self.text(of: document)
        try ExportPDFMechanismSpikeTests.assertEverySentinelAppearsOnceInOrder(
            Self.markers(beforeMarkers, columnMarkers, rowMarkers, afterMarkers),
            in: text
        )
    }

    /// Prints the fixture's document on a fake panel (the runner answers "printed")
    /// and returns the PDFDocument the operation would have sent to the printer.
    private func printFixture(
        _ fixture: ExportHTMLCommandAppTests.Fixture,
        orientation: NSPrintInfo.PaperOrientation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> PDFDocument {
        fixture.appState.exportHTMLOperations.printInfoProvider = {
            Self.a4PrintInfo(orientation: orientation)
        }
        var observed: PDFDocument?
        fixture.appState.exportHTMLOperations.printDocumentObserver = { observed = $0 }
        fixture.appState.exportHTMLOperations.printOperationRunner = { _, _ in true }
        var results: [ExportHTMLOperationResult] = []
        fixture.appState.exportHTMLOperations.didFinishOperation = { _, result in
            results.append(result)
        }
        try await XCTUnwrap(fixture.appState.printCurrentDocument(), file: file, line: line).value
        XCTAssertEqual(results, [.printed], file: file, line: line)
        let document = try XCTUnwrap(
            observed, "printDocumentObserver saw nothing", file: file, line: line
        )
        ExportPDFWideRunsAppSupport.assertNoBlankPage(document, file: file, line: line)
        let controller = try await ExportPDFWideRunsAppSupport.preparedController(
            fixture.session.text, fileKind: fixture.session.fileKind
        )
        defer { controller.invalidate() }
        let bounds = Self.a4PrintInfo(orientation: orientation).imageablePageBounds
        let startedAt = Date()
        let capture = try await controller.captureExportPDF(
            pageAspect: bounds.height / bounds.width
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        XCTAssertEqual(capture.droppedTrailingBlankPages, 0, file: file, line: line)
        XCTAssertEqual(document.pageCount, capture.plannedPageCount, file: file, line: line)
        print(String(
            format: "E1 PRINT CAPTURE pages=%d planned=%d widest=%.1fpt minScale=%.3f time=%.2fs",
            document.pageCount,
            capture.plannedPageCount,
            capture.pageWidths.max() ?? 0,
            capture.minimumScale,
            elapsed
        ))
        return document
    }

    /// kitchen-sink.mdx measured on explicit A4 portrait: two sheets — the pre-20c
    /// count the clipped-text fix restores. If a style or planner change shifts it,
    /// update the pin deliberately rather than silently.
    private static let kitchenSinkPrintSheetCount = 2

    /// Explicit A4 through the print-info seam (low 4): paper size and margins are
    /// fixed so the sheet counts never depend on the system default paper.
    /// `imageablePageBounds` comes back (18, 41, 559, 783) portrait.
    private static func a4PrintInfo(orientation: NSPrintInfo.PaperOrientation) -> NSPrintInfo {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        info.leftMargin = 18
        info.rightMargin = 18
        info.topMargin = 41
        info.bottomMargin = 18
        info.orientation = orientation
        return info
    }

    private static func prose(prefix: String, count: Int) -> (markdown: String, markers: [String]) {
        let markers = (0 ..< count).map { String(format: "%@%04d", prefix, $0) }
        let markdown = markers.map { "\($0) prose paragraph." }.joined(separator: "\n\n")
        return (markdown, markers)
    }

    /// Marker groups flattened in order — a typed helper instead of `+` chains.
    private static func markers(_ groups: [String]...) -> [String] {
        groups.flatMap { $0 }
    }

    private static func text(of document: PDFDocument) -> String {
        (0 ..< document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }
}
