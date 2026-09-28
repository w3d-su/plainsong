import Foundation
@testable import MarkdownCore
import XCTest

/// Boundary regressions from the 2026-09-23 math rereview: unpaired delimiters,
/// regex expressions, tab stops, multi-line JSX, same-line HTML, and frontmatter.
final class MathEditingBoundaryTests: XCTestCase {
    // N1: an unpaired `$` or backtick is literal, so later code and math still parse.
    func testUnpairedDollarDoesNotSwallowFollowingCodeSpan() {
        for suffix in ["\n", ""] {
            assertNoMathEdit(.insertInlineMath, from: "Price $5 and `va<caret>lue`" + suffix)
            assertNoMathEdit(.insertDisplayMath, from: "Price $5 and `va<caret>lue`" + suffix)
        }
    }

    func testUnpairedBacktickDoesNotSwallowFollowingFormula() {
        for suffix in ["\n", ""] {
            assertMathEdit(
                .insertInlineMath,
                from: "unmatched ` before $a<caret>+b$" + suffix,
                to: "unmatched ` before $[[a+b]]$" + suffix,
                expectSelectionOnly: true
            )
            assertMathEdit(
                .insertDisplayMath,
                from: "unmatched ` before $a<caret>+b$" + suffix,
                to: "unmatched ` before $[[a+b]]$" + suffix,
                expectSelectionOnly: true
            )
        }
    }

    func testEscapedBacktickDoesNotOpenCodeBeforeFormula() {
        for suffix in ["\n", ""] {
            assertMathEdit(
                .insertInlineMath,
                from: "escaped \\` before $a<caret>+b$" + suffix,
                to: "escaped \\` before $[[a+b]]$" + suffix,
                expectSelectionOnly: true
            )
        }
    }

    func testUnpairedDelimiterDoesNotCrossABlankLine() {
        assertMathEdit(
            .insertInlineMath,
            from: "`code\n\nmo<caret>re`",
            to: "`code\n\nmo$[[x]]$re`"
        )
        assertMathEdit(
            .insertInlineMath,
            from: "$a\n\nb<caret>c$",
            to: "$a\n\nb$[[x]]$c$"
        )
    }

