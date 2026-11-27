import AppKit
@testable import EditorKit
import SwiftUI
import XCTest

/// Committing a composition must leave the caret where the editing behavior that handled
/// the committed text put it.
@MainActor
final class MarkedTextCommitSelectionTests: XCTestCase {
    func testCommittedNewlineKeepsTheListContinuationCaret() {
        let editor = makeEditor(source: "- item", caret: 6)

        editor.textView.setMarkedText(
            "x",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        editor.textView.insertText("\n", replacementRange: .notFound)

        XCTAssertEqual(text(in: editor.textView), "- item\n- ")
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 9, length: 0))
    }

    func testCommittedOpeningBracketKeepsTheCaretInsideThePair() {
        let editor = makeEditor(source: "", caret: 0)

        editor.textView.setMarkedText(
            "x",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        editor.textView.insertText("(", replacementRange: .notFound)

        XCTAssertEqual(text(in: editor.textView), "()")
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 1, length: 0))
    }

    func testRejectedCommitLeavesTheCaretInsideTheText() {
        let editor = makeEditor(source: "ab", caret: 2)
        editor.textView.setMarkedText(
            "x",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        editor.textView.isEditable = false

        editor.textView.insertText("a long committed string", replacementRange: .notFound)

        let length = (text(in: editor.textView) as NSString).length
        XCTAssertLessThanOrEqual(NSMaxRange(editor.textView.selectedRange()), length)
    }

    func testPlainCommitPlacesTheCaretAfterTheCommittedText() {
        let editor = makeEditor(source: "ab", caret: 1)

        editor.textView.setMarkedText(
            "x",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        editor.textView.insertText("中文", replacementRange: .notFound)

        XCTAssertEqual(text(in: editor.textView), "a中文b")
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 3, length: 0))
    }

    private struct Editor {
        let textView: MarkdownSTTextView
        let coordinator: MarkdownTextViewCoordinator
    }

    private func makeEditor(source: String, caret: Int) -> Editor {
        let model = Model(text: source)
        let coordinator = MarkdownTextViewCoordinator(
            text: Binding(get: { model.text }, set: { model.text = $0 }),
            selection: .constant(nil)
        )
        let textView = MarkdownSTTextView(frame: .zero)
        textView.textDelegate = coordinator
        textView.text = source
        textView.textSelection = NSRange(location: caret, length: 0)
        return Editor(textView: textView, coordinator: coordinator)
    }

    private func text(in textView: MarkdownSTTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? ""
    }

    private final class Model {
        var text: String
        init(text: String) {
            self.text = text
        }
    }
}
