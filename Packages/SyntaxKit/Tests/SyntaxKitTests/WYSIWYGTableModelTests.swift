import Foundation
import MarkdownCore
@testable import SyntaxKit
import XCTest

/// T1 of `docs/table-wysiwyg-gates.md`: the tree-sitter table region model.
final class WYSIWYGTableModelTests: XCTestCase {
    private var parser: MarkdownSyntaxParser!

    override func setUpWithError() throws {
        parser = try MarkdownSyntaxParser()
    }

    private func tables(
        in source: String,
        visibleRange: NSRange? = nil,
        fileKind: FileKind = .markdown
    ) -> [WYSIWYGTableRegion] {
        parser.visibleTokensAndFoldPlan(
            in: source,
            fileKind: fileKind,
            visibleRange: visibleRange ?? NSRange(location: 0, length: (source as NSString).length),
            selection: NSRange(location: 0, length: 0),
            tableRegionsEnabled: true
        ).foldPlan.tableRegions
    }

    private func range(of needle: String, in source: String) -> NSRange {
        let range = (source as NSString).range(of: needle)
        precondition(range.location != NSNotFound, needle)
        return range
    }

    func testRegionGivesExactRowCellAndStructuralRanges() throws {
        let source = "Intro\n\n| Name | Qty |\n| :--- | ---: |\n| apple | 3 |\n|  | 12 |\n\nOutro\n"
        let table = try XCTUnwrap(tables(in: source).first)

        XCTAssertNil(table.rawReason)
        XCTAssertEqual(table.sourceRange, NSRange(
            location: range(of: "| Name", in: source).location,
            length: NSMaxRange(range(of: "|  | 12 |", in: source)) - range(of: "| Name", in: source).location
        ))
        XCTAssertEqual(table.alignments, [.left, .right])
        XCTAssertEqual(table.columnCount, 2)
        XCTAssertEqual(table.rows.map(\.lineRange), [
            range(of: "| Name | Qty |", in: source),
            range(of: "| :--- | ---: |", in: source),
            range(of: "| apple | 3 |", in: source),
            range(of: "|  | 12 |", in: source),
        ])
        let body = range(of: "| apple | 3 |", in: source)
        XCTAssertEqual(table.rows[2].cells.map(\.contentRange), [
            NSRange(location: body.location + 2, length: 5),
            NSRange(location: body.location + 10, length: 1),
        ])
        // An all-space cell keeps its first space as content, as `TableEditing` does.
        let emptyRow = range(of: "|  | 12 |", in: source)
        XCTAssertEqual(table.rows[3].cells[0].contentRange, NSRange(location: emptyRow.location + 1, length: 1))

        XCTAssertEqual(table.structuralRanges(ofRow: 2), [
            NSRange(location: body.location, length: 2), // "| "
            NSRange(location: body.location + 7, length: 3), // " | "
            NSRange(location: body.location + 11, length: 2), // " |"
        ])
        XCTAssertEqual(table.structuralRanges(ofRow: 1), [range(of: "| :--- | ---: |", in: source)])
    }

    func testStructuralAndContentRangesTileEveryRowExactly() throws {
        let source = "a | b | c\n--|:-:|--\n1 | 2\n   x|y|z   \n"
        let table = try XCTUnwrap(tables(in: source).first)
        XCTAssertNil(table.rawReason)

        for (index, row) in table.rows.enumerated() {
            let content = index == 1 ? [] : row.cells.map(\.contentRange)
            let pieces = (content + table.structuralRanges(ofRow: index)).filter { $0.length > 0 }
                .sorted { $0.location < $1.location }
            var cursor = row.lineRange.location
            for piece in pieces {
                XCTAssertEqual(piece.location, cursor, "row \(index) has a gap or overlap")
                cursor = NSMaxRange(piece)
            }
            XCTAssertEqual(cursor, NSMaxRange(row.lineRange), "row \(index) is not covered")
        }
    }

    func testCellContentMatchesTheTableHelperTabSelection() throws {
        let source = "| 123|234 |  345  |\n| --- | :-: | --: |\n| a | **b** | `c` |\n"
        let table = try XCTUnwrap(tables(in: source).first)
        let cells = [table.rows[0], table.rows[2]].flatMap(\.cells)

        for (index, cell) in cells.dropLast().enumerated() {
            let result = try XCTUnwrap(MarkdownEditing.apply(
                .insertTab(backwards: false),
                to: source,
                selection: NSRange(location: cell.contentRange.location, length: 0)
            ))
            XCTAssertEqual(result.newSelection, cells[index + 1].contentRange, "Tab from cell \(index)")
        }
    }

