import Foundation
@testable import MarkdownCore
import XCTest

/// Cases where acorn — the preview's MDX expression parser — reads `/` or `{`
/// differently from plain JavaScript intuition, and GFM table/indent rules.
/// Each source and its expected extent was checked against the real
/// `renderMarkdown` / `renderMdx` pipeline.
final class MathEditingAcornContextTests: XCTestCase {
    // MARK: - acorn token contexts

    func testClassExpressionBodyIsAnOperand() {
        for expression in [
            "{(() => { const A = class {} / 2; return A; })()}",
            "{(() => { const A = class B extends C {} / 2; return A; })()}",
        ] {
            assertMathEdit(
                .insertInlineMath,
                from: expression + "\n\nva<caret>lue",
                to: expression + "\n\nva$[[x]]$lue",
                fileKind: .mdx
            )
        }
        assertNoMathEditBoth(
            from: "{(() => { class A {} /[}}]/.test(va<caret>lue); })()}",
            fileKind: .mdx
        )
    }

    /// acorn marks a `function` after any `:` inside a statement block as a
    /// statement (its tokenizer cannot tell a ternary from a label), so after
    /// the body `/` starts a regex; the line break makes that valid by ASI.
    func testFunctionAfterTernaryColonInABlockIsFollowedByARegex() {
        assertNoMathEditBoth(
            from: "{(function*(){ a ? b : function f() {}\n/[}}]/.test(va<caret>lue); })()}",
            fileKind: .mdx
        )
    }

    /// acorn's `async function` override lands on the token after `function`:
    /// the function context for a name, the parameter paren for `(`.
    func testAsyncFunctionExpressionOverrideFollowsAcorn() {
        let named = "{(() => { const f = async function f() {} / 2; return f; })()}"
        assertMathEdit(
            .insertInlineMath,
            from: named + "\n\nva<caret>lue",
            to: named + "\n\nva$[[x]]$lue",
            fileKind: .mdx
        )
        assertNoMathEditBoth(
            from: "{(function*(){ x = async function() {}\n/[}}]/.test(va<caret>lue); })()}",
            fileKind: .mdx
        )
    }

    /// `async⏎{}`: acorn tokenizes that block as an object, but the parser
    /// reads a block statement and re-reads the following `/` as a regex.
    func testStatementBlockAfterASIAllowsARegex() {
        assertNoMathEditBoth(
            from: "{(function*(){ async\n{} /[}}]/.test(va<caret>lue); })()}",
            fileKind: .mdx
        )
    }

    // MARK: - Markdown block starters

    func testIndentedHashLineContinuesTheParagraph() {
        assertNoMathEditBoth(from: "``a\n    # h\nb va<caret>lue``")
        assertMathEdit(.insertInlineMath, from: "$a\n    # h\nb va<caret>lue$", to: "$[[a\n    # h\nb value]]$")
    }

    /// A GFM delimiter row only forms a table when its cell count matches the
    /// header line above it, is not lazy, and is indented at most three columns.
    func testDelimiterRowNeedsAMatchingHeader() {
        for row in ["|-|-|", "-|-", "--|--", "|-|-|-|"] {
            assertNoMathEditBoth(from: "``a\n\(row)\nb va<caret>lue``")
        }
        for row in ["|-|", ":-", "-:"] {
            assertMathEdit(
                .insertInlineMath,
                from: "``a\n\(row)\nb va<caret>lue``",
                to: "``a\n\(row)\nb va$[[x]]$lue``"
            )
        }
        assertMathEdit(
            .insertInlineMath,
            from: "``a|b\n-|-\nb va<caret>lue``",
            to: "``a|b\n-|-\nb va$[[x]]$lue``"
        )
        assertNoMathEditBoth(from: "``a|b\n    -|-\nb va<caret>lue``")
        assertNoMathEditBoth(from: "> ``a\n|-|\n> b va<caret>lue``")
    }

    // MARK: - await, for-await, line separators, table cells

