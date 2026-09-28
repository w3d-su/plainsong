import Foundation
@testable import MarkdownCore
import XCTest

/// 2026-09-25 fifth-round math regressions: statement colons, empty list
/// markers, lazy quotes, setext underlines, quote-blank lines, JSX names,
/// function bodies, and JSX inside expressions.
final class MathEditingGuardTests: XCTestCase {
    func testLabelAndSwitchCaseColonsKeepTheFollowingBlockAStatement() {
        let label = "{(() => { label: {} /[}}]/.test(va<caret>lue); })()}"
        let switchCase = "{(() => { switch (n) { case 1: {} /[}}}]/.test(va<caret>lue); } })()}"
        assertNoMathEditBoth(from: label, fileKind: .mdx)
        assertNoMathEditBoth(from: switchCase, fileKind: .mdx)
    }

    func testParagraphAfterLabelExpressionIsEditable() {
        let source = "{(() => { label: {} /[}}]/.test(value); })()}\n\nva<caret>lue"
        assertMathEdit(
            .insertInlineMath,
            from: source,
            to: "{(() => { label: {} /[}}]/.test(value); })()}\n\nva$[[x]]$lue",
            fileKind: .mdx
        )
        assertMathEdit(
            .insertDisplayMath,
            from: source,
            to: "{(() => { label: {} /[}}]/.test(value); })()}\n\nva\n\n$$\n[[x]]\n$$\n\nlue",
            fileKind: .mdx
        )
    }

    func testWhitespaceOnlyListMarkerDoesNotBreakACodeSpanOrFormula() {
        assertNoMathEditBoth(from: "`a\n+     \nb<caret>`")
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

    func testLazyQuoteContinuationKeepsOneCodeSpanAndFormula() {
        assertNoMathEditBoth(from: "> `a\nlazy\n> b<caret>`")
        assertMathEdit(
            .insertInlineMath,
            from: "> $a\nlazy\n> b<caret>$",
            to: "> $[[a\nlazy\n> b]]$",
            expectSelectionOnly: true
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "> $a\nlazy\n> b<caret>$",
            to: "> $[[a\nlazy\n> b]]$",
            expectSelectionOnly: true
        )
    }

    func testSingleDashSetextUnderlineEndsTheParagraph() {
        assertMathEdit(
            .insertInlineMath,
            from: "$a\n- \nb<caret>c$",
            to: "$a\n- \nb$[[x]]$c$"
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "$a\n- \nb<caret>$",
            to: "$a\n- \nb\n\n$$\n[[x]]\n$$\n\n$"
        )
        assertMathEdit(
            .insertInlineMath,
            from: "`a\n- \nb<caret>`",
            to: "`a\n- \nb$[[x]]$`"
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "`a\n- \nb<caret>`",
            to: "`a\n- \nb\n\n$$\n[[x]]\n$$\n\n`"
        )
    }

    func testQuoteMarkerWithNoContentEndsTheParagraph() {
        assertMathEdit(
            .insertInlineMath,
            from: "> $a\n>\n> b<caret>c$",
            to: "> $a\n>\n> b$[[x]]$c$"
        )
        assertNoMathEdit(.insertDisplayMath, from: "> $a\n>\n> b<caret>$")
        assertMathEdit(
            .insertInlineMath,
            from: "> `a\n>\n> b<caret>`",
            to: "> `a\n>\n> b$[[x]]$`"
        )
        assertNoMathEdit(.insertDisplayMath, from: "> `a\n>\n> b<caret>`")
    }

    func testHyphenatedJSXNamespacesBlockDisplayOnly() {
        for name in ["my-ui:Card", "UI:my-card"] {
            let source = "<\(name)>\n\nva<caret>lue\n\n</\(name)>"
            assertMathEdit(
                .insertInlineMath,
                from: source,
                to: "<\(name)>\n\nva$[[x]]$lue\n\n</\(name)>",
                fileKind: .mdx
            )
            assertNoMathEdit(.insertDisplayMath, from: source, fileKind: .mdx)
        }
    }

    func testFunctionExpressionBodyMakesTheFollowingSlashDivision() {
        let inside = "{(() => { const f = function(){} / <caret>2; return f; })()}"
        assertNoMathEditBoth(from: inside, fileKind: .mdx)
        let source = "{(() => { const f = function(){} / 2; return f; })()}\n\nva<caret>lue"
        assertMathEdit(
            .insertInlineMath,
            from: source,
            to: "{(() => { const f = function(){} / 2; return f; })()}\n\nva$[[x]]$lue",
            fileKind: .mdx
        )
        assertMathEdit(
            .insertDisplayMath,
            from: source,
            to: "{(() => { const f = function(){} / 2; return f; })()}\n\nva\n\n$$\n[[x]]\n$$\n\nlue",
            fileKind: .mdx
        )
    }

    func testJSXInsideExpressionDoesNotSwallowTheFollowingParagraph() {
        assertNoMathEditBoth(from: "{<Card>va<caret>lue</Card>}", fileKind: .mdx)
        let source = "{<Card>value</Card>}\n\nva<caret>lue"
        assertMathEdit(
            .insertInlineMath,
            from: source,
            to: "{<Card>value</Card>}\n\nva$[[x]]$lue",
            fileKind: .mdx
        )
        assertMathEdit(
            .insertDisplayMath,
            from: source,
            to: "{<Card>value</Card>}\n\nva\n\n$$\n[[x]]\n$$\n\nlue",
            fileKind: .mdx
        )
    }

    func testComparisonAndObjectColonStillCloseTheExpression() {
        assertMathEdit(
            .insertInlineMath,
            from: "{a < b}\n\nva<caret>lue",
            to: "{a < b}\n\nva$[[x]]$lue",
            fileKind: .mdx
        )
        assertMathEdit(
            .insertInlineMath,
            from: "{{a: 1}}\n\nva<caret>lue",
            to: "{{a: 1}}\n\nva$[[x]]$lue",
            fileKind: .mdx
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
    let input = MathGuardMarkedText(rawInput)
    let expected = MathGuardMarkedText(rawExpected)
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
    let mutable = NSMutableString(string: input.text)
    mutable.replaceCharacters(in: edit.replacementRange, with: edit.replacementString)
    XCTAssertEqual(mutable as String, expected.text, file: file, line: line)
    XCTAssertEqual(edit.newSelection, expected.selection, file: file, line: line)
}

private func assertNoMathEdit(
    _ command: MarkdownFormattingCommand,
    from rawInput: String,
    fileKind: FileKind = .markdown,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let input = MathGuardMarkedText(rawInput)
    let edit = MarkdownEditing.apply(
        .format(command),
        to: input.text,
        selection: input.selection,
        fileKind: fileKind
    )
    XCTAssertNil(edit, "Expected no-op", file: file, line: line)
}

private struct MathGuardMarkedText {
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
