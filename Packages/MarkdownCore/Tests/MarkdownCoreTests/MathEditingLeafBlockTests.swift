import Foundation
@testable import MarkdownCore
import XCTest

/// 2026-09-24 fourth-round math regressions: statement-block braces inside
/// MDX expressions, list paragraph-interruption, new-container delimiter
/// boundaries, namespaced JSX names, and case-sensitive void-tag handling.
final class MathEditingLeafBlockTests: XCTestCase {
    // F1: `{}` at statement position inside a block body is a nested statement
    // block, not an object literal — a following `/…/` is still a regex.

    func testNestedStatementBlockKeepsRegexInsideExpression() {
        let source = "{(() => { {} /[}}]/.test(va<caret>lue); })()}"
        assertNoMathEditBoth(from: source, fileKind: .mdx)
    }

    func testParagraphAfterNestedStatementBlockExpressionIsEditable() {
        assertMathEdit(
            .insertInlineMath,
            from: "{(() => { {} /[}}]/.test(value); })()}\n\nva<caret>lue",
            to: "{(() => { {} /[}}]/.test(value); })()}\n\nva$[[x]]$lue",
            fileKind: .mdx
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "{(() => { {} /[}}]/.test(value); })()}\n\nva<caret>lue",
            to: "{(() => { {} /[}}]/.test(value); })()}\n\nva\n\n$$\n[[x]]\n$$\n\nlue",
            fileKind: .mdx
        )
    }

    // F2: a list marker can interrupt a paragraph only when the item is
    // non-empty and — for ordered lists — starts with `1`.

    func testOrderedMarkerAboveOneCannotInterruptAParagraph() {
        assertNoMathEditBoth(from: "`a\n2. b<caret>`")
        assertMathEdit(
            .insertInlineMath,
            from: "$a\n2. b<caret>$",
            to: "$[[a\n2. b]]$",
            expectSelectionOnly: true
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "$a\n2. b<caret>$",
            to: "$[[a\n2. b]]$",
            expectSelectionOnly: true
        )
    }

    func testOrderedOneInterruptsAParagraph() {
        assertMathEdit(
            .insertInlineMath,
            from: "$a\n1. b<caret>c$",
            to: "$a\n1. b$[[x]]$c$"
        )
        assertNoMathEdit(.insertDisplayMath, from: "$a\n1. b<caret>$")
    }

    func testEmptyListMarkerCannotInterruptAParagraph() {
        // `+` plus spaces has no item content and is not a setext underline,
        // so the paragraph continues and the dollars stay one formula.
        // A single `- ` is a setext underline, not this case.
        assertMathEdit(
            .insertInlineMath,
            from: "$a\n+     \nb<caret>$",
            to: "$[[a\n+     \nb]]$",
            expectSelectionOnly: true
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "$a\n+     \nb<caret>$",
            to: "$[[a\n+     \nb]]$",
            expectSelectionOnly: true
        )
    }

    // F3: a line that opens a new container is a leaf-block boundary even
    // when a paragraph could otherwise continue; delimiters must not pair
    // across it. Delimiters still pair within the same quote paragraph.

    func testDollarDoesNotPairAcrossANewBlockquote() {
        assertMathEdit(
            .insertInlineMath,
            from: "$a\n> b<caret>c$",
            to: "$a\n> b$[[x]]$c$"
        )
        assertNoMathEdit(.insertDisplayMath, from: "$a\n> b<caret>$")
    }

    func testBacktickDoesNotPairAcrossANewBlockquote() {
        assertMathEdit(
            .insertInlineMath,
            from: "`a\n> b<caret>`",
            to: "`a\n> b$[[x]]$`"
        )
        assertNoMathEdit(.insertDisplayMath, from: "`a\n> b<caret>`")
    }

    func testDollarStillPairsWithinOneBlockquoteParagraph() {
        assertMathEdit(
            .insertInlineMath,
            from: "> $a\n> b<caret>$",
            to: "> $[[a\n> b]]$",
            expectSelectionOnly: true
        )
    }

    // F4: namespaced JSX names (`UI:Card`) are valid component names in MDX
    // and open containers. Autolinks keep their own exclusion and never
    // become containers.

    func testNamespacedJSXContainerBlocksDisplayOnly() {
        let source = "<UI:Card>\n\nva<caret>lue\n\n</UI:Card>"
        assertMathEdit(
            .insertInlineMath,
            from: source,
            to: "<UI:Card>\n\nva$[[x]]$lue\n\n</UI:Card>",
            fileKind: .mdx
        )
        assertNoMathEdit(.insertDisplayMath, from: source, fileKind: .mdx)
    }

    func testMalformedNamespacedNameDoesNotOpenAContainer() {
        assertMathEdit(
            .insertDisplayMath,
            from: "<https://example.com>\n\nva<caret>lue",
            to: "<https://example.com>\n\nva\n\n$$\n[[x]]\n$$\n\nlue",
            fileKind: .mdx
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "<a:b:c>\n\nva<caret>lue\n\n</a:b:c>",
            to: "<a:b:c>\n\nva\n\n$$\n[[x]]\n$$\n\nlue\n\n</a:b:c>",
            fileKind: .mdx
        )
    }