    // N2: a `}` inside a regex character class does not close the MDX expression.
    func testRegexCharacterClassDoesNotEndMDXExpression() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "{/[}]/.test(va<caret>lue)}",
            fileKind: .mdx
        )
        assertNoMathEdit(
            .insertDisplayMath,
            from: "{/[}]/.test(va<caret>lue)}",
            fileKind: .mdx
        )
    }

    func testDivisionIsNotARegexAndExpressionStillCloses() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "{a / b<caret>}",
            fileKind: .mdx
        )
        assertMathEdit(
            .insertInlineMath,
            from: "{a / b} <caret>x",
            to: "{a / b} $[[x]]$x",
            fileKind: .mdx
        )
    }

    func testRegexAfterOperatorStaysInsideExpression() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "{a + /[}]/.test(va<caret>lue)}",
            fileKind: .mdx
        )
        assertNoMathEdit(
            .insertDisplayMath,
            from: "{a / /[}]/.test(va<caret>lue)}",
            fileKind: .mdx
        )
    }

    // N3: tab stops are 4 columns, distinct from the UTF-16 offset.
    func testTabIndentedCodeRejectsMathCommands() {
        for suffix in ["\n", ""] {
            assertNoMathEdit(.insertInlineMath, from: "\tva<caret>lue" + suffix)
            assertNoMathEdit(.insertDisplayMath, from: "\tva<caret>lue" + suffix)
        }
    }

    func testMixedSpaceAndTabIndentIsCode() {
        assertNoMathEdit(.insertInlineMath, from: " \tva<caret>lue")
        assertNoMathEdit(.insertDisplayMath, from: "  \tva<caret>lue")
        assertNoMathEdit(.insertInlineMath, from: "   \tva<caret>lue")
        assertMathEdit(
            .insertInlineMath,
            from: "   va<caret>lue",
            to: "   va$[[x]]$lue"
        )
    }

    func testTabIndentedCodeInsideListAndQuoteIsRejected() {
        assertNoMathEdit(.insertInlineMath, from: "- item\n\n\t\tva<caret>lue")
        assertNoMathEdit(.insertDisplayMath, from: "- item\n\n\t\tva<caret>lue")
        assertNoMathEdit(.insertInlineMath, from: ">\t\tva<caret>lue")
        assertNoMathEdit(.insertDisplayMath, from: ">\t\tva<caret>lue")
    }

    func testTabListContinuationBlocksDisplayButNotInline() {
        assertMathEdit(
            .insertInlineMath,
            from: "- item\n\n\tva<caret>lue",
            to: "- item\n\n\tva$[[x]]$lue"
        )
        assertNoMathEdit(.insertDisplayMath, from: "- item\n\n\tva<caret>lue")
        assertMathEdit(
            .insertInlineMath,
            from: ">\tva<caret>lue",
            to: ">\tva$[[x]]$lue"
        )
        assertNoMathEdit(.insertDisplayMath, from: ">\tva<caret>lue")
    }

    func testLazyTabContinuationIsNotIndentedCode() {
        assertMathEdit(
            .insertInlineMath,
            from: "para\n\tva<caret>lue",
            to: "para\n\tva$[[x]]$lue"
        )
    }

    // N4: a tag that closes on a later line still updates the container stack,
    // and a raw `>` inside that tag is not a new blockquote.
    func testDisplayMathInsideMultilineJSXContainerIsNoOp() {
        assertMathEdit(
            .insertInlineMath,
            from: "<Card\n title=\"x\">\n\nva<caret>lue\n\n</Card>",
            to: "<Card\n title=\"x\">\n\nva$[[x]]$lue\n\n</Card>",
            fileKind: .mdx
        )
        assertNoMathEdit(
            .insertDisplayMath,
            from: "<Card\n title=\"x\">\n\nva<caret>lue\n\n</Card>",
            fileKind: .mdx
        )
    }

    func testClosingAngleBracketOnItsOwnLineEndsJSXContainer() {
        assertMathEdit(
            .insertInlineMath,
            from: "<Card>\n\ninside\n\n</Card\n>\n\nva<caret>lue\n",
            to: "<Card>\n\ninside\n\n</Card\n>\n\nva$[[x]]$lue\n",
            fileKind: .mdx
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "<Card>\n\ninside\n\n</Card\n>\n\nva<caret>lue\n",
            to: "<Card>\n\ninside\n\n</Card\n>\n\nva\n\n$$\n[[x]]\n$$\n\nlue\n",
            fileKind: .mdx
        )
    }

    func testExpressionContinuationDoesNotTreatAngleBracketAsQuote() {
        assertMathEdit(
            .insertInlineMath,
            from: "{1 +\n>}\n\nva<caret>lue",
            to: "{1 +\n>}\n\nva$[[x]]$lue",
            fileKind: .mdx
        )
    }

    // N5: a marker HTML block that ends on its opening line excludes only that line.
    func testSameLineHTMLCommentDoesNotExcludeTheBody() {
        assertMathEdit(
            .insertInlineMath,
            from: "<!-- note -->\n\nva<caret>lue",
            to: "<!-- note -->\n\nva$[[x]]$lue"
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "<!-- note -->\n\nva<caret>lue",
            to: "<!-- note -->\n\nva\n\n$$\n[[x]]\n$$\n\nlue"
        )
        assertMathEdit(
            .insertInlineMath,
            from: "<script>let x=1</script>\n\nva<caret>lue",
            to: "<script>let x=1</script>\n\nva$[[x]]$lue"
        )
        assertMathEdit(
            .insertInlineMath,
            from: "<SCRIPT>let x=1</SCRIPT>\n\nva<caret>lue",
            to: "<SCRIPT>let x=1</SCRIPT>\n\nva$[[x]]$lue"
        )
    }

    func testUnclosedHTMLCommentStillExcludesTheBody() {
        assertNoMathEdit(.insertInlineMath, from: "<!-- note\n\nva<caret>lue")
        assertNoMathEdit(.insertDisplayMath, from: "<!-- note\n\nva<caret>lue")
    }

    // N8: the closing frontmatter line stays protected; the body caret does not.
    func testBodyCaretAfterFrontmatterCanInsertMath() {
        assertMathEdit(
            .insertInlineMath,
            from: "---\ntitle: hi\n---\n<caret>value",
            to: "---\ntitle: hi\n---\n$[[x]]$value"
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "---\ntitle: hi\n---\n<caret>value",
            to: "---\ntitle: hi\n---\n\n$$\n[[x]]\n$$\n\nvalue"
        )
        assertNoMathEdit(
            .insertInlineMath,
            from: "---\ntitle: hi\n---<caret>\nvalue"
        )
    }

    private func assertMathEdit(
        _ command: MarkdownFormattingCommand,
        from rawInput: String,
        to rawExpected: String,
        fileKind: FileKind = .markdown,
        expectSelectionOnly: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let input = MathMarkedText(rawInput)
        let expected = MathMarkedText(rawExpected)
        guard let edit = MarkdownEditing.apply(
            .format(command),
            to: input.text,
            selection: input.selection,
            fileKind: fileKind
        ) else {
            XCTFail("Expected edit", file: file, line: line)
            return
        }

        if expectSelectionOnly {
            XCTAssertEqual(edit.replacementString, "", file: file, line: line)
            XCTAssertEqual(edit.replacementRange.length, 0, file: file, line: line)
        }

        let actualText = applyMathEdit(edit, to: input.text)
        XCTAssertEqual(actualText, expected.text, file: file, line: line)
        XCTAssertEqual(edit.newSelection, expected.selection, file: file, line: line)
    }

    private func assertNoMathEdit(
        _ command: MarkdownFormattingCommand,
        from rawInput: String,
        fileKind: FileKind = .markdown,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let input = MathMarkedText(rawInput)
        let edit = MarkdownEditing.apply(
            .format(command),
            to: input.text,
            selection: input.selection,
            fileKind: fileKind
        )
        XCTAssertNil(edit, "Expected no-op", file: file, line: line)
    }

    private func applyMathEdit(_ edit: MarkdownEditResult, to text: String) -> String {
        let mutableText = NSMutableString(string: text)
        mutableText.replaceCharacters(in: edit.replacementRange, with: edit.replacementString)
        return mutableText as String
    }
}

private struct MathMarkedText {
    let text: String
    let selection: NSRange

    init(_ raw: String) {
        if let start = raw.range(of: "[["), let end = raw.range(of: "]]") {
            var text = raw
            text.removeSubrange(end)
            text.removeSubrange(start)

            let location = raw[..<start.lowerBound].utf16.count
            let length = raw[start.upperBound ..< end.lowerBound].utf16.count
            self.text = text
            selection = NSRange(location: location, length: length)
            return
        }

        guard let cursorRange = raw.range(of: "<caret>") else {
            self.text = raw
            selection = NSRange(location: 0, length: 0)
            return
        }

        var text = raw
        text.removeSubrange(cursorRange)
        self.text = text
        selection = NSRange(location: raw[..<cursorRange.lowerBound].utf16.count, length: 0)
    }
}
