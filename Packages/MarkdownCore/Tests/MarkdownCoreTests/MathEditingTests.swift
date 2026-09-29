import Foundation
@testable import MarkdownCore
import XCTest

/// Insertion behavior for Format ▸ Insert Inline Math / Insert Display Math.
/// Context-guard rules have their own file (`MathInsertionContextTests`).
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
        assertNoMathEdit(.insertInlineMath, from: "line [[one\ntwo]] end")
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
        assertNoMathEdit(.insertInlineMath, from: "run `$x <caret>+ 1$` first")
    }

    func testInlineMathCaretInsideCodeFenceIsNoOp() {
        assertNoMathEdit(.insertInlineMath, from: "```\nlet a <caret>= 1\n```")
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
        assertNoMathEdit(.insertInlineMath, from: "---\ntitle: <caret>Post\n---\nbody")
    }

    func testInlineMathSelectionPartiallyOverlappingFormulaIsNoOp() {
        assertNoMathEdit(.insertInlineMath, from: "see $x[[ + 1$ an]]d more")
    }

    func testInlineMathEscapedDollarDoesNotPair() {
        // The \$ are literal currency; the caret is not inside a formula.
        assertMathEdit(
            .insertInlineMath,
            from: "costs \\$5 and <caret>\\$10",
            to: "costs \\$5 and $[[x]]$\\$10"
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

    // MARK: - Inline math boundaries

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

    func testUnpairedDollarDoesNotSwallowFollowingCodeSpan() {
        for suffix in ["\n", ""] {
            assertNoMathEditBoth(from: "Price $5 and `va<caret>lue`" + suffix)
        }
    }

    func testUnpairedBacktickDoesNotSwallowFollowingFormula() {
        for suffix in ["\n", ""] {
            for command in [MarkdownFormattingCommand.insertInlineMath, .insertDisplayMath] {
                assertMathEdit(
                    command,
                    from: "unmatched ` before $a<caret>+b$" + suffix,
                    to: "unmatched ` before $[[a+b]]$" + suffix,
                    expectSelectionOnly: true
                )
            }
        }
    }

    func testEscapedBacktickDoesNotOpenCodeBeforeFormula() {
        assertMathEdit(
            .insertInlineMath,
            from: "escaped \\` before $a<caret>+b$",
            to: "escaped \\` before $[[a+b]]$",
            expectSelectionOnly: true
        )
    }

    func testUnpairedDelimiterDoesNotCrossALineBreak() {
        assertMathEdit(.insertInlineMath, from: "`code\n\nmo<caret>re`", to: "`code\n\nmo$[[x]]$re`")
        assertMathEdit(.insertInlineMath, from: "$a\n\nb<caret>c$", to: "$a\n\nb$[[x]]$c$")
    }

    // MARK: - Display math

    func testDisplayMathEmptyDocument() {
        assertMathEdit(.insertDisplayMath, from: "<caret>", to: "$$\n[[x]]\n$$")
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

    func testDisplayMathAfterListOnBlankLineIsAllowed() {
        assertMathEdit(
            .insertDisplayMath,
            from: "- item\n\n<caret>",
            to: "- item\n\n$$\n[[x]]\n$$"
        )
    }

    func testDisplayMathInsideCodeFenceIsNoOp() {
        assertNoMathEdit(.insertDisplayMath, from: "```\ncode <caret>here\n```")
    }

    func testDisplayMathInsideFrontmatterIsNoOp() {
        assertNoMathEdit(.insertDisplayMath, from: "---\ntitle: <caret>x\n---\nbody")
    }

    func testDisplayMathCRLFDocument() {
        assertMathEdit(
            .insertDisplayMath,
            from: "a\r\n\r\n<caret>\r\n\r\nb",
            to: "a\r\n\r\n$$\n[[x]]\n$$\r\n\r\nb"
        )
    }

    func testDisplayMathCRLFAdjacentBreaksCountOnce() {
        assertMathEdit(
            .insertDisplayMath,
            from: "a\r\n<caret>b",
            to: "a\r\n\n$$\n[[x]]\n$$\n\nb"
        )
    }

    func testDisplayMathUTF16EmojiDocument() {
        assertMathEdit(
            .insertDisplayMath,
            from: "😀 中文<caret>",
            to: "😀 中文\n\n$$\n[[x]]\n$$"
        )
    }

    func testDisplayMathBesideATXHeadingLineStillAcceptsParagraph() {
        assertMathEdit(
            .insertDisplayMath,
            from: "# Title\npa<caret>ra",
            to: "# Title\npa\n\n$$\n[[x]]\n$$\n\nra"
        )
    }
}
