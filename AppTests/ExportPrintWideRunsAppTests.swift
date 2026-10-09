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
        let (before, beforeMarkers) = Self.prose(prefix: "PB2BEFORE", count: 300)
        let (after, afterMarkers) = Self.prose(prefix: "PB2AFTER", count: 300)
        let columnMarkers = (0 ..< 10).map { String(format: "PB2COL%02dSENTINEL", $0) }
        let quote = [
            "> - PB2LISTSENTINEL quoted list item",
            ">",
            "> | " + columnMarkers.joined(separator: " | ") + " |",
            "> | " + [String](repeating: "---", count: columnMarkers.count).joined(separator: " | ") + " |",
            "> | PB2CELLSENTINEL | " + [String](repeating: "cell", count: columnMarkers.count - 1)
                .joined(separator: " | ") + " |",
        ].joined(separator: "\n")
        let fixture = try support.makeFixture(text: [before, quote, after].joined(separator: "\n\n"))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let document = try await printFixture(fixture, orientation: .portrait)
        for index in 0 ..< document.pageCount {
            let text = document.page(at: index)?.string ?? ""
            XCTAssertFalse(
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Sheet \(index + 1) is blank"
            )
        }
        let text = Self.text(of: document)
        // Prose and the quote's list lead the table in extraction order; inside the
        // table itself PDFKit's reading order is not DOM order, so its markers are
        // asserted once-only rather than in a fixed sequence.
        try ExportPDFMechanismSpikeTests.assertEverySentinelAppearsOnceInOrder(
            beforeMarkers + ["PB2LISTSENTINEL"] + afterMarkers,
            in: text
        )
        for marker in columnMarkers + ["PB2CELLSENTINEL"] {
            XCTAssertEqual(
                text.components(separatedBy: marker).count - 1, 1, marker
            )
        }
    }

    /// kitchen-sink.mdx prints the same number of sheets it did before the run
    /// work — a regression pin, not a recomputed expectation.
    func testKitchenSinkMdxPrintKeepsItsSheetCount() async throws {
        let support = ExportHTMLCommandAppTests()
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "kitchen-sink", withExtension: "mdx"))
        let source = try String(contentsOf: url, encoding: .utf8)
        let fixture = try support.makeFixture(name: "kitchen-sink.mdx", text: source)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let document = try await printFixture(fixture, orientation: .portrait)
        XCTAssertEqual(document.pageCount, Self.kitchenSinkPrintSheetCount)
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
        let table = [
            "| " + header.joined(separator: " | ") + " |",
            "| " + [String](repeating: "---", count: header.count).joined(separator: " | ") + " |",
        ] + rowMarkers.map { "| \($0) |" }
        let fixture = try support.makeFixture(
            text: [before, table.joined(separator: "\n"), after].joined(separator: "\n\n")
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let document = try await printFixture(fixture, orientation: orientation)
        var runSheets = 0
        for index in 0 ..< document.pageCount {
            let page = try XCTUnwrap(document.page(at: index), file: file, line: line)
            let box = page.bounds(for: .mediaBox)
            XCTAssertLessThanOrEqual(box.width, 14400.5, file: file, line: line)
            XCTAssertLessThanOrEqual(box.height, 14400.5, file: file, line: line)
            let text = page.string ?? ""
            if text.contains("PRTBLCOL") || text.contains("PRTBLROW") {
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
            beforeMarkers + columnMarkers + rowMarkers + afterMarkers,
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
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.orientation = orientation
        fixture.appState.exportHTMLOperations.printInfoProvider = { info }
        var observed: PDFDocument?
        fixture.appState.exportHTMLOperations.printDocumentObserver = { observed = $0 }
        fixture.appState.exportHTMLOperations.printOperationRunner = { _, _ in true }
        var results: [ExportHTMLOperationResult] = []
        fixture.appState.exportHTMLOperations.didFinishOperation = { _, result in
            results.append(result)
        }
        try await XCTUnwrap(fixture.appState.printCurrentDocument(), file: file, line: line).value
        XCTAssertEqual(results, [.printed], file: file, line: line)
        return try XCTUnwrap(observed, "printDocumentObserver saw nothing", file: file, line: line)
    }

    /// kitchen-sink.mdx measured on A4 portrait, 2026-10-09: four sheets. The count
    /// is a regression pin — if a style or planner change shifts it, update the pin
    /// deliberately rather than silently.
    private static let kitchenSinkPrintSheetCount = 4

    private static func prose(prefix: String, count: Int) -> (markdown: String, markers: [String]) {
        let markers = (0 ..< count).map { String(format: "%@%04d", prefix, $0) }
        let markdown = markers.map { "\($0) prose paragraph." }.joined(separator: "\n\n")
        return (markdown, markers)
    }

    private static func text(of document: PDFDocument) -> String {
        (0 ..< document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }
}
