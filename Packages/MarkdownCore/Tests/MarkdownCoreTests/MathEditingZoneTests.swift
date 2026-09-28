import Foundation
@testable import MarkdownCore
import XCTest

/// Regression coverage for the 2026-09-21 math review (R1-R6): the zone
/// scanner must reject edits inside MDX expressions, code regions, JSX
/// tags, and existing formulas, matching what the preview parser accepts.
final class MathEditingZoneTests: XCTestCase {
    // MARK: - Review 2026-09-21 regression coverage

    // R1: `}` inside a JavaScript string must not close the MDX expression.
    func testInlineMathInsideMDXExpressionStringBraceIsNoOp() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "{\"}\" + va<caret>lue}",
            fileKind: .mdx
        )
    }

    func testDisplayMathInsideMDXExpressionStringBraceIsNoOp() {
        assertNoMathEdit(
            .insertDisplayMath,
            from: "{\"}\" + va<caret>lue}",
            fileKind: .mdx
        )
    }

    func testInlineMathInsideMDXExpressionCommentIsNoOp() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "{/* } */ va<caret>lue}",
            fileKind: .mdx
        )
    }

    func testInlineMathInsideMDXExpressionTemplateIsNoOp() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "{`t${\"}\"}` + va<caret>lue}",
            fileKind: .mdx
        )
    }

    // R2: legal code regions — multi-line inline code, indented code, and
    // fenced code inside containers — stay unwritable.
    func testInlineMathInsideMultiLineCodeSpanIsNoOp() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "`code\nva<caret>lue`"
        )
    }

    func testDisplayMathInsideMultiLineCodeSpanIsNoOp() {
        assertNoMathEdit(
            .insertDisplayMath,
            from: "`code\nva<caret>lue`"
        )
    }

    func testInlineMathInsideIndentedCodeIsNoOp() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "para\n\n    va<caret>lue"
        )
    }

    func testDisplayMathInsideIndentedCodeIsNoOp() {
        assertNoMathEdit(
            .insertDisplayMath,
            from: "para\n\n    va<caret>lue"
        )
    }

    func testInlineMathInsideQuoteFenceIsNoOp() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "> ```js\n> va<caret>lue\n> ```"
        )
    }

    func testInlineMathInsideListFenceIsNoOp() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "- ```js\n  va<caret>lue\n  ```"
        )
    }

    /// An indented line directly after a paragraph is a lazy continuation, not
    /// indented code — insertion stays allowed there.
    func testInlineMathInLazyParagraphContinuationIsAllowed() {
        assertMathEdit(
            .insertInlineMath,
            from: "para\n    va<caret>lue",
            to: "para\n    va$[[x]]$lue"
        )
    }

    // R3: a caret on the closing-fence line or at EOF inside an unclosed zone
    // is still inside the region.
    func testInlineMathAtClosingFenceLineEndIsNoOp() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "```js\ncode\n```<caret>\n\nAfter"
        )
    }

    func testInlineMathAtUnclosedFenceEndIsNoOp() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "```js\nva<caret>lue"
        )
    }

    func testInlineMathAfterInlineCodeEndIsAllowed() {
        assertMathEdit(
            .insertInlineMath,
            from: "run `code`<caret> now",
            to: "run `code`$[[x]]$ now"
        )
    }

    func testInlineMathAfterFenceOnNextLineIsAllowed() {
        assertMathEdit(
            .insertInlineMath,
            from: "```js\ncode\n```\n<caret>After",
            to: "```js\ncode\n```\n$[[x]]$After"
        )
    }

    // R4: a JSX tag open across lines keeps its attribute state.
    func testInlineMathInsideMultiLineTagAttributeIsNoOp() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "<Card\n  title=\"va<caret>lue\"\n/>",
            fileKind: .mdx
        )
    }

    func testInlineMathInsideTagQuotedAngleBracketIsNoOp() {
        assertNoMathEdit(
            .insertInlineMath,
            from: "<Card title=\"a>b\" note=<caret>x />",
            fileKind: .mdx
        )
    }

    // R5: same-line open+close and autolinks must not leave a stale container.
    func testDisplayMathAfterSameLineContainerCloseIsAllowed() {
        assertMathEdit(
            .insertDisplayMath,
            from: "<Card>note</Card>\n\nva<caret>lue",
            to: "<Card>note</Card>\n\nva\n\n$$\n[[x]]\n$$\n\nlue",
            fileKind: .mdx
        )
    }

    func testDisplayMathAfterAutolinkParagraphIsAllowed() {
        assertMathEdit(
            .insertDisplayMath,
            from: "<https://example.com>\n\nva<caret>lue",
            to: "<https://example.com>\n\nva\n\n$$\n[[x]]\n$$\n\nlue"
        )
    }

    // R6: preview-legal existing formulas are protected across lines and with
    // longer `$$` runs.
    func testInlineMathInsideMultiLineFormulaSelectsInner() {
        assertMathEdit(
            .insertInlineMath,
            from: "$a\nb<caret>$",
            to: "$[[a\nb]]$",
            expectSelectionOnly: true
        )
    }

    func testDisplayMathInsideMultiLineFormulaSelectsInner() {
        assertMathEdit(
            .insertDisplayMath,
            from: "$a\nb<caret>$",
            to: "$[[a\nb]]$",
            expectSelectionOnly: true
        )
    }

    func testInlineMathInsideTripleDollarBlockSelectsInner() {
        assertMathEdit(
            .insertInlineMath,
            from: "$$$\na + <caret>b\n$$$",
            to: "$$$\n[[a + b]]\n$$$",
            expectSelectionOnly: true
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
