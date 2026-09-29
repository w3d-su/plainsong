import Foundation
@testable import MarkdownCore
import XCTest

/// One test group per rule of `MathInsertionContext`, plus the accepted limitations.
final class MathInsertionContextTests: XCTestCase {
    // MARK: - Rule 1: frontmatter

    func testCaretOnClosingFrontmatterDelimiterIsRefused() {
        assertNoMathEditBoth(from: "---\na: 1\n---<caret>\nbody")
        assertNoMathEditBoth(from: "---\na: 1\n...<caret>\nbody")
    }

    func testBodyAfterFrontmatterIsAllowed() {
        assertMathEdit(
            .insertInlineMath,
            from: "---\na: 1\n---\n<caret>body",
            to: "---\na: 1\n---\n$[[x]]$body"
        )
    }

    func testSelectionStartingInFrontmatterIsRefused() {
        assertNoMathEditBoth(from: "---\na: [[1\n---\nbo]]dy")
    }

    func testUnclosedFrontmatterOpenerIsNotFrontmatter() {
        assertMathEdit(
            .insertInlineMath,
            from: "---\ntext <caret>here",
            to: "---\ntext $[[x]]$here"
        )
    }

    func testFrontmatterOnlyCountsAtOffsetZero() {
        assertMathEdit(
            .insertInlineMath,
            from: "intro\n---\na: <caret>1\n---",
            to: "intro\n---\na: $[[x]]$1\n---"
        )
    }

    func testFrontmatterWithCRLF() {
        assertNoMathEditBoth(from: "---\r\ntitle: <caret>x\r\n---\r\nbody")
    }

    // MARK: - Rule 2: fenced code and math fences

    func testTildeFenceNeedsAClosingFenceOfEqualOrGreaterLength() {
        // Three tildes cannot close a four-tilde fence, so the caret is still inside.
        assertNoMathEditBoth(from: "~~~~\ncode\n~~~\n<caret>x\n~~~~")
        assertMathEdit(
            .insertInlineMath,
            from: "~~~\ncode\n~~~\nafter <caret>text",
            to: "~~~\ncode\n~~~\nafter $[[x]]$text"
        )
    }

    func testDifferentFenceCharacterDoesNotClose() {
        assertNoMathEditBoth(from: "```\ncode\n~~~\nstill <caret>code")
    }

    func testTextAfterAClosedFenceIsAllowed() {
        assertMathEdit(
            .insertInlineMath,
            from: "```\ncode\n```\nafter <caret>text",
            to: "```\ncode\n```\nafter $[[x]]$text"
        )
        assertMathEdit(
            .insertInlineMath,
            from: "before <caret>text\n```\ncode\n```",
            to: "before $[[x]]$text\n```\ncode\n```"
        )
    }

    func testFourSpaceIndentedFenceMarkerIsNotAFence() {
        assertMathEdit(
            .insertInlineMath,
            from: "    ```\nfoo <caret>bar",
            to: "    ```\nfoo $[[x]]$bar"
        )
    }

    func testBacktickFenceInfoStringMayNotContainBackticks() {
        assertMathEdit(
            .insertInlineMath,
            from: "``` a`b\nfoo <caret>bar",
            to: "``` a`b\nfoo $[[x]]$bar"
        )
    }

    func testUnclosedFenceRunsToTheEndOfTheDocument() {
        assertNoMathEditBoth(from: "```\nfoo <caret>bar")
    }

    func testFenceWithCRLF() {
        assertNoMathEditBoth(from: "```\r\ncode <caret>x\r\n```")
    }

    func testMathFenceWithCRLFSelectsInner() {
        assertMathEdit(
            .insertInlineMath,
            from: "```math\r\nx <caret>+ 1\r\n```",
            to: "```math\r\n[[x + 1]]\r\n```",
            expectSelectionOnly: true
        )
    }

    func testMathFenceWithMultipleLinesSelectsAllInnerLines() {
        assertMathEdit(
            .insertDisplayMath,
            from: "```math\na = 1\nb <caret>= 2\n```",
            to: "```math\n[[a = 1\nb = 2]]\n```",
            expectSelectionOnly: true
        )
    }

