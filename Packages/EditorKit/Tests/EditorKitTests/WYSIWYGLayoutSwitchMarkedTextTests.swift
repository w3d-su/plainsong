import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// Switching between a source layout and WYSIWYG swaps the content storage delegate and
/// invalidates the whole document's layout (`setWYSIWYGZeroWidthFoldingEnabled`), with no
/// `hasMarkedText()` guard. The switch can come from the toolbar while Zhuyin is composing,
/// so it must leave the marked text, its range and the committed result alone.
@MainActor
final class WYSIWYGLayoutSwitchMarkedTextTests: XCTestCase {
    func testSwitchingLayoutWhileComposingZhuyinKeepsTheMarkedTextAndCommit() throws {
        let source = "Intro **bold** and [a link](https://example.com) tail\n"
        // Right after the hidden `](https://example.com)` while folded.
        let caret = (source as NSString).range(of: " tail").location
        for startsFolded in [false, true] {
            let label = startsFolded ? "WYSIWYG → source → WYSIWYG" : "source → WYSIWYG → source"
            let textView = try makeEditor(source, folded: startsFolded)
            let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: textView))
            textView.textSelection = NSRange(location: caret, length: 0)

            textView.setMarkedText("ㄓ", selectedRange: NSRange(location: 1, length: 0), replacementRange: .notFound)
            XCTAssertEqual(textView.markedRange(), NSRange(location: caret, length: 1), label)

            XCTAssertTrue(textView.setWYSIWYGZeroWidthFoldingEnabled(!startsFolded), label)
            textView.layoutSubtreeIfNeeded()

            XCTAssertTrue(textView.hasMarkedText(), "\(label): the first switch dropped the composition")
            XCTAssertEqual(textView.markedRange(), NSRange(location: caret, length: 1), label)
            XCTAssertEqual(textView.selectedRange(), NSRange(location: caret + 1, length: 0), label)

            textView.setMarkedText("ㄓㄨˊ", selectedRange: NSRange(location: 3, length: 0), replacementRange: .notFound)
            XCTAssertTrue(textView.setWYSIWYGZeroWidthFoldingEnabled(startsFolded), label)
            textView.layoutSubtreeIfNeeded()

            XCTAssertTrue(textView.hasMarkedText(), "\(label): the second switch dropped the composition")
            XCTAssertEqual(textView.markedRange(), NSRange(location: caret, length: 3), label)

            textView.insertText("竹", replacementRange: .notFound)

            XCTAssertFalse(textView.hasMarkedText(), label)
            XCTAssertEqual(
                storage.string,
                (source as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: "竹"),
                label
            )
            XCTAssertEqual(textView.selectedRange(), NSRange(location: caret + 1, length: 0), label)
        }
    }

    private func makeEditor(_ source: String, folded: Bool) throws -> MarkdownSTTextView {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 240)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.isEditable = true
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        TestWindowTeardown.hideAfterCurrentTest(window)
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        textView.text = source
        XCTAssertTrue(textView.setWYSIWYGZeroWidthFoldingEnabled(folded))
        // Fold with the caret at the end, so the link and bold spans are folded.
        let end = (source as NSString).length
        let highlighted = MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: end),
            developmentPresentation: folded ? .inlineFoldRevealWithLinkFolding : .source,
            selection: NSRange(location: end, length: 0)
        )
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(
            HighlightedText(
                revision: 1,
                range: highlighted.range,
                text: highlighted.text,
                foldPlan: highlighted.foldPlan
            ),
            to: textView
        ))
        textView.layoutSubtreeIfNeeded()
        return textView
    }
}