    /// `await` is a name token (`exprAllowed` stays false) but `parseAwait`
    /// parses a unary operand and `parseExprAtom` re-reads `/` as a regexp.
    func testAwaitOperandSlashIsARegex() {
        let sources = [
            "{(async()=>{ await /[}}]/.test(va<caret>lue); })()}",
            "{(async function f(){ await /[}}]/.test(va<caret>lue); })()}",
            "{(async()=>{ await\n/[}}]/.test(va<caret>lue); })()}",
            "{(async()=>{ await /*c*/ /[}}]/.test(va<caret>lue); })()}",
        ]
        for source in sources {
            assertNoMathEditBoth(from: source, fileKind: .mdx)
            assertNoMathEditBoth(from: source + "\n", fileKind: .mdx)
        }
    }

    /// The operand is `a` or the regexp; the following `/` is division, so
    /// the next paragraph stays editable. Member names `await` are not operands.
    func testAwaitDivisionDoesNotSwallowTheNextParagraph() {
        let expressions = [
            "{(async()=>{ const x = await a / 2; return x; })()}",
            "{(async()=>{ const x = await /a/ / 2; return x; })()}",
            "{(async()=>{ const x = await + a / 2; return x; })()}",
            "{(async()=>{ const x = obj.await / 2; return x; })()}",
            "{(async()=>{ const x = obj?.await / 2; return x; })()}",
        ]
        for expression in expressions {
            assertEditableParagraph(expression, fileKind: .mdx)
            assertEditableParagraph(expression + "\n", fileKind: .mdx)
        }
    }

    /// `for await (` is a statement head even though `await`, not `for`,
    /// is the token before `(`. Ordinary `for (` is already a statement head.
    func testForAwaitBodySlashIsARegex() {
        let sources = [
            "{(async()=>{ for await (const x of xs) /[}}]/.test(va<caret>lue); })()}",
            "{(async()=>{ for await\n(const x of xs) /[}}]/.test(va<caret>lue); })()}",
            "{(async()=>{ for (const x of xs) /[}}]/.test(va<caret>lue); })()}",
        ]
        for source in sources {
            assertNoMathEditBoth(from: source, fileKind: .mdx)
            assertNoMathEditBoth(from: source + "\n", fileKind: .mdx)
        }
        assertEditableParagraph(
            "{(async()=>{ const x = (a) / 2; return x; })()}",
            fileKind: .mdx
        )
    }

    /// U+2028 and U+2029 are JavaScript line terminators. `return` then a
    /// separator ends the statement, so `{}` is a block and `/` is a regexp.
    /// A comment or `async function` pair is split by the same separator.
    /// NBSP stays ordinary whitespace.
    func testUnicodeLineSeparatorsMatchJavaScriptLineBreaks() {
        for separator in ["\u{2028}", "\u{2029}"] {
            let sources = [
                "{(() => { return\(separator){} /[}}]/.test(va<caret>lue); })()}",
                "{(() => { return\(separator)function f() {} /[}}]/.test(va<caret>lue); })()}",
                "{(() => { const a=1\(separator)async function f() {} /[}}]/.test(va<caret>lue); })()}",
                "{(() => { async\(separator)function f() {} /[}}]/.test(va<caret>lue); })()}",
                "{(() => { async /*\(separator)*/ function f() {} /[}}]/.test(va<caret>lue); })()}",
            ]
            for source in sources {
                assertNoMathEditBoth(from: source, fileKind: .mdx)
                assertNoMathEditBoth(from: source + "\n", fileKind: .mdx)
            }
        }
        assertEditableParagraph(
            "{(() => { return\u{00A0}{} / 2; return 1; })()}",
            fileKind: .mdx
        )
    }

    /// A line break does not finish `parseAwait`. `async function` after it is
    /// the operand, so `/ 2` stays division and the next paragraph is editable.
    /// `return` / `yield` followed by a line break still end the statement.
    func testAwaitAcrossALineBreakStillTakesAnOperand() {
        let expressions = [
            "{(async()=>{ const f = await\nasync function g(){} / 2; return f; })()}",
            "{(async()=>{ const f = await\n/* c */ async function g(){} / 2; return f; })()}",
            "{(async()=>{ const f = await /* c */\nasync function g(){} / 2; return f; })()}",
            "{(async()=>{ const f = await async function g(){} / 2; return f; })()}",
        ]
        for expression in expressions {
            assertEditableParagraph(expression, fileKind: .mdx)
            assertEditableParagraph(expression + "\n", fileKind: .mdx)
        }
        for source in [
            "{(() => { return\nasync function g(){} /[}}]/.test(va<caret>lue); })()}",
            "{(function*(){ yield\nasync function g(){} /[}}]/.test(va<caret>lue); })()}",
        ] {
            assertNoMathEditBoth(from: source, fileKind: .mdx)
            assertNoMathEditBoth(from: source + "\n", fileKind: .mdx)
        }
    }

