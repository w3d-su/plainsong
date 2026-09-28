import Foundation
@testable import MarkdownCore
import XCTest

/// 2026-09-23 third-round math regressions: JS regex context, JSX names,
/// leaf-block delimiter pairing, and equal-length inline dollar runs.
final class MathEditingContextTests: XCTestCase {
    // M1: regex vs division follows statement context, not the previous character.

    func testRegexAfterControlStatementStaysInsideExpression() {
        let source = "{(() => { if (ok) /[}}]/.test(va<caret>lue); return true })()}"
        assertNoMathEditBoth(from: source, fileKind: .mdx)
    }

    func testRegexAfterStatementBlockStaysInsideExpression() {
        let source = "{(() => { if (ok) {} /[}}]/.test(va<caret>lue); return true })()}"
        assertNoMathEditBoth(from: source, fileKind: .mdx)
    }

    func testPropertyNamedReturnIsDivisionSoTheNextParagraphIsEditable() {
        assertNoMathEditBoth(from: "{obj.return / <caret>2}", fileKind: .mdx)
        assertMathEdit(
            .insertInlineMath,
            from: "{obj.return / 2}\n\nva<caret>lue",
            to: "{obj.return / 2}\n\nva$[[x]]$lue",
            fileKind: .mdx
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "{obj.return / 2}\n\nva<caret>lue",
            to: "{obj.return / 2}\n\nva\n\n$$\n[[x]]\n$$\n\nlue",
            fileKind: .mdx
        )
    }

    func testParagraphAfterControlStatementRegexIsEditable() {
        let source = "{(() => { if (ok) /[}}]/.test(value); return true })()}\n\nva<caret>lue"
        assertMathEdit(
            .insertInlineMath,
            from: source,
            to: "{(() => { if (ok) /[}}]/.test(value); return true })()}\n\nva$[[x]]$lue",
            fileKind: .mdx
        )
        assertMathEdit(
            .insertDisplayMath,
            from: source,
            to: "{(() => { if (ok) /[}}]/.test(value); return true })()}\n\nva\n\n$$\n[[x]]\n$$\n\nlue",
            fileKind: .mdx
        )
    }

    func testECMAScriptWhitespaceStillStartsARegex() {
        for space in ["\u{00A0}", "\u{3000}", "\u{FEFF}"] {
            assertNoMathEditBoth(
                from: "{\(space)/[}]/.test(va<caret>lue)}",
                fileKind: .mdx
            )
        }
    }

    func testObjectLiteralCloseMakesTheNextSlashDivision() {
        assertNoMathEditBoth(from: "{{}/<caret>2}", fileKind: .mdx)
        assertMathEdit(
            .insertInlineMath,
            from: "{{}/2}\n\nva<caret>lue",
            to: "{{}/2}\n\nva$[[x]]$lue",
            fileKind: .mdx
        )
    }

    // M2: JSX names the preview accepts, including fragments, protect attributes
    // and count as containers. Markdown HTML stays ASCII.

    func testJSXIdentifierAttributesRejectMath() {
        for name in ["_Card", "$Card", "\u{00C9}lan"] {
            assertNoMathEditBoth(
                from: "<\(name) title=\"va<caret>lue\" />",
                fileKind: .mdx
            )
        }
    }

    func testUnderscoreComponentBodyBlocksDisplayOnly() {
        let source = "<_Card>\n\nva<caret>lue\n\n</_Card>"
        assertMathEdit(
            .insertInlineMath,
            from: source,
            to: "<_Card>\n\nva$[[x]]$lue\n\n</_Card>",
            fileKind: .mdx
        )
        assertNoMathEdit(.insertDisplayMath, from: source, fileKind: .mdx)
    }

    func testFragmentBodyBlocksDisplayOnly() {
        let source = "<>\n\nva<caret>lue\n\n</>"
        assertMathEdit(
            .insertInlineMath,
            from: source,
            to: "<>\n\nva$[[x]]$lue\n\n</>",
            fileKind: .mdx
        )
        assertNoMathEdit(.insertDisplayMath, from: source, fileKind: .mdx)
    }

    func testMarkdownDoesNotTreatJSXNamesOrFragmentsAsTags() {
        assertMathEdit(
            .insertInlineMath,
            from: "<_Card title=\"va<caret>lue\" />",
            to: "<_Card title=\"va$[[x]]$lue\" />"
        )
        assertMathEdit(
            .insertInlineMath,
            from: "<>\nva<caret>lue\n</>",
            to: "<>\nva$[[x]]$lue\n</>"
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "<https://example.com>\n\nva<caret>lue",
            to: "<https://example.com>\n\nva\n\n$$\n[[x]]\n$$\n\nlue",
            fileKind: .mdx
        )
    }

