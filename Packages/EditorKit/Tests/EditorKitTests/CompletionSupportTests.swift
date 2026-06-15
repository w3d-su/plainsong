@testable import EditorKit
import Foundation
import MarkdownCore
import STTextView
import XCTest

@MainActor
final class CompletionSupportTests: XCTestCase {
    func testCompletionTriggersIncludeMarkdownContextsAndEmojiContinuation() {
        XCTAssertTrue(EditorCompletionSupport.shouldTriggerCompletion(
            replacementString: "#",
            textBeforeChange: "",
            selection: NSRange(location: 0, length: 0),
            fileKind: .markdown
        ))
        XCTAssertTrue(EditorCompletionSupport.shouldTriggerCompletion(
            replacementString: "`",
            textBeforeChange: "``",
            selection: NSRange(location: 2, length: 0),
            fileKind: .markdown
        ))
        XCTAssertTrue(EditorCompletionSupport.shouldTriggerCompletion(
            replacementString: "m",
            textBeforeChange: ":s",
            selection: NSRange(location: 2, length: 0),
            fileKind: .markdown
        ))
        XCTAssertTrue(EditorCompletionSupport.shouldTriggerCompletion(
            replacementString: "<",
            textBeforeChange: "",
            selection: NSRange(location: 0, length: 0),
            fileKind: .mdx
        ))
        XCTAssertFalse(EditorCompletionSupport.shouldTriggerCompletion(
            replacementString: "a",
            textBeforeChange: "plain",
            selection: NSRange(location: 5, length: 0),
            fileKind: .markdown
        ))
        XCTAssertFalse(EditorCompletionSupport.shouldTriggerCompletion(
            replacementString: "<",
            textBeforeChange: "",
            selection: NSRange(location: 0, length: 0),
            fileKind: .markdown
        ))
    }

    func testCompletionInsertionReplacesEngineRangeAndMovesSelection() {
        let textView = STTextView(frame: .zero)
        textView.text = "```sw"
        textView.textSelection = NSRange(location: 5, length: 0)
        let completion = Completion(
            label: "swift",
            insertText: "swift",
            kind: .language,
            replacementRange: NSRange(location: 3, length: 2)
        )
        let editingGuard = EditingBehaviorGuard()

        EditorCompletionSupport.insert(completion, into: textView, editingGuard: editingGuard)

        XCTAssertEqual(Self.text(in: textView), "```swift")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 8, length: 0))
        XCTAssertFalse(editingGuard.isApplying)
    }

    func testCompletionInsertionClampsNotFoundReplacementRangeToDocumentStart() {
        let textView = STTextView(frame: .zero)
        textView.text = "body"
        textView.textSelection = NSRange(location: 4, length: 0)
        let completion = Completion(
            label: "title",
            insertText: "title: ",
            kind: .frontmatterKey,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let editingGuard = EditingBehaviorGuard()

        EditorCompletionSupport.insert(completion, into: textView, editingGuard: editingGuard)

        XCTAssertEqual(Self.text(in: textView), "title: body")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 7, length: 0))
        XCTAssertFalse(editingGuard.isApplying)
    }

    private static func text(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }
}