    /// An even run of backslashes does not escape the following pipe, so the
    /// pipe is a cell boundary. The code span in the first cell stays code.
    /// One backslash still escapes the pipe and keeps the formula in one cell.
    func testEvenBackslashesLeaveThePipeAsACellBoundary() {
        for escapes in ["\\\\", "\\\\\\\\"] {
            let row = "| $left `va<caret>lue` \(escapes)| right$ |"
            let table = "| a | b |\n| - | - |\n\(row)"
            assertNoMathEditBoth(from: table)
            assertNoMathEditBoth(from: table + "\n")
        }
        assertMathEdit(
            .insertInlineMath,
            from: "| a | b |\n| - | - |\n| $left \\\\| va<caret>lue$ |",
            to: "| a | b |\n| - | - |\n| $left \\\\| va$[[x]]$lue$ |"
        )
        assertNoMathEdit(
            .insertDisplayMath,
            from: "| a | b |\n| - | - |\n| $left \\\\| va<caret>lue$ |"
        )
        assertMathEdit(
            .insertInlineMath,
            from: "| a | b |\n| - | - |\n| left \\\\| va<caret>lue |",
            to: "| a | b |\n| - | - |\n| left \\\\| va$[[x]]$lue |"
        )
        assertNoMathEdit(.insertDisplayMath, from: "| a | b |\n| - | - |\n| left \\\\| va<caret>lue |")
        let escaped = "| a | b |\n| - | - |\n| $left \\| va<caret>lue$ | tail |"
        let selected = "| a | b |\n| - | - |\n| $[[left \\| value]]$ | tail |"
        assertMathEdit(.insertInlineMath, from: escaped, to: selected)
        assertMathEdit(.insertDisplayMath, from: escaped, to: selected)
        assertNoMathEditBoth(from: "`$left va<caret>lue \\\\| right$`")
    }

    /// GFM cells and rows bound inline delimiters. An unescaped pipe or a
    /// row end is not inside a formula or code span. The same cell still is.
    /// Pipes in a paragraph, and a delimiter row that does not match, are not
    /// cells.
    func testTableCellsBoundInlineMathAndCode() {
        let tables = [
            "| a | b |\n| - | - |\n| $left | va<caret>lue$ |",
            "| a | b |\n| - | - |\n| `left | va<caret>lue` |",
            "| a | b |\n| - | - |\n| $left | x |\n| va<caret>lue$ | y |",
            "| a | b |\n| - | - |\n| `left | x |\n| va<caret>lue` | y |",
        ]
        for table in tables {
            assertTableCaretIsPlainText(table)
            assertTableCaretIsPlainText(table + "\n")
        }
        assertMathEdit(
            .insertInlineMath,
            from: "| a | b |\n| - | - |\n| $va<caret>lue$ | text |",
            to: "| a | b |\n| - | - |\n| $[[value]]$ | text |"
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "| a | b |\n| - | - |\n| $va<caret>lue$ | text |",
            to: "| a | b |\n| - | - |\n| $[[value]]$ | text |"
        )
        assertNoMathEditBoth(from: "| a | b |\n| - | - |\n| `va<caret>lue` | text |")
        assertMathEdit(
            .insertInlineMath,
            from: "| $a \\| va<caret>lue$ | c |\n| - | - |",
            to: "| $[[a \\| value]]$ | c |\n| - | - |"
        )
        assertMathEdit(
            .insertInlineMath,
            from: "a\\|b | c\n-|-\nva<caret>lue",
            to: "a\\|b | c\n-|-\nva$[[x]]$lue"
        )
        assertNoMathEdit(.insertDisplayMath, from: "a\\|b | c\n-|-\nva<caret>lue")
        assertMathEdit(
            .insertInlineMath,
            from: "$le<caret>ft | value$",
            to: "$[[left | value]]$"
        )
        assertNoMathEditBoth(from: "`le<caret>ft | value`")
    }

