@testable import MarkdownCore
import XCTest

/// Enter, table formatting and ordered-list numbering on CRLF and CR documents, on
/// paragraph text next to a table, and on list numbers past CommonMark's nine digits.
final class MarkdownEditingLineEndingTests: XCTestCase {
    func testListEnterUsesTheDocumentLineEnding() {
        assertEnter(in: "- one\r\n- two", at: 5, gives: "- one\r\n- \r\n- two", caret: 9)
        assertEnter(in: "1. one\r\n2. two", at: 6, gives: "1. one\r\n2. \r\n3. two", caret: 11)
        // The last line has no terminator of its own: the previous line's is used.
        assertEnter(in: "- a\r\n- b", at: 8, gives: "- a\r\n- b\r\n- ", caret: 12)
        assertEnter(in: "- a\r- b", at: 7, gives: "- a\r- b\r- ", caret: 10)
        assertEnter(in: "- a", at: 3, gives: "- a\n- ", caret: 6)
    }

    func testCodeFenceEnterUsesTheDocumentLineEnding() {
        assertEnter(in: "intro\r\n```", at: 10, gives: "intro\r\n```\r\n\r\n```", caret: 12)
    }

    func testTableEnterUsesTheDocumentLineEnding() {
        let text = "| A | B |\r\n| --- | --- |\r\n| one | two |"
        let length = (text as NSString).length
        let edit = MarkdownEditing.apply(
            .insertNewline(fileKind: .markdown),
            to: text,
            selection: NSRange(location: length, length: 0)
        )
        XCTAssertEqual(edit.map { apply($0, to: text) }, text + "\r\n|  |  |")
        XCTAssertEqual(edit?.newSelection, NSRange(location: length + 4, length: 1))
    }

    func testFormatTableKeepsCRLFRows() {
        let text = "|A|B|\r\n|---|---|\r\n|1|2|\r\nafter\r\n"
        for caret in [1, 9, 20] {
            XCTAssertEqual(
                formatTable(text, caret: caret),
                "| A   | B   |\r\n| --- | --- |\r\n| 1   | 2   |\r\nafter\r\n",
                "caret \(caret)"
            )
        }
    }

    func testFormatTableLeavesAPipedParagraphLineAboveTheHeaderAlone() {
        let text = "Use a | b here\n| a | b |\n|---|---|\n| 1 | 2 |"
        let formatted = "Use a | b here\n| a   | b   |\n| --- | --- |\n| 1   | 2   |"
        XCTAssertEqual(formatTable(text, caret: (text as NSString).length), formatted)
        XCTAssertEqual(formatTable(text, caret: 16), formatted)
        // The paragraph line is not part of any table.
        XCTAssertNil(MarkdownEditing.apply(.formatTable, to: text, selection: NSRange(location: 3, length: 0)))
        XCTAssertNil(MarkdownEditing.apply(
            .insertTab(backwards: false),
            to: text,
            selection: NSRange(location: 3, length: 0)
        ))
    }

    func testDelimiterRowWithoutHeaderIsNotATable() {
        XCTAssertNil(MarkdownEditing.apply(
            .formatTable,
            to: "|---|---|\n| 1 | 2 |",
            selection: NSRange(location: 12, length: 0)
        ))
    }

    func testOrderedListNumbersStopAtNineDigits() {
        assertEnter(
            in: "999999999. x",
            at: 12,
            gives: "999999999. x\n1000000000. ",
            caret: 25
        )
        // Ten or more digits are paragraph text in CommonMark. Int.max - 1 used to trap
        // while computing the renumbering start.
        let tooLong = [
            "1234567890. x",
            "9223372036854775806. x",
            "9223372036854775807) x",
            "99999999999999999999. x",
        ]
        for line in tooLong {
            let caret = (line as NSString).length
            XCTAssertNil(
                MarkdownEditing.apply(
                    .insertNewline(fileKind: .markdown),
                    to: line,
                    selection: NSRange(location: caret, length: 0)
                ),
                line
            )
            XCTAssertNil(
                MarkdownEditing.apply(
                    .insertTab(backwards: false),
                    to: line,
                    selection: NSRange(location: caret, length: 0)
                ),
                line
            )
        }
    }

    private func assertEnter(
        in text: String,
        at location: Int,
        gives expected: String,
        caret: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let edit = MarkdownEditing.apply(
            .insertNewline(fileKind: .markdown),
            to: text,
            selection: NSRange(location: location, length: 0)
        ) else {
            return XCTFail("Expected an edit for \(text.debugDescription)", file: file, line: line)
        }
        XCTAssertEqual(apply(edit, to: text), expected, file: file, line: line)
        XCTAssertEqual(edit.newSelection, NSRange(location: caret, length: 0), file: file, line: line)
    }

    private func formatTable(_ text: String, caret: Int) -> String? {
        MarkdownEditing.apply(.formatTable, to: text, selection: NSRange(location: caret, length: 0))
            .map { apply($0, to: text) }
    }

    private func apply(_ edit: MarkdownEditResult, to text: String) -> String {
        let mutableText = NSMutableString(string: text)
        mutableText.replaceCharacters(in: edit.replacementRange, with: edit.replacementString)
        return mutableText as String
    }
}