    func testEscapedPipesStayInsideTheirCell() throws {
        let source = "| a | b |\n| - | - |\n| x \\| y | `p\\|q` |\n"
        let table = try XCTUnwrap(tables(in: source).first)

        XCTAssertNil(table.rawReason)
        XCTAssertEqual(table.rows[2].cells.map(\.trimmedText), ["x \\| y", "`p\\|q`"])
    }

    func testUnescapedPipeInsideCodeSpanSplitsTheCellAsInGFM() throws {
        let source = "| a | b |\n| - | - |\n| `p|q` | r |\n"
        let table = try XCTUnwrap(tables(in: source).first)

        XCTAssertEqual(table.rawReason, .extraCells)
        XCTAssertTrue(table.rows.isEmpty)
    }

    func testRowsWithFewerCellsThanTheHeaderStayEligible() throws {
        let source = "| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 |\n"
        let table = try XCTUnwrap(tables(in: source).first)

        XCTAssertNil(table.rawReason)
        XCTAssertEqual(table.rows.map(\.cells.count), [3, 3, 1, 2])
    }

    func testEveryIneligibilityRuleLeavesTheTableRaw() {
        let cases: [(String, WYSIWYGTableRegion.RawReason)] = [
            ("> | a | b |\n> |---|---|\n> | 1 | 2 |\n", .nested),
            ("- | a | b |\n  |---|---|\n  | 1 | 2 |\n", .nested),
            ("| a | b |\n|---|---|\n| 1\t| 2 |\n", .containsTab),
            ("| a | b |\n|---|---|\n1 | 2 |\n", .inconsistentLeadingPipe),
            ("| a | b |\n|---|---|\n| 1 | 2 | 3 |\n", .extraCells),
            ("a | b\n:-:|---\n1 | 2\n", .unanchoredFirstColumn),
            ("a | b\n--:|---\n1 | 2\n", .unanchoredFirstColumn),
        ]
        for (source, reason) in cases {
            let regions = tables(in: source)
            XCTAssertEqual(regions.count, 1, source.debugDescription)
            XCTAssertEqual(regions.first?.rawReason, reason, source.debugDescription)
            XCTAssertEqual(regions.first?.rows, [], source.debugDescription)
        }
        XCTAssertNil(tables(in: "a | b\n:--|---\n1 | 2\n").first?.rawReason)
    }

    func testCapsLeaveLargeTablesRaw() {
        let tooManyRows = "| a |\n| - |\n" + String(repeating: "| r |\n", count: WYSIWYGTableRegion.maximumRowCount - 1)
        XCTAssertEqual(tables(in: tooManyRows).first?.rawReason, .overCaps)
        let atRowCap = "| a |\n| - |\n" + String(repeating: "| r |\n", count: WYSIWYGTableRegion.maximumRowCount - 2)
        XCTAssertNil(tables(in: atRowCap).first?.rawReason)

        let columns = WYSIWYGTableRegion.maximumColumnCount + 1
        let wide = "|" + String(repeating: " h |", count: columns) + "\n|" + String(repeating: "---|", count: columns) +
            "\n"
        XCTAssertEqual(tables(in: wide).first?.rawReason, .overCaps)

        let longCell = String(repeating: "x", count: WYSIWYGTableRegion.maximumSourceLength)
        XCTAssertEqual(tables(in: "| a |\n| - |\n| \(longCell) |\n").first?.rawReason, .overCaps)
    }

    func testPureRulesReportTruncationAndStructureMismatch() throws {
        let header = try XCTUnwrap(MarkdownTableRowStructure(line: "| a |", lineStart: 0))
        let delimiter = try XCTUnwrap(MarkdownTableRowStructure(line: "| - |", lineStart: 6))
        let range = NSRange(location: 0, length: 11)
        func make(
            rows: [MarkdownTableRowStructure?],
            pipes: [[Int]],
            truncated: Bool = false
        ) -> WYSIWYGTableRegion {
            WYSIWYGTableRegion.make(
                sourceRange: range,
                sourceText: "| a |\n| - |",
                rows: rows,
                parsedPipeOffsets: pipes,
                placement: truncated ? .truncated : .complete
            )
        }

        XCTAssertNil(make(rows: [header, delimiter], pipes: [[0, 4], [6, 10]]).rawReason)
        XCTAssertEqual(make(rows: [header, delimiter], pipes: [[0, 4], [6, 10]], truncated: true).rawReason, .truncated)
        XCTAssertEqual(make(rows: [header, delimiter], pipes: [[0, 4], [6]]).rawReason, .structureMismatch)
        XCTAssertEqual(make(rows: [header, nil], pipes: [[0, 4], []]).rawReason, .structureMismatch)
    }

