import Foundation
@testable import MarkdownCore
import XCTest

/// Scanner cases where the preview's parser accepts the source: the zone scan
/// must agree with it about where code spans and MDX expressions end.
final class MathEditingScannerRegressionTests: XCTestCase {
    // MARK: - Lazy continuation lines

    func testLazySetextLikeLineStaysInsideQuotedCodeSpan() {
        for middle in ["=", "==", "= =", "--", "#x"] {
            assertNoMathEditBoth(from: "> ``a\n\(middle)\n> b<caret>``")
        }
    }

    /// Read outside the quote, any list marker opens a list — even an empty
    /// item or one starting at 2 — so the quote and its code span end there.
    func testLazyListMarkerEndsTheQuote() {
        for middle in ["-", "- ", "*", "+", "- -", "1.", "2. x"] {
            assertMathEdit(
                .insertInlineMath,
                from: "> ``a\n\(middle)\n> b<caret>``",
                to: "> ``a\n\(middle)\n> b$[[x]]$``"
            )
        }
    }

    func testLazyInvalidBacktickFenceStaysInsideQuotedCodeSpan() {
        assertNoMathEditBoth(from: "> ``a\n```bad`info\n> b<caret>``")
    }

    func testLazyThematicBreakAndFenceStillEndTheQuote() {
        assertMathEdit(
            .insertInlineMath,
            from: "> ``a\n---\n> b<caret>``",
            to: "> ``a\n---\n> b$[[x]]$``"
        )
        assertMathEdit(
            .insertInlineMath,
            from: "> ``a\n```ok\n```\n> b<caret>``",
            to: "> ``a\n```ok\n```\n> b$[[x]]$``"
        )
        for middle in ["***", "# h"] {
            assertMathEdit(
                .insertInlineMath,
                from: "> ``a\n\(middle)\n> b<caret>``",
                to: "> ``a\n\(middle)\n> b$[[x]]$``"
            )
        }
    }

    // MARK: - Setext underline spacing

    /// A setext underline is one unbroken `=`/`-` run; `= =` is paragraph text.
    func testSpacedEqualsIsParagraphTextNotASetextUnderline() {
        for source in [
            "``a\n= =\nb<caret>``",
            "> ``a\n> = =\n> b<caret>``",
            "> > ``a\n> > = =\n> > b<caret>``",
        ] {
            assertNoMathEditBoth(from: source)
            assertNoMathEditBoth(from: source + "\n")
        }
    }

    func testSpacedEqualsKeepsAnExistingFormulaWhole() {
        for command in [MarkdownFormattingCommand.insertInlineMath, .insertDisplayMath] {
            assertMathEdit(command, from: "$a\n= =\nb<caret>eta$", to: "$[[a\n= =\nbeta]]$")
            assertMathEdit(command, from: "> $a\n> = =\n> b<caret>eta$", to: "> $[[a\n> = =\n> beta]]$")
        }
    }

    func testUnbrokenEqualsRunIsStillASetextUnderline() {
        for underline in ["==", "=  ", "  =="] {
            assertMathEdit(
                .insertInlineMath,
                from: "``a\n\(underline)\nb<caret>``",
                to: "``a\n\(underline)\nb$[[x]]$``"
            )
        }
    }

    /// Only ASCII space and tab are Markdown whitespace. NBSP or EM SPACE
    /// around `==` makes the line paragraph text, not a setext underline.
    func testUnicodeSpaceBesideEqualsIsParagraphText() {
        let nbsp = "\u{00A0}"
        let emSpace = "\u{2003}"
        for suffix in ["", "\n"] {
            assertNoMathEditBoth(from: "``a\n==\(nbsp)\nb<caret>``" + suffix)
            for command in [MarkdownFormattingCommand.insertInlineMath, .insertDisplayMath] {
                assertMathEdit(
                    command,
                    from: "$a\n==\(nbsp)\nb<caret>eta$" + suffix,
                    to: "$[[a\n==\(nbsp)\nbeta]]$" + suffix
                )
            }
            for underline in ["==\(nbsp)", "==\(emSpace)", "\(nbsp)=="] {
                assertMathEdit(
                    .insertDisplayMath,
                    from: "va<caret>lue\n\(underline)" + suffix,
                    to: "va\n\n$$\n[[x]]\n$$\n\nlue\n\(underline)" + suffix
                )
            }
        }
    }

