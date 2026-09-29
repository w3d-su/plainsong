import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
import STTextView
import XCTest

/// Undo/redo for the Format-menu math commands: text restores, and redo puts
/// the caret back on the formula's inner selection. Only math commands register
/// that selection fix-up.
@MainActor
final class EditingBehaviorsSupportMathUndoTests: XCTestCase {
    func testInlineMathCommandUndoRedoRestoresTextAndSelection() {
        let textView = STTextView(frame: .zero)
        textView.text = "E = mc^2"
        textView.textSelection = NSRange(location: 0, length: 8)

        EditingBehaviorsSupport.applyCommand(
            .format(.insertInlineMath),
            to: textView,
            editingGuard: EditingBehaviorGuard()
        )
        XCTAssertEqual(Self.text(in: textView), "$E = mc^2$")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 8))

        textView.undoManager?.undo()
        XCTAssertEqual(Self.text(in: textView), "E = mc^2")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 8))

        textView.undoManager?.redo()
        XCTAssertEqual(Self.text(in: textView), "$E = mc^2$")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 8))

        textView.undoManager?.undo()
        textView.undoManager?.redo()
        XCTAssertEqual(Self.text(in: textView), "$E = mc^2$")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 8))
    }

    func testSameLengthDisplayMathReplacementRedoRestoresInnerSelection() {
        // Display math replaces a blank line; seven spaces and `$$\nx\n$$`
        // are both seven UTF-16 units, so a length check cannot see the edit.
        let textView = STTextView(frame: .zero)
        textView.text = "       "
        textView.textSelection = NSRange(location: 3, length: 0)

        EditingBehaviorsSupport.applyCommand(
            .format(.insertDisplayMath),
            to: textView,
            editingGuard: EditingBehaviorGuard()
        )
        XCTAssertEqual(Self.text(in: textView), "$$\nx\n$$")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 1))

        textView.undoManager?.undo()
        XCTAssertEqual(Self.text(in: textView), "       ")

        textView.undoManager?.redo()
        XCTAssertEqual(Self.text(in: textView), "$$\nx\n$$")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 1))
    }

    func testDisplayMathCommandUndoRestoresDocument() {
        let textView = STTextView(frame: .zero)
        textView.text = "para\n\nnext"
        textView.textSelection = NSRange(location: 5, length: 0)

        EditingBehaviorsSupport.applyCommand(
            .format(.insertDisplayMath),
            to: textView,
            editingGuard: EditingBehaviorGuard()
        )
        XCTAssertTrue(Self.text(in: textView).contains("$$"))

        textView.undoManager?.undo()
        XCTAssertEqual(Self.text(in: textView), "para\n\nnext")
    }

    func testOnlyMathCommandsRestoreSelectionOnRedo() throws {
        let textView = STTextView(frame: .zero)
        let editingGuard = EditingBehaviorGuard()
        textView.text = "word"
        textView.textSelection = NSRange(location: 0, length: 4)

        let bold = try XCTUnwrap(EditingBehaviorsSupport.proposedCommand(
            .format(.bold),
            in: textView,
            editingGuard: editingGuard
        ))
        guard case let .textMutation(_, boldRestores) = bold else {
            return XCTFail("Expected bold to mutate text")
        }
        XCTAssertFalse(boldRestores)

        let math = try XCTUnwrap(EditingBehaviorsSupport.proposedCommand(
            .format(.insertInlineMath),
            in: textView,
            editingGuard: editingGuard
        ))
        guard case let .textMutation(_, mathRestores) = math else {
            return XCTFail("Expected inline math to mutate text")
        }
        XCTAssertTrue(mathRestores)
    }

    func testMathCommandInUnsafeContextProposesNothing() {
        let textView = STTextView(frame: .zero)
        textView.text = "```\ncode\n```"
        textView.textSelection = NSRange(location: 6, length: 0)

        let proposal = EditingBehaviorsSupport.proposedCommand(
            .format(.insertInlineMath),
            in: textView,
            editingGuard: EditingBehaviorGuard()
        )
        XCTAssertNil(proposal)
        XCTAssertEqual(Self.text(in: textView), "```\ncode\n```")
    }

    func testFileKindReachesTheMathGuard() {
        let textView = STTextView(frame: .zero)
        textView.text = "import a from 'a'"
        textView.textSelection = NSRange(location: 6, length: 0)
        let editingGuard = EditingBehaviorGuard()

        XCTAssertNil(EditingBehaviorsSupport.proposedCommand(
            .format(.insertInlineMath),
            in: textView,
            editingGuard: editingGuard,
            fileKind: .mdx
        ))
        XCTAssertNotNil(EditingBehaviorsSupport.proposedCommand(
            .format(.insertInlineMath),
            in: textView,
            editingGuard: editingGuard,
            fileKind: .markdown
        ))
    }

    func testMathCommandClassification() {
        XCTAssertTrue(EditingBehaviorsSupport.isMathCommand(.format(.insertInlineMath)))
        XCTAssertTrue(EditingBehaviorsSupport.isMathCommand(.format(.insertDisplayMath)))
        XCTAssertFalse(EditingBehaviorsSupport.isMathCommand(.format(.bold)))
        XCTAssertFalse(EditingBehaviorsSupport.isMathCommand(.formatTable))
    }
}

@MainActor
private extension EditingBehaviorsSupportMathUndoTests {
    static func text(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }
}