    func testDisplayMathAcceptsParagraphWithMismatchedDelimiterRow() {
        assertMathEdit(
            .insertDisplayMath,
            from: "a|b\n|-|-|-|\nva<caret>lue",
            to: "a|b\n|-|-|-|\nva\n\n$$\n[[x]]\n$$\n\nlue"
        )
        assertNoMathEdit(.insertDisplayMath, from: "a|b\n-|-\nva<caret>lue")
    }
}

/// The expression is one MDX expression; the following paragraph accepts both
/// math commands.
private func assertEditableParagraph(
    _ expression: String,
    fileKind: FileKind,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    assertMathEdit(
        .insertInlineMath,
        from: expression + "\n\nva<caret>lue",
        to: expression + "\n\nva$[[x]]$lue",
        fileKind: fileKind,
        file: file,
        line: line
    )
    assertMathEdit(
        .insertDisplayMath,
        from: expression + "\n\nva<caret>lue",
        to: expression + "\n\nva\n\n$$\n[[x]]\n$$\n\nlue",
        fileKind: fileKind,
        file: file,
        line: line
    )
}

/// A caret in a table cell that is not itself a formula or code span: inline
/// math inserts, display math does not.
private func assertTableCaretIsPlainText(
    _ raw: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let inserted = raw.replacingOccurrences(of: "<caret>", with: "$[[x]]$")
    assertMathEdit(.insertInlineMath, from: raw, to: inserted, file: file, line: line)
    assertNoMathEdit(.insertDisplayMath, from: raw, file: file, line: line)
}

private func assertNoMathEditBoth(
    from rawInput: String,
    fileKind: FileKind = .markdown,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    for command in [MarkdownFormattingCommand.insertInlineMath, .insertDisplayMath] {
        let input = AcornContextMarkedText(rawInput)
        let edit = MarkdownEditing.apply(
            .format(command),
            to: input.text,
            selection: input.selection,
            fileKind: fileKind
        )
        XCTAssertNil(edit, "Expected \(command) to no-op", file: file, line: line)
    }
}

private func assertNoMathEdit(
    _ command: MarkdownFormattingCommand,
    from rawInput: String,
    fileKind: FileKind = .markdown,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let input = AcornContextMarkedText(rawInput)
    let edit = MarkdownEditing.apply(
        .format(command),
        to: input.text,
        selection: input.selection,
        fileKind: fileKind
    )
    XCTAssertNil(edit, "Expected \(command) to no-op", file: file, line: line)
}

private func assertMathEdit(
    _ command: MarkdownFormattingCommand,
    from rawInput: String,
    to rawExpected: String,
    fileKind: FileKind = .markdown,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let input = AcornContextMarkedText(rawInput)
    let expected = AcornContextMarkedText(rawExpected)
    guard let edit = MarkdownEditing.apply(
        .format(command),
        to: input.text,
        selection: input.selection,
        fileKind: fileKind
    ) else {
        XCTFail("Expected edit", file: file, line: line)
        return
    }
    let mutableText = NSMutableString(string: input.text)
    mutableText.replaceCharacters(in: edit.replacementRange, with: edit.replacementString)
    XCTAssertEqual(mutableText as String, expected.text, file: file, line: line)
    XCTAssertEqual(edit.newSelection, expected.selection, file: file, line: line)
}

private struct AcornContextMarkedText {
    let text: String
    let selection: NSRange

    init(_ raw: String) {
        if let start = raw.range(of: "[["), let end = raw.range(of: "]]") {
            var text = raw
            text.removeSubrange(end)
            text.removeSubrange(start)
            self.text = text
            selection = NSRange(
                location: raw[..<start.lowerBound].utf16.count,
                length: raw[start.upperBound ..< end.lowerBound].utf16.count
            )
            return
        }
        guard let caret = raw.range(of: "<caret>") else {
            text = raw
            selection = NSRange(location: 0, length: 0)
            return
        }
        var text = raw
        text.removeSubrange(caret)
        self.text = text
        selection = NSRange(location: raw[..<caret.lowerBound].utf16.count, length: 0)
    }
}