    func testSelectionStraddlingAFenceBoundaryIsRefused() {
        assertNoMathEditBoth(from: "[[para\n```]]\ncode\n```")
        assertNoMathEditBoth(from: "```math\n[[x\n```\nafter]]")
    }

    // MARK: - Rule 3: inline code

    func testCaretRightOutsideACodeSpanIsAllowed() {
        assertMathEdit(
            .insertInlineMath,
            from: "`code`<caret> x",
            to: "`code`$[[x]]$ x"
        )
        assertMathEdit(
            .insertInlineMath,
            from: "x <caret>`code`",
            to: "x $[[x]]$`code`"
        )
    }

    func testDoubleBacktickSpanMayContainASingleBacktick() {
        assertNoMathEditBoth(from: "`` a`b <caret>`` z")
    }

    func testSelectionOverlappingACodeSpanIsRefused() {
        assertNoMathEdit(.insertInlineMath, from: "a [[b `c]] d`")
        assertNoMathEdit(.insertInlineMath, from: "a `b [[c` d]]")
    }

    func testInlineCodeWithEmojiAndCJKOffsets() {
        assertNoMathEditBoth(from: "😀 `co<caret>de`")
        assertNoMathEditBoth(from: "中文 `代碼<caret>` 後")
        assertMathEdit(
            .insertInlineMath,
            from: "中文 <caret>`代碼`",
            to: "中文 $[[x]]$`代碼`"
        )
    }

    func testInlineCodeOnAnotherLineDoesNotAffectTheCaretLine() {
        assertMathEdit(
            .insertInlineMath,
            from: "`open\nmid <caret>line\nclose`",
            to: "`open\nmid $[[x]]$line\nclose`"
        )
    }

    // MARK: - Rule 4: existing formula

    func testDoubleDollarSpanOnOneLineIsAFormula() {
        assertMathEdit(
            .insertInlineMath,
            from: "a $$x <caret>+ 1$$ b",
            to: "a $$[[x + 1]]$$ b",
            expectSelectionOnly: true
        )
    }

    func testEscapedDollarBeforeAFormulaIsIgnored() {
        assertMathEdit(
            .insertInlineMath,
            from: "cost \\$5 and $x<caret>$",
            to: "cost \\$5 and $[[x]]$",
            expectSelectionOnly: true
        )
    }

    func testCaretJustOutsideAFormulaIsNotInsideIt() {
        assertNoMathEdit(.insertInlineMath, from: "$x$<caret> tail")
        assertNoMathEdit(.insertInlineMath, from: "head <caret>$x$")
    }

    func testDollarBlockWithIndentAndTrailingSpacesSelectsInner() {
        assertMathEdit(
            .insertInlineMath,
            from: "  $$  \nx <caret>+ 1\n$$",
            to: "  $$  \n[[x + 1]]\n$$",
            expectSelectionOnly: true
        )
    }

    func testDollarBlockWithCRLFSelectsInner() {
        assertMathEdit(
            .insertDisplayMath,
            from: "$$\r\nx <caret>+ 1\r\n$$",
            to: "$$\r\n[[x + 1]]\r\n$$",
            expectSelectionOnly: true
        )
    }

    func testDollarBlockWithEmojiSelectsInnerByUTF16Length() {
        assertMathEdit(
            .insertInlineMath,
            from: "$$\n😀 <caret>x\n$$",
            to: "$$\n[[😀 x]]\n$$",
            expectSelectionOnly: true
        )
    }

    func testUnclosedDollarBlockIsRefused() {
        assertNoMathEditBoth(from: "$$\nx <caret>+ 1")
    }

    func testTextAfterAClosedDollarBlockIsAllowed() {
        assertMathEdit(
            .insertInlineMath,
            from: "$$\nx\n$$\nafter <caret>text",
            to: "$$\nx\n$$\nafter $[[x]]$text"
        )
    }

    // MARK: - Rule 5: MDX import/export