    func testUnicodeSpaceDoesNotFormHeadingOrQuoteMarkers() {
        let nbsp = "\u{00A0}"
        for line in ["\(nbsp)# h", "#\(nbsp)h", "\(nbsp)> q"] {
            assertMathEdit(
                .insertDisplayMath,
                from: "\(line) va<caret>lue",
                to: "\(line) va\n\n$$\n[[x]]\n$$\n\nlue"
            )
        }
    }

    func testASCIIWhitespaceAroundEqualsStillFormsASetextHeading() {
        for underline in ["==  ", "==\t", "  =="] {
            assertNoMathEdit(.insertDisplayMath, from: "va<caret>lue\n\(underline)")
        }
    }

    // MARK: - MDX expressions

    func testFunctionDeclarationBodyIsFollowedByAStatement() {
        assertNoMathEditBoth(
            from: "{(() => { function f() {} /[}}]/.test(va<caret>lue); })()}",
            fileKind: .mdx
        )
    }

    func testAsyncAndGeneratorDeclarationsAreFollowedByAStatement() {
        for head in ["async function f()", "function* g()", "function * g()", "async function* g()"] {
            let source = "{(() => { \(head) {} /[}}]/.test(va<caret>lue); })()}"
            assertNoMathEditBoth(from: source, fileKind: .mdx)
            assertNoMathEditBoth(from: source + "\n", fileKind: .mdx)
        }
    }

    /// ASI: an operand cannot be followed by `function`, so after a line
    /// break the keyword starts a declaration statement.
    func testFunctionAfterALineBreakEndingAStatementIsADeclaration() {
        for source in [
            "{(() => { const a=1\nfunction f() {} /[}}]/.test(va<caret>lue); })()}",
            "{(() => { const a=1\nasync function f() {} /[}}]/.test(va<caret>lue); })()}",
        ] {
            assertNoMathEditBoth(from: source, fileKind: .mdx)
            assertNoMathEditBoth(from: source + "\n", fileKind: .mdx)
        }
    }

    /// Comments are trivia between tokens: they neither hide `async function`
    /// nor erase a line break that already ended the previous statement.
    func testCommentsDoNotChangeDeclarationContext() {
        for source in [
            "{(() => { async /* note */ function f() {} /[}}]/.test(va<caret>lue); })()}",
            "{(() => { async/**/function f() {} /[}}]/.test(va<caret>lue); })()}",
            "{(() => { const a=1\n/* note */ function f() {} /[}}]/.test(va<caret>lue); })()}",
        ] {
            assertNoMathEditBoth(from: source, fileKind: .mdx)
            assertNoMathEditBoth(from: source + "\n", fileKind: .mdx)
        }
    }

    /// `return` and `yield` may not be followed by a line break: after one,
    /// ASI ends the statement, so `function` or `{` starts a new statement.
    func testRestrictedKeywordFollowedByALineBreakEndsTheStatement() {
        for source in [
            "{(() => { return\nfunction f() {} /[}}]/.test(va<caret>lue); })()}",
            "{(function*(){ yield\nfunction f() {} /[}}]/.test(va<caret>lue); })()}",
            "{(() => { return\n{} /[}}]/.test(va<caret>lue); })()}",
        ] {
            assertNoMathEditBoth(from: source, fileKind: .mdx)
            assertNoMathEditBoth(from: source + "\n", fileKind: .mdx)
        }
    }

