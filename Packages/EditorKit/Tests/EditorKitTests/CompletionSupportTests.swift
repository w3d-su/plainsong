@testable import EditorKit
import Foundation
import MarkdownCore
import STTextView
import SwiftUI
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

    func testCoordinatorRequestsCompletionAfterMDXComponentTrigger() async {
        let textView = CompletionProbeTextView(frame: .zero)
        let source = "import Card from \"./Card\"\n\n"
        textView.text = source
        textView.textSelection = NSRange(location: source.utf16.count, length: 0)
        let coordinator = Self.makeCoordinator(fileKind: .mdx, textView: textView)

        let shouldChange = coordinator.textView(
            textView,
            shouldChangeTextIn: Self.insertionTextRange(in: textView),
            replacementString: "<"
        )

        XCTAssertFalse(shouldChange)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(textView.completeCallCount, 1)
    }

    func testCoordinatorReturnsMDXComponentItemsInTagContext() async {
        let textView = STTextView(frame: .zero)
        let source = "import Card from \"./Card\"\n\n<"
        textView.text = source
        textView.textSelection = NSRange(location: source.utf16.count, length: 0)
        let coordinator = Self.makeCoordinator(fileKind: .mdx, textView: textView)
        coordinator.updateCompletionWorkspace(CompletionWorkspace(
            currentFilePath: "page.mdx",
            componentNames: ["Card"]
        ))

        let items = await coordinator.textView(
            textView,
            completionItemsAtLocation: Self.textLocation(in: textView)
        )

        let completions = items?.compactMap { ($0 as? MarkdownCompletionItem)?.completion } ?? []
        XCTAssertTrue(completions.contains { $0.label == "Card" && $0.kind == .component })
    }

    func testCoordinatorDoesNotReturnMDXComponentItemsInsideFencedCode() async {
        let textView = STTextView(frame: .zero)
        let source = """
        import Card from "./Card"

        ```tsx
        <
        ```
        """
        let cursor = source.range(of: "<").map { source[..<$0.upperBound].utf16.count } ?? source.utf16.count
        textView.text = source
        textView.textSelection = NSRange(location: cursor, length: 0)
        let coordinator = Self.makeCoordinator(fileKind: .mdx, textView: textView)
        coordinator.updateCompletionWorkspace(CompletionWorkspace(
            currentFilePath: "page.mdx",
            componentNames: ["Card"]
        ))

        let items = await coordinator.textView(
            textView,
            completionItemsAtLocation: Self.textLocation(in: textView)
        )

        XCTAssertNil(items)
    }

    private static func text(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }

    private static func makeCoordinator(
        fileKind: FileKind,
        textView: STTextView
    ) -> MarkdownTextViewCoordinator {
        let coordinator = MarkdownTextViewCoordinator(
            text: .constant(text(in: textView)),
            selection: .constant(textView.selectedRange())
        )
        let commandProxy = EditorCommandProxy()
        commandProxy.update(fileKind: fileKind)
        coordinator.attachCommandProxy(commandProxy, to: textView)
        return coordinator
    }

    private static func insertionTextRange(in textView: STTextView) -> NSTextRange {
        let contentManager = textView.textContentManager
        let documentStart = contentManager.documentRange.location
        let location = contentManager.location(
            documentStart,
            offsetBy: textView.selectedRange().location
        ) ?? contentManager.documentRange.endLocation
        return NSTextRange(location: location, end: location)!
    }

    private static func textLocation(in textView: STTextView) -> any NSTextLocation {
        insertionTextRange(in: textView).location
    }
}

@MainActor
private final class CompletionProbeTextView: STTextView {
    var completeCallCount = 0

    override func complete(_: Any?) {
        completeCallCount += 1
    }
}
