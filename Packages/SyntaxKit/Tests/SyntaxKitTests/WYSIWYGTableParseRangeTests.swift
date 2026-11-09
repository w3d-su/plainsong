import Foundation
import MarkdownCore
@testable import SyntaxKit
import XCTest

/// T1 of `docs/table-wysiwyg-gates.md`: the WYSIWYG parse range grows to whole tables, so
/// the rows a parse sees, and so the column widths, never depend on the scroll position.
final class WYSIWYGTableParseRangeTests: XCTestCase {
    private var parser: MarkdownSyntaxParser!

    override func setUpWithError() throws {
        parser = try MarkdownSyntaxParser()
    }

    private func plan(_ source: String, viewport: NSRange) -> WYSIWYGFoldPlan {
        parser.visibleTokensAndFoldPlan(
            in: source,
            fileKind: .markdown,
            visibleRange: viewport,
            selection: NSRange(location: 0, length: 0),
            tableRegionsEnabled: true
        ).foldPlan
    }

    /// Prose, then a table longer than the 4096-unit minimum window, then prose.
    private func longTableDocument() -> (source: String, table: NSRange) {
        let prose = Array(repeating: "Prose line that keeps the document long enough.", count: 200)
            .joined(separator: "\n")
        let rows = (0 ..< 300).map { "| row \($0) | value \($0 * 7) | note |" }
        let table = (["| Key | Value | Note |", "| --- | ---: | :-: |"] + rows).joined(separator: "\n")
        let source = prose + "\n\n" + table + "\n\n" + prose + "\n"
        return (source, (source as NSString).range(of: table))
    }

    func testEveryViewportOverATableSeesTheSameWholeTable() throws {
        let (source, tableRange) = longTableDocument()
        let text = source as NSString
        XCTAssertGreaterThan(tableRange.length, MarkdownSyntaxParser.visibleHighlightMinimumLength)
        let viewports = [
            text.range(of: "| Key |"),
            text.range(of: "| row 150 |"),
            text.range(of: "| row 299 |"),
            NSRange(location: tableRange.location - 200, length: 100),
            NSRange(location: NSMaxRange(tableRange) - 10, length: 400),
        ]

        let regions = try viewports.map { viewport in
            let found = plan(source, viewport: viewport).tableRegions
            return try XCTUnwrap(found.first { $0.sourceRange.intersects(tableRange) }, "\(viewport)")
        }
        for region in regions {
            XCTAssertEqual(region, regions[0])
        }
        XCTAssertNil(regions[0].rawReason)
        XCTAssertEqual(regions[0].sourceRange, tableRange)
        XCTAssertEqual(regions[0].rows.count, 302)
    }

    func testRangeGrowsOnlyAtAnEdgeInsideATableBlock() {
        let (source, tableRange) = longTableDocument()
        let text = source as NSString
        let proseViewport = NSRange(location: 0, length: 50)
        let visible = MarkdownSyntaxParser.visibleHighlightRange(in: source, requestedRange: proseViewport)
        XCTAssertEqual(MarkdownSyntaxParser.tableParseRange(in: source, expanding: visible).range, visible)

        let middle = MarkdownSyntaxParser.visibleHighlightRange(
            in: source,
            requestedRange: text.range(of: "| row 150 |")
        )
        let grown = MarkdownSyntaxParser.tableParseRange(in: source, expanding: middle)
        XCTAssertEqual(grown.range.location, tableRange.location)
        XCTAssertEqual(NSMaxRange(grown.range), NSMaxRange(tableRange) + 1)
        XCTAssertNil(grown.leadingCut)
        XCTAssertNil(grown.trailingCut)
    }

    func testProseBlockWithoutADelimiterLineDoesNotGrow() {
        let paragraph = Array(repeating: "a | b is not a table without a delimiter row", count: 400)
            .joined(separator: "\n")
        let source = paragraph + "\n"
        let viewport = MarkdownSyntaxParser.visibleHighlightRange(
            in: source,
            requestedRange: NSRange(location: 8000, length: 10)
        )
        XCTAssertEqual(MarkdownSyntaxParser.tableParseRange(in: source, expanding: viewport).range, viewport)
    }

    func testScanStopsAtTheCapAndReportsTheCut() throws {
        let filler = String(repeating: "x", count: 60)
        let lines = Array(repeating: filler, count: 800) + ["| a |", "| - |", "| 1 |"]
            + Array(repeating: filler, count: 800).map { "| \($0) |" }
        let source = lines.joined(separator: "\n") + "\n"
        let text = source as NSString
        let viewport = MarkdownSyntaxParser.visibleHighlightRange(
            in: source,
            requestedRange: text.range(of: "| 1 |")
        )

        let grown = MarkdownSyntaxParser.tableParseRange(in: source, expanding: viewport)

        let leadingCut = try XCTUnwrap(grown.leadingCut)
        XCTAssertEqual(grown.range.location, leadingCut)
        XCTAssertGreaterThan(leadingCut, 0)
        XCTAssertLessThanOrEqual(text.range(of: "| 1 |").location - leadingCut, WYSIWYGTableRegion.maximumSourceLength)
        XCTAssertNotNil(grown.trailingCut)
        XCTAssertLessThan(NSMaxRange(grown.range), text.length)
    }

    func testGrownRangeNeverStartsInsideFencedCode() throws {
        let source = "Intro\n\n```\ncode\n\nx|y\n```\n| a |\n|---|\n| 1 |\n"
        let text = source as NSString
        let viewport = MarkdownSyntaxParser.visibleHighlightRange(in: source, requestedRange: text.range(of: "| 1 |"))
        let grown = MarkdownSyntaxParser.tableParseRange(in: source, expanding: viewport)

        XCTAssertLessThanOrEqual(grown.range.location, text.range(of: "```").location)
        let table = try XCTUnwrap(plan(source, viewport: text.range(of: "| 1 |")).tableRegions.first)
        XCTAssertNil(table.rawReason)
        XCTAssertEqual(table.sourceRange.location, text.range(of: "| a |").location)
    }
}