    func testSameLineRestrictedKeywordsAndCommentedExpressionsStayOperands() {
        for expression in [
            "{(() => { return function(){} / 2; })()}",
            "{(() => { return {a:1} / 2; })()}",
            "{(() => { const f = async /* c */ function*(){} / 2; return f; })()}",
            "{(() => { const f = x ||\n/* c */ function(){} / 2; return f; })()}",
        ] {
            assertMathEdit(
                .insertInlineMath,
                from: expression + "\n\nva<caret>lue",
                to: expression + "\n\nva$[[x]]$lue",
                fileKind: .mdx
            )
        }
    }

    func testGeneratorAndMultilineFunctionExpressionsStayOperands() {
        for expression in [
            "{(() => { const f = function*(){} / 2; return f; })()}",
            "{(() => { const f = async function*(){} / 2; return f; })()}",
            "{(() => { const f = function * g(){} / 2; return f; })()}",
            "{(() => { const f = x ||\nfunction(){} / 2; return f; })()}",
            "{(() => { const a = b\n/ 2; return a; })()}",
        ] {
            assertMathEdit(
                .insertInlineMath,
                from: expression + "\n\nva<caret>lue",
                to: expression + "\n\nva$[[x]]$lue",
                fileKind: .mdx
            )
        }
    }

    func testFunctionExpressionBodyIsStillAnOperand() {
        assertMathEdit(
            .insertInlineMath,
            from: "{(() => { const f = function(){} / 2; return f; })()}\n\nva<caret>lue",
            to: "{(() => { const f = function(){} / 2; return f; })()}\n\nva$[[x]]$lue",
            fileKind: .mdx
        )
        assertMathEdit(
            .insertInlineMath,
            from: "{(() => { const f = function g(a = function(){}) {} / 2; })()}\n\nva<caret>lue",
            to: "{(() => { const f = function g(a = function(){}) {} / 2; })()}\n\nva$[[x]]$lue",
            fileKind: .mdx
        )
    }

    func testComparisonWithoutSpacesIsNotJSX() {
        for source in ["{a<b}", "{a < b}", "{(a)<b}", "{a[0]<b}"] {
            assertMathEdit(
                .insertInlineMath,
                from: source + "\n\nva<caret>lue",
                to: source + "\n\nva$[[x]]$lue",
                fileKind: .mdx
            )
        }
    }

    func testJSXInsideAnExpressionInsideJSXReturnsToThatExpression() {
        for source in [
            "{<Outer>{<Inner />}</Outer>}",
            "{<Outer>{cond ? <A>x</A> : <B />}</Outer>}",
            "{<A b={<C />}>t</A>}",
        ] {
            assertMathEdit(
                .insertInlineMath,
                from: source + "\n\nva<caret>lue",
                to: source + "\n\nva$[[x]]$lue",
                fileKind: .mdx
            )
        }
    }

    func testObjectPropertyColonDoesNotConsumeAnOuterTernary() {
        let source = "{(() => { const x = ok ? {a:1} : {} / 2; return x; })()}"
        assertMathEdit(
            .insertInlineMath,
            from: source + "\n\nva<caret>lue",
            to: source + "\n\nva$[[x]]$lue",
            fileKind: .mdx
        )
        let nested = "{(() => { const x = a ? (b ? 1 : {c:2}) : {} / 2; return x; })()}"
        assertMathEdit(
            .insertInlineMath,
            from: nested + "\n\nva<caret>lue",
            to: nested + "\n\nva$[[x]]$lue",
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
    for command in [MarkdownFormattingCommand.insertInlineMath, .insertDisplayMath] {
        let input = ScannerRegressionMarkedText(rawInput)
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
    let input = ScannerRegressionMarkedText(rawInput)
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
    let input = ScannerRegressionMarkedText(rawInput)
    let expected = ScannerRegressionMarkedText(rawExpected)
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

private struct ScannerRegressionMarkedText {
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