    func testMDXImportAndExportLinesAreRefused() {
        assertNoMathEditBoth(from: "import Foo from './foo'<caret>", fileKind: .mdx)
        assertNoMathEditBoth(from: "export const a = 1<caret>", fileKind: .mdx)
        assertNoMathEditBoth(from: "intro\n\nimport Foo from './foo'\nexport <caret>x", fileKind: .mdx)
    }

    func testMDXWordsThatMerelyStartWithImportAreAllowed() {
        assertMathEdit(
            .insertInlineMath,
            from: "important <caret>note",
            to: "important $[[x]]$note",
            fileKind: .mdx
        )
    }

    func testMarkdownFilesDoNotApplyTheImportRule() {
        assertMathEdit(
            .insertInlineMath,
            from: "import <caret>things",
            to: "import $[[x]]$things",
            fileKind: .markdown
        )
    }

    /// Accepted limitation: `{…}` expressions and JSX are not detected, so the command
    /// inserts inside them. The edit is one Undo away and the preview shows the error.
    func testKnownLimitationMDXExpressionAndJSXAreNotRefused() {
        assertMathEdit(
            .insertInlineMath,
            from: "result: {a <caret>+ b}",
            to: "result: {a $[[x]]$+ b}",
            fileKind: .mdx
        )
        assertMathEdit(
            .insertInlineMath,
            from: "<Foo bar=\"<caret>\" />",
            to: "<Foo bar=\"$[[x]]$\" />",
            fileKind: .mdx
        )
    }

    // MARK: - Rule 6: display math placement

    func testDisplayMathRefusesBlockConstructLines() {
        assertNoMathEdit(.insertDisplayMath, from: "# Ti<caret>tle")
        assertNoMathEdit(.insertDisplayMath, from: "para\n### Ti<caret>tle\nmore")
        assertNoMathEdit(.insertDisplayMath, from: "> quo<caret>ted")
        assertNoMathEdit(.insertDisplayMath, from: "| a | b |\n|---|---|\n| 1 | <caret>2 |")
        assertNoMathEdit(.insertDisplayMath, from: "- it<caret>em")
        assertNoMathEdit(.insertDisplayMath, from: "* it<caret>em")
        assertNoMathEdit(.insertDisplayMath, from: "+ it<caret>em")
        assertNoMathEdit(.insertDisplayMath, from: "1. it<caret>em")
        assertNoMathEdit(.insertDisplayMath, from: "12) it<caret>em")
        assertNoMathEdit(.insertDisplayMath, from: "   - it<caret>em")
    }

    func testDisplayMathAllowsLookalikeParagraphs() {
        assertMathEdit(
            .insertDisplayMath,
            from: "-wo<caret>rd",
            to: "-wo\n\n$$\n[[x]]\n$$\n\nrd"
        )
        assertMathEdit(
            .insertDisplayMath,
            from: "1.5 is <caret>a number",
            to: "1.5 is \n\n$$\n[[x]]\n$$\n\na number"
        )
    }

    func testDisplayMathSelectionSpanningParagraphsIsRefused() {
        assertNoMathEdit(.insertDisplayMath, from: "a [[b\n\nc]] d")
    }

    func testDisplayMathSelectionCoveringABlockLineIsRefused() {
        assertNoMathEdit(.insertDisplayMath, from: "a [[b\n> c]] d")
    }

    func testInlineMathIsAllowedOnBlockConstructLines() {
        assertMathEdit(.insertInlineMath, from: "# Ti<caret>tle", to: "# Ti$[[x]]$tle")
        assertMathEdit(.insertInlineMath, from: "> quo<caret>ted", to: "> quo$[[x]]$ted")
        assertMathEdit(.insertInlineMath, from: "- it<caret>em", to: "- it$[[x]]$em")
    }

    /// Accepted limitation: only the line prefix is inspected, so a list continuation
    /// paragraph or an indented-code line is not recognised as a container.
    func testKnownLimitationListContinuationParagraphIsNotRefused() {
        assertMathEdit(
            .insertDisplayMath,
            from: "- item\n\n  continued <caret>here",
            to: "- item\n\n  continued \n\n$$\n[[x]]\n$$\n\nhere"
        )
    }
}
