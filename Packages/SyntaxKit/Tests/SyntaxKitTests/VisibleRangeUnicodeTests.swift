import Foundation
import MarkdownCore
@testable import SyntaxKit
import XCTest

final class VisibleRangeUnicodeTests: XCTestCase {
    func testUnicodeLineSeparatorsDoNotStartAMarkdownLine() throws {
        let parser = try MarkdownSyntaxParser()
        for separator in ["\u{2028}", "\u{2029}", "\u{0085}"] {
            let paragraph = "abc\(separator)# not a heading\n\nnext\n"
            let source = String(repeating: "filler line\n", count: 800) + "\n" + paragraph
            let storage = source as NSString
            let visible = storage.range(of: "not a")
            let paragraphStart = storage.range(of: "abc").location

            let covered = MarkdownSyntaxParser.visibleHighlightRange(in: source, requestedRange: visible)
            XCTAssertEqual(
                covered.location,
                paragraphStart,
                "U+\(String(separator.unicodeScalars.first!.value, radix: 16))"
            )
            XCTAssertEqual(
                parser.tokens(in: source, fileKind: .markdown, visibleRange: visible),
                parser.tokens(in: source, fileKind: .markdown).filter { $0.range.location >= covered.location }
            )
            XCTAssertEqual(parser.tokens(in: source, fileKind: .markdown, visibleRange: visible), [])
        }
    }

    func testMarkdownLineRangeEndsOnlyAtLFCRAndCRLF() {
        let text = "a\u{2028}b\r\nc\rd\ne" as NSString
        XCTAssertEqual(text.markdownLineRange(containing: 0), NSRange(location: 0, length: 5))
        XCTAssertEqual(text.markdownLineRange(containing: 2), NSRange(location: 0, length: 5))
        XCTAssertEqual(text.markdownLineRange(containing: 4), NSRange(location: 0, length: 5))
        XCTAssertEqual(text.markdownLineRange(containing: 5), NSRange(location: 5, length: 2))
        XCTAssertEqual(text.markdownLineRange(containing: 8), NSRange(location: 7, length: 2))
        XCTAssertEqual(text.markdownLineRange(containing: 9), NSRange(location: 9, length: 1))
        XCTAssertEqual(text.markdownLineRange(containing: 10), NSRange(location: 9, length: 1))
        XCTAssertEqual(("" as NSString).markdownLineRange(containing: 0), NSRange(location: 0, length: 0))
    }

    func testRangeStartingOnATrailSurrogateKeepsDocumentOffsets() throws {
        let source = "a😀b\n\n# h\n"
        let length = (source as NSString).length
        let parser = try MarkdownSyntaxParser()
        let expected = parser.tokens(in: source, fileKind: .markdown)
        XCTAssertEqual(expected.map(\.range), [NSRange(location: 6, length: 1), NSRange(location: 8, length: 1)])

        // Location 2 is the trail surrogate of the emoji.
        let range = NSRange(location: 2, length: length - 2)
        XCTAssertEqual(parser.tokens(in: source, fileKind: .markdown, expandedVisibleRange: range), expected)

        let fragment = try XCTUnwrap(MarkdownParseFragment(source: source, range: range))
        XCTAssertEqual(fragment.text.utf16.count, range.length + 1)
        XCTAssertEqual(fragment.base, 1)
    }

    func testRangeEndingOnALeadSurrogateKeepsItsLength() throws {
        let source = "# h\n\na😀b\n"
        let range = NSRange(location: 0, length: 7)
        let fragment = try XCTUnwrap(MarkdownParseFragment(source: source, range: range))

        XCTAssertEqual(fragment.text.utf16.count, 7)
        XCTAssertEqual(fragment.base, 0)
    }
}