    // M3: inline delimiters pair across a paragraph, not across headings or
    // sibling list items. Same-line and lazy continuations still pair.

    func testDollarDoesNotPairAcrossAHeading() {
        assertMathEdit(
            .insertInlineMath,
            from: "# $price\nva<caret>lue$",
            to: "# $price\nva$[[x]]$lue$"
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "# $price\nva<caret>lue$",
            to: "# $price\nva\n\n$$\n[[x]]\n$$\n\nlue$"
        )
    }

    func testDollarDoesNotPairAcrossSiblingListItems() {
        assertMathEdit(
            .insertInlineMath,
            from: "- $a\n- va<caret>lue$",
            to: "- $a\n- va$[[x]]$lue$"
        )
        assertNoMathEdit(.insertDisplayMath, from: "- $a\n- va<caret>lue$")
        assertMathEdit(
            .insertInlineMath,
            from: "1. $a\n2. va<caret>lue$",
            to: "1. $a\n2. va$[[x]]$lue$"
        )
        assertMathEdit(
            .insertInlineMath,
            from: "- $a\n  - b<caret>c$",
            to: "- $a\n  - b$[[x]]$c$"
        )
    }

    func testBacktickDoesNotPairAcrossSiblingListItems() {
        assertMathEdit(
            .insertInlineMath,
            from: "- `a\n- va<caret>lue`",
            to: "- `a\n- va$[[x]]$lue`"
        )
        assertNoMathEdit(.insertDisplayMath, from: "- `a\n- va<caret>lue`")
    }

    func testLazyAndIndentedListContinuationsStillPairMath() {
        assertMathEdit(
            .insertInlineMath,
            from: "- $a\nb<caret>$",
            to: "- $[[a\nb]]$",
            expectSelectionOnly: true
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "- $a\n  b<caret>$",
            to: "- $[[a\n  b]]$",
            expectSelectionOnly: true
        )
        assertMathEdit(
            .insertInlineMath,
            from: "> $a\nb<caret>$",
            to: "> $[[a\nb]]$",
            expectSelectionOnly: true
        )
    }

    func testSameLineMathInsideHeadingAndListStillSelects() {
        assertMathEdit(
            .insertInlineMath,
            from: "# $a<caret>+b$",
            to: "# $[[a+b]]$",
            expectSelectionOnly: true
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "- $a<caret>+b$",
            to: "- $[[a+b]]$",
            expectSelectionOnly: true
        )
    }

    func testDollarBeforeAFollowingListItemStaysLiteral() {
        assertMathEdit(
            .insertInlineMath,
            from: "$a\n- b<caret>c$",
            to: "$a\n- b$[[x]]$c$"
        )
        assertNoMathEdit(.insertDisplayMath, from: "$a\n- b<caret>$")
    }

    // M4: inline `$` closes only on an equal-length run. Flow `$$` still
    // accepts a closing run at least as long as the opener.

    func testUnequalInlineDollarRunsStayLiteral() {
        assertMathEdit(
            .insertInlineMath,
            from: "text $$$a<caret>+b$$ after",
            to: "text $$$a$[[x]]$+b$$ after"
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "text $$$a<caret>+b$$ after",
            to: "text $$$a\n\n$$\n[[x]]\n$$\n\n+b$$ after"
        )
        assertMathEdit(
            .insertInlineMath,
            from: "text $$a<caret>+b$$$ after",
            to: "text $$a$[[x]]$+b$$$ after"
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "text $$a<caret>+b$$$ after",
            to: "text $$a\n\n$$\n[[x]]\n$$\n\n+b$$$ after"
        )
    }

    func testEqualInlineDollarRunsStillSelectTheFormula() {
        assertMathEdit(
            .insertInlineMath,
            from: "text $$a<caret>+b$$ after",
            to: "text $$[[a+b]]$$ after",
            expectSelectionOnly: true
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "text $a<caret>+b$ after",
            to: "text $[[a+b]]$ after",
            expectSelectionOnly: true
        )
    }

    func testFlowMathStillClosesWhenTheClosingRunIsLonger() {
        assertMathEdit(
            .insertDisplayMath,
            from: "$$$\na + <caret>b\n$$$",
            to: "$$$\n[[a + b]]\n$$$",
            expectSelectionOnly: true
        )
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

private func assertMathEdit(
    _ command: MarkdownFormattingCommand,
    from rawInput: String,
    to rawExpected: String,
    fileKind: FileKind = .markdown,
    expectSelectionOnly: Bool = false,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let input = MathContextMarkedText(rawInput)
    let expected = MathContextMarkedText(rawExpected)
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
    let input = MathContextMarkedText(rawInput)
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

private struct MathContextMarkedText {
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