    // F5: HTML void-tag inference is a markdown rule. An uppercase MDX name
    // is a component, so `<Input>` opens a container like `<Card>` does.

    func testUppercaseComponentNameIsNotAnHTMLVoidElement() {
        let source = "<Input>\n\nva<caret>lue\n\n</Input>"
        assertMathEdit(
            .insertInlineMath,
            from: source,
            to: "<Input>\n\nva$[[x]]$lue\n\n</Input>",
            fileKind: .mdx
        )
        assertNoMathEdit(.insertDisplayMath, from: source, fileKind: .mdx)
    }

    func testLowercaseJSXIntrinsicWithCloserIsAContainerToo() {
        let source = "<input>\n\nva<caret>lue\n\n</input>"
        assertMathEdit(
            .insertInlineMath,
            from: source,
            to: "<input>\n\nva$[[x]]$lue\n\n</input>",
            fileKind: .mdx
        )
        assertNoMathEdit(.insertDisplayMath, from: source, fileKind: .mdx)
    }

    // MARK: - Headings are not paragraphs

    func testDisplayMathRefusesATXHeadingLine() {
        assertNoMathEdit(.insertDisplayMath, from: "# Ti<caret>tle")
        assertNoMathEdit(.insertDisplayMath, from: "para\n### Ti<caret>tle\nmore")
        assertMathEdit(.insertInlineMath, from: "# Ti<caret>tle", to: "# Ti$[[x]]$tle")
    }

    func testDisplayMathRefusesSetextHeadingText() {
        assertNoMathEdit(.insertDisplayMath, from: "Ti<caret>tle\n=====")
        assertNoMathEdit(.insertDisplayMath, from: "Ti<caret>tle\n---\n\nnext")
    }

    func testParagraphAdjacentToATXHeadingStillAcceptsDisplayMath() {
        assertMathEdit(
            .insertDisplayMath,
            from: "# Title\npa<caret>ra",
            to: "# Title\npa\n\n$$\n[[x]]\n$$\n\nra"
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "pa<caret>ra\n# Title",
            to: "pa\n\n$$\n[[x]]\n$$\n\nra\n# Title"
        )
    }

    func testFourSpaceHashIsParagraphContinuationNotHeading() {
        assertMathEdit(
            .insertDisplayMath,
            from: "pa<caret>ra\n    # not a heading",
            to: "pa\n\n$$\n[[x]]\n$$\n\nra\n    # not a heading"
        )
    }

    // MARK: - Inline delimiters must stand alone

    func testInlineMathRefusesSelectionContainingDollar() {
        assertNoMathEdit(.insertInlineMath, from: "a [[cost $5]] b")
        assertNoMathEdit(.insertInlineMath, from: "a [[\\$5]] b")
    }

    func testInlineMathRefusesTrailingOddBackslash() {
        assertNoMathEdit(.insertInlineMath, from: "a [[x\\]] b")
        assertMathEdit(.insertInlineMath, from: "a [[x\\\\]] b", to: "a $[[x\\\\]]$ b")
    }

    func testInlineMathRefusesEscapedOrAdjacentDelimiter() {
        assertNoMathEdit(.insertInlineMath, from: "a\\<caret>b")
        assertNoMathEdit(.insertInlineMath, from: "a\\[[b]] c")
        assertNoMathEdit(.insertInlineMath, from: "a<caret>$b")
        assertNoMathEdit(.insertInlineMath, from: "a$<caret>b")
        assertMathEdit(.insertInlineMath, from: "a\\\\<caret>b", to: "a\\\\$[[x]]$b")
        assertMathEdit(.insertInlineMath, from: "a\\$<caret>b", to: "a\\$$[[x]]$b")
    }
}

private func assertNoMathEditBoth(
    from rawInput: String,
    fileKind: FileKind = .markdown,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    assertNoMathEdit(.insertInlineMath, from: rawInput, fileKind: fileKind, file: file, line: line)
    assertNoMathEdit(.insertDisplayMath, from: rawInput, fileKind: fileKind, file: file, line: line)
}

private func assertNoMathEdit(
    _ command: MarkdownFormattingCommand,
    from rawInput: String,
    fileKind: FileKind = .markdown,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let input = MathLeafMarkedText(rawInput)
    let edit = MarkdownEditing.apply(
        .format(command),
        to: input.text,
        selection: input.selection,
        fileKind: fileKind
    )
    XCTAssertNil(edit, "Expected no-op", file: file, line: line)
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
    let input = MathLeafMarkedText(rawInput)
    let expected = MathLeafMarkedText(rawExpected)
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

    let actualText = applyLeafMathEdit(edit, to: input.text)
    XCTAssertEqual(actualText, expected.text, file: file, line: line)
    XCTAssertEqual(edit.newSelection, expected.selection, file: file, line: line)
}

private func applyLeafMathEdit(_ edit: MarkdownEditResult, to text: String) -> String {
    let mutableText = NSMutableString(string: text)
    mutableText.replaceCharacters(in: edit.replacementRange, with: edit.replacementString)
    return mutableText as String
}

private struct MathLeafMarkedText {
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
