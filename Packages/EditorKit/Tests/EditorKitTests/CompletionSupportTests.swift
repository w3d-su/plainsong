@testable import EditorKit
import Foundation
import MarkdownCore
import STTextView
import XCTest

@MainActor
final class CompletionSupportTests: XCTestCase {
    func testCompletionTriggersIncludeMarkdownContexts() {
        var didEvaluateImmediateTriggerPrefix = false
        func immediateTriggerPrefix() -> String? {
            didEvaluateImmediateTriggerPrefix = true
            return nil
        }

        XCTAssertTrue(EditorCompletionSupport.shouldTriggerCompletion(
            replacementString: "#",
            emojiShortcodePrefixBeforeChange: immediateTriggerPrefix(),
            fileKind: .markdown
        ))
        XCTAssertFalse(didEvaluateImmediateTriggerPrefix)
        XCTAssertTrue(EditorCompletionSupport.shouldTriggerCompletion(
            replacementString: "`",
            emojiShortcodePrefixBeforeChange: nil,
            fileKind: .markdown
        ))
        XCTAssertTrue(EditorCompletionSupport.shouldTriggerCompletion(
            replacementString: "<",
            emojiShortcodePrefixBeforeChange: nil,
            fileKind: .mdx
        ))
        XCTAssertFalse(EditorCompletionSupport.shouldTriggerCompletion(
            replacementString: "<",
            emojiShortcodePrefixBeforeChange: nil,
            fileKind: .markdown
        ))
    }

    func testEmojiCompletionRequiresColonPlusTwoCharacters() {
        XCTAssertFalse(EditorCompletionSupport.shouldTriggerCompletion(
            replacementString: ":",
            emojiShortcodePrefixBeforeChange: nil,
            fileKind: .markdown
        ))
        XCTAssertFalse(EditorCompletionSupport.shouldTriggerCompletion(
            replacementString: "s",
            emojiShortcodePrefixBeforeChange: "",
            fileKind: .markdown
        ))
        XCTAssertTrue(EditorCompletionSupport.shouldTriggerCompletion(
            replacementString: "m",
            emojiShortcodePrefixBeforeChange: "s",
            fileKind: .markdown
        ))
        XCTAssertFalse(EditorCompletionSupport.shouldTriggerCompletion(
            replacementString: "a",
            emojiShortcodePrefixBeforeChange: nil,
            fileKind: .markdown
        ))
    }

    func testCompletionTriggerUsesBoundedEmojiPrefixInsteadOfWholeLine() {
        let textView = STTextView(frame: .zero)
        textView.text = String(repeating: "x", count: 10000) + " :s"
        textView.textSelection = NSRange(location: Self.text(in: textView).utf16.count, length: 0)

        let emojiPrefix = EditorCompletionSupport.emojiShortcodePrefixBeforeSelection(in: textView)

        XCTAssertEqual(emojiPrefix, "s")
        XCTAssertTrue(EditorCompletionSupport.shouldTriggerCompletion(
            replacementString: "m",
            emojiShortcodePrefixBeforeChange: emojiPrefix,
            fileKind: .markdown
        ))
    }

    func testCompletionTriggerDoesNotScanPastBoundedEmojiPrefix() {
        let textView = STTextView(frame: .zero)
        textView.text = ":" + String(repeating: "s", count: 100)
        textView.textSelection = NSRange(location: Self.text(in: textView).utf16.count, length: 0)

        XCTAssertNil(EditorCompletionSupport.emojiShortcodePrefixBeforeSelection(in: textView, limit: 64))
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

    func testRecentCompletionIDsMoveSelectedItemToFrontAndStayBounded() {
        let existing = (0 ..< 25).map { "filePath:post-\($0).md" }

        let updated = EditorCompletionSupport.recentCompletionIDs(
            selecting: "filePath:post-10.md",
            existing: existing
        )

        XCTAssertEqual(updated.first, "filePath:post-10.md")
        XCTAssertEqual(updated.count, 20)
        XCTAssertEqual(updated.filter { $0 == "filePath:post-10.md" }.count, 1)
        XCTAssertFalse(updated.contains("filePath:post-20.md"))
    }

    private static func text(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }
}
