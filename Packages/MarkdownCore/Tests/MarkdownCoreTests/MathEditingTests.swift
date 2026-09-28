import Foundation
@testable import MarkdownCore
import XCTest

final class MathEditingTests: XCTestCase {
    // MARK: - Inline math

    func testInlineMathNoSelectionInsertsPlaceholder() {
        assertMathEdit(
            .insertInlineMath,
            from: "hello <caret>world",
            to: "hello $[[x]]$world"
        )
    }

    func testInlineMathWrapsSingleLineSelection() {
        assertMathEdit(
            .insertInlineMath,
            from: "Energy is [[E = mc^2]] here",
            to: "Energy is $[[E = mc^2]]$ here"
        )
    }

    func testInlineMathMultiLineSelectionIsNoOp() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "line [[one\ntwo]] end"
        )
    }

    func testInlineMathSelectsInnerOfExistingFormula() {
        assertMathEdit(
            .insertInlineMath,
            from: "see $[[x + 1]]$ now",
            to: "see $[[x + 1]]$ now",
            expectSelectionOnly: true
        )
    }

    func testInlineMathCaretInsideFormulaSelectsInner() {
        assertMathEdit(
            .insertInlineMath,
            from: "see $x<caret> + 1$ now",
            to: "see $[[x + 1]]$ now",
            expectSelectionOnly: true
        )
    }

    func testInlineMathCaretInsideInlineCodeIsNoOp() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "run `$x <caret>+ 1$` first"
        )
    }

    func testInlineMathCaretInsideCodeFenceIsNoOp() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "```\nlet a <caret>= 1\n```"
        )
    }

    func testInlineMathCaretInsideMathFenceSelectsInner() {
        assertMathEdit(
            .insertInlineMath,
            from: "```math\nx <caret>+ 1\n```",
            to: "```math\n[[x + 1]]\n```",
            expectSelectionOnly: true
        )
    }

    func testInlineMathCaretInsideDisplayBlockSelectsInner() {
        assertMathEdit(
            .insertInlineMath,
            from: "$$\nx <caret>+ 1\n$$",
            to: "$$\n[[x + 1]]\n$$",
            expectSelectionOnly: true
        )
    }

    func testInlineMathInsideFrontmatterIsNoOp() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "---\ntitle: <caret>Post\n---\nbody"
        )
    }

    func testInlineMathInsideMDXExpressionIsNoOp() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "result: {a <caret>+ b}",
            fileKind: .mdx
        )
    }

    func testInlineMathBraceTextAllowedInMarkdown() {
        assertMathEdit(
            .insertInlineMath,
            from: "result: {a <caret>+ b}",
            to: "result: {a $[[x]]$+ b}",
            fileKind: .markdown
        )
    }

    func testInlineMathSelectionPartiallyOverlappingFormulaIsNoOp() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "see $x[[ + 1$ an]]d more"
        )
    }

    func testInlineMathEscapedDollarDoesNotPair() {
        // The \$ are literal currency; the caret is not inside a formula.
        assertMathEdit(
            .insertInlineMath,
            from: "costs \\$5 and <caret>\\$10",
            to: "costs \\$5 and $[[x]]$\\$10"
        )
    }

    func testInlineMathCaretInsideHTMLTagIsNoOp() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "<a href=<caret>\"x\">text</a>"
        )
    }

    func testInlineMathUTF16SelectionWithEmoji() {
        assertMathEdit(
            .insertInlineMath,
            from: "😀 [[x]] 中文",
            to: "😀 $[[x]]$ 中文"
        )
    }

    func testInlineMathCRLFDocument() {
        assertMathEdit(
            .insertInlineMath,
            from: "a\r\nb <caret>c\r\nd",
            to: "a\r\nb $[[x]]$c\r\nd"
        )
    }

    // MARK: - Display math

    func testDisplayMathEmptyDocument() {
        assertMathEdit(
            .insertDisplayMath,
            from: "<caret>",
            to: "$$\n[[x]]\n$$"
        )
    }

    func testDisplayMathCaretMidParagraphSplitsParagraph() {
        assertMathEdit(
            .insertDisplayMath,
            from: "ab<caret>cd",
            to: "ab\n\n$$\n[[x]]\n$$\n\ncd"
        )
    }

    func testDisplayMathCaretAtLineStartOfParagraph() {
        assertMathEdit(
            .insertDisplayMath,
            from: "a\n<caret>b",
            to: "a\n\n$$\n[[x]]\n$$\n\nb"
        )
    }

    func testDisplayMathCaretOnBlankLineReplacesIt() {
        assertMathEdit(
            .insertDisplayMath,
            from: "a\n\n<caret>\n\nb",
            to: "a\n\n$$\n[[x]]\n$$\n\nb"
        )
    }

    func testDisplayMathCaretAtDocumentEnd() {
        assertMathEdit(
            .insertDisplayMath,
            from: "para<caret>",
            to: "para\n\n$$\n[[x]]\n$$"
        )
    }

    func testDisplayMathSelectionWrapsContent() {
        assertMathEdit(
            .insertDisplayMath,
            from: "before [[x^2 + y^2]] after",
            to: "before \n\n$$\n[[x^2 + y^2]]\n$$\n\n after"
        )
    }

    func testDisplayMathMultiLineSelectionPreservesNewlines() {
        assertMathEdit(
            .insertDisplayMath,
            from: "p\n\n[[a = 1\nb = 2]]\n\nq",
            to: "p\n\n$$\n[[a = 1\nb = 2]]\n$$\n\nq"
        )
    }

    func testDisplayMathWholeBlockSelectionSelectsInner() {
        assertMathEdit(
            .insertDisplayMath,
            from: "p\n\n[[$$\nx + 1\n$$]]\n\nq",
            to: "p\n\n$$\n[[x + 1]]\n$$\n\nq",
            expectSelectionOnly: true
        )
    }

    func testDisplayMathCaretInsideMathFenceSelectsInner() {
        assertMathEdit(
            .insertDisplayMath,
            from: "```math\nx <caret>+ 1\n```",
            to: "```math\n[[x + 1]]\n```",
            expectSelectionOnly: true
        )
    }

    func testDisplayMathInsideListIsNoOp() {
        assertNoMathEdit(
            .insertDisplayMath,
            from: "- item <caret>text"
        )
    }

    func testDisplayMathInsideListContinuationParagraphIsNoOp() {
        assertNoMathEdit(
            .insertDisplayMath,
            from: "- item\n\n  continued <caret>here"
        )
    }

    func testDisplayMathAfterListOnBlankLineIsAllowed() {
        assertMathEdit(
            .insertDisplayMath,
            from: "- item\n\n<caret>",
            to: "- item\n\n$$\n[[x]]\n$$"
        )
    }

    func testDisplayMathInsideQuoteIsNoOp() {
        assertNoMathEdit(
            .insertDisplayMath,
            from: "> quoted <caret>text"
        )
    }

    func testDisplayMathInsideTableIsNoOp() {
        assertNoMathEdit(
            .insertDisplayMath,
            from: "| a | b |\n|---|---|\n| 1 | <caret>2 |"
        )
    }

    func testDisplayMathInsideMDXContainerIsNoOp() {
        assertNoMathEdit(
            .insertDisplayMath,
            from: "<Callout>\n\nnote <caret>text\n\n</Callout>",
            fileKind: .mdx
        )
    }

    func testDisplayMathAfterMDXContainerIsAllowed() {
        assertMathEdit(
            .insertDisplayMath,
            from: "<Callout>\n\nnote\n\n</Callout>\n\n<caret>",
            to: "<Callout>\n\nnote\n\n</Callout>\n\n$$\n[[x]]\n$$",
            fileKind: .mdx
        )
    }

    func testDisplayMathInsideCodeFenceIsNoOp() {
        assertNoMathEdit(
            .insertDisplayMath,
            from: "```\ncode <caret>here\n```"
        )
    }

    func testDisplayMathInsideFrontmatterIsNoOp() {
        assertNoMathEdit(
            .insertDisplayMath,
            from: "---\ntitle: <caret>x\n---\nbody"
        )
    }

    func testDisplayMathCRLFDocument() {
        assertMathEdit(
            .insertDisplayMath,
            from: "a\r\n\r\n<caret>\r\n\r\nb",
            to: "a\r\n\r\n$$\n[[x]]\n$$\r\n\r\nb"
        )
    }

    func testDisplayMathUTF16EmojiDocument() {
        assertMathEdit(
            .insertDisplayMath,
            from: "😀 中文<caret>",
            to: "😀 中文\n\n$$\n[[x]]\n$$"
        )
    }

    // MARK: - helpers

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
