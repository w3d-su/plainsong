import Foundation
@testable import MarkdownCore
import XCTest

final class MarkdownTableRowStructureTests: XCTestCase {
    func testRowWithOuterPipesHasExactCellAndPipeRanges() throws {
        let line = "| 123|234 |  345  |"
        let row = try XCTUnwrap(MarkdownTableRowStructure(line: line, lineStart: 10))

        XCTAssertEqual(row.lineRange, NSRange(location: 10, length: 19))
        XCTAssertTrue(row.hasLeadingPipe)
        XCTAssertTrue(row.hasTrailingPipe)
        XCTAssertEqual(row.pipeOffsets, [10, 15, 20, 28])
        XCTAssertEqual(row.cells.map(\.trimmedText), ["123", "234", "345"])
        XCTAssertEqual(row.cells.map(\.contentRange), [
            NSRange(location: 12, length: 3),
            NSRange(location: 16, length: 3),
            NSRange(location: 23, length: 3),
        ])
        XCTAssertEqual(row.cells.map(\.rawRange), [
            NSRange(location: 11, length: 4),
            NSRange(location: 16, length: 4),
            NSRange(location: 21, length: 7),
        ])
        XCTAssertFalse(row.isDelimiterRow)
    }

    func testOuterPipesAreOptionalAndKeepEdgeCellRanges() throws {
        let row = try XCTUnwrap(MarkdownTableRowStructure(line: "a | b", lineStart: 0))

        XCTAssertFalse(row.hasLeadingPipe)
        XCTAssertFalse(row.hasTrailingPipe)
        XCTAssertEqual(row.pipeOffsets, [2])
        XCTAssertEqual(row.cells.map(\.contentRange), [
            NSRange(location: 0, length: 1),
            NSRange(location: 4, length: 1),
        ])
    }

    func testEscapedPipeIsCellContentAndEscapedBackslashIsNot() throws {
        let escaped = try XCTUnwrap(MarkdownTableRowStructure(line: #"| a \| b | c |"#, lineStart: 0))
        XCTAssertEqual(escaped.cells.map(\.trimmedText), [#"a \| b"#, "c"])

        let backslash = try XCTUnwrap(MarkdownTableRowStructure(line: #"| a \\| b |"#, lineStart: 0))
        XCTAssertEqual(backslash.cells.map(\.trimmedText), [#"a \\"#, "b"])
    }

    func testEmptyCellsKeepARestingPlaceForTheCaret() throws {
        let row = try XCTUnwrap(MarkdownTableRowStructure(line: "|   || x |", lineStart: 0))

        // An all-space cell keeps its first space; a cell with no characters is empty.
        XCTAssertEqual(row.cells.map(\.contentRange), [
            NSRange(location: 1, length: 1),
            NSRange(location: 5, length: 0),
            NSRange(location: 7, length: 1),
        ])
    }

    func testDelimiterRowReportsAlignments() throws {
        let row = try XCTUnwrap(MarkdownTableRowStructure(line: "| --- | :--- | :---: | ---: |", lineStart: 0))

        XCTAssertTrue(row.isDelimiterRow)
        XCTAssertEqual(row.cells.map(\.alignment), [.none, .left, .center, .right])
    }

    func testLineWithoutUnescapedPipeIsNotARow() {
        XCTAssertNil(MarkdownTableRowStructure(line: "plain text", lineStart: 0))
        XCTAssertNil(MarkdownTableRowStructure(line: #"a \| b"#, lineStart: 0))
    }

    func testTableHelperTabUsesTheSharedCellContentRanges() throws {
        let text = "| 123|234 |  345  |\n| --- | --- | --- |\n| a | b | c |"
        let row = try XCTUnwrap(MarkdownTableRowStructure(line: "| 123|234 |  345  |", lineStart: 0))
        let result = try XCTUnwrap(TableEditing.handleTab(
            in: text,
            selection: NSRange(location: row.cells[0].contentRange.location, length: 0),
            backwards: false
        ))

        XCTAssertEqual(result.newSelection, row.cells[1].contentRange)
    }
}
