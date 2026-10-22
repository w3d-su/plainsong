import Foundation
import SyntaxKit
import XCTest

/// `MarkdownSyntaxParser.visibleHighlightRange` grows the viewport to whole fenced
/// blocks through `MarkdownFenceScanner`, so a fence opened far above the viewport, or
/// closed far below it, still gives the visible lines their code-block context.
final class MarkdownVisibleRangeContextTests: XCTestCase {
    func testViewportInsideTildeFenceStartsAtTheTildeOpeningLine() {
        let source = "Intro\n~~~\n```\ninside tilde\n~~~\nOutro\n"
        let requested = (source as NSString).range(of: "inside tilde")

        let range = MarkdownSyntaxParser.visibleHighlightRange(in: source, requestedRange: requested)

        XCTAssertEqual(range.location, (source as NSString).range(of: "~~~").location)
        XCTAssertEqual(NSMaxRange(range), (source as NSString).length)
    }

    func testViewportInsideLongFenceEndsAtTheMatchingClosingFence() {
        // The block is longer than the 4096-unit minimum window, and holds a `~~~` line
        // past that window that must not end it.
        let codeLines = (0 ..< 300).map { "let value\($0) = 1234567890" }
        var lines = ["# Title", "", "```swift"]
        lines += codeLines[..<250]
        lines.append("~~~")
        lines += codeLines[250...]
        lines += ["```", "", "Trailing prose."]
        lines += Array(repeating: "More prose that keeps the document long.", count: 200)
        let source = lines.joined(separator: "\n")
        let nsSource = source as NSString
        let requested = nsSource.range(of: "let value10 =")
        let opening = nsSource.range(of: "```swift")
        let closingLine = nsSource.range(of: "\n```\n")
        let expectedEnd = NSMaxRange(closingLine)

        let range = MarkdownSyntaxParser.visibleHighlightRange(in: source, requestedRange: requested)

        XCTAssertEqual(range.location, opening.location)
        XCTAssertEqual(NSMaxRange(range), expectedEnd)
        XCTAssertGreaterThan(range.length, MarkdownSyntaxParser.visibleHighlightMinimumLength)

        let bridged = NSMutableString(string: source) as String
        XCTAssertEqual(MarkdownSyntaxParser.visibleHighlightRange(in: bridged, requestedRange: requested), range)
    }

    func testViewportAtTheEndOfALargeDocumentKeepsItsFenceContext() {
        let section = """
        ## Section

        Prose with **bold** and `code`.

        ```swift
        struct Fixture {
            let title = "Section"
        }
        ```

        """
        let lastBlock = "```json\n{\"tail\":true}\n"
        let source = String(repeating: section, count: 4000) + lastBlock + "still inside the unclosed block\n"
        let nsSource = source as NSString
        let requested = nsSource.range(of: "still inside the unclosed block")

        let range = MarkdownSyntaxParser.visibleHighlightRange(in: source, requestedRange: requested)

        XCTAssertEqual(range.location, nsSource.range(of: lastBlock, options: .backwards).location)
        XCTAssertEqual(NSMaxRange(range), nsSource.length)
    }
}