    func testTableAtTheCapEdgeIsTruncated() throws {
        let source = "| a |\n| - |\n| 1 |\n"
        let fragment = source as NSString
        let tree = try XCTUnwrap(parser.markdownParser.parse(source))
        let root = try XCTUnwrap(tree.rootNode)
        var cut: [WYSIWYGTableRegion] = []
        parser.appendTableRegions(
            from: root,
            fragment: fragment,
            parseRange: WYSIWYGTableParseRange(range: NSRange(location: 0, length: fragment.length), leadingCut: 0),
            to: &cut
        )
        var trailing: [WYSIWYGTableRegion] = []
        parser.appendTableRegions(
            from: root,
            fragment: fragment,
            parseRange: WYSIWYGTableParseRange(
                range: NSRange(location: 0, length: fragment.length),
                trailingCut: fragment.length - 1
            ),
            to: &trailing
        )

        XCTAssertEqual(cut.first?.rawReason, .truncated)
        XCTAssertEqual(trailing.first?.rawReason, .truncated)
    }

    func testTableAtDocumentEndWithoutNewlineAndWithCRLF() throws {
        let plain = "Intro\n\n| a | b |\n|---|---|\n| 1 | 2 |"
        let table = try XCTUnwrap(tables(in: plain).first)
        XCTAssertNil(table.rawReason)
        XCTAssertEqual(NSMaxRange(table.sourceRange), (plain as NSString).length)

        let crlf = "| a | b |\r\n|---|---|\r\n| 1 | 2 |\r\n"
        let crlfTable = try XCTUnwrap(tables(in: crlf).first)
        XCTAssertNil(crlfTable.rawReason)
        XCTAssertEqual(crlfTable.rows.map(\.lineRange.length), [9, 9, 9])
        XCTAssertEqual(NSMaxRange(crlfTable.sourceRange), (crlf as NSString).length - 2)
    }

    func testTableRegionsAreOffUnlessRequested() {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |\n"
        let plan = parser.visibleTokensAndFoldPlan(
            in: source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (source as NSString).length),
            selection: NSRange(location: 0, length: 0)
        ).foldPlan
        XCTAssertEqual(plan.tableRegions, [])
        XCTAssertEqual(
            parser.foldPlan(
                in: source,
                fileKind: .markdown,
                visibleRange: NSRange(location: 0, length: 3),
                selection: NSRange(location: 0, length: 0),
                tableRegionsEnabled: true
            ).tableRegions.count,
            1
        )
    }

    func testTableRegionsDoNotChangeInlineFoldRegionsOrTokens() {
        let source = "# Title\n\nSome **bold** and `code`.\n\n"
            + "| **a** | [l](u) |\n|---|---|\n| *1* | `2` |\n\nEnd *x*.\n"
        let whole = NSRange(location: 0, length: (source as NSString).length)
        let selection = NSRange(location: 12, length: 0)
        let without = parser.visibleTokensAndFoldPlan(
            in: source,
            fileKind: .markdown,
            visibleRange: whole,
            selection: selection,
            linkFoldingEnabled: true
        )
        let with = parser.visibleTokensAndFoldPlan(
            in: source,
            fileKind: .markdown,
            visibleRange: whole,
            selection: selection,
            linkFoldingEnabled: true,
            tableRegionsEnabled: true
        )

        XCTAssertEqual(with.foldPlan.regions, without.foldPlan.regions)
        XCTAssertEqual(with.foldPlan.imageRegions, without.foldPlan.imageRegions)
        XCTAssertEqual(with.tokens, without.tokens)
        XCTAssertEqual(with.visibleRange, without.visibleRange)
        XCTAssertEqual(with.foldPlan.tableRegions.count, 1)
    }

    func testMDXTablesUseTheSameModel() {
        let source = "import X from './x'\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
        XCTAssertNil(tables(in: source, fileKind: .mdx).first?.rawReason)
    }
}
