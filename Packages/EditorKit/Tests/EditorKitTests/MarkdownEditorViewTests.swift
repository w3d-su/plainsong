@testable import EditorKit
import XCTest

final class MarkdownEditorViewTests: XCTestCase {
    func testComputedHighlightCoversTypicalDocuments() {
        XCTAssertTrue(MarkdownEditorView.shouldComputeHighlight(forLength: 0))
        XCTAssertTrue(
            MarkdownEditorView.shouldComputeHighlight(
                forLength: MarkdownEditorView.maxComputedHighlightLength
            )
        )
    }

    func testComputedHighlightStillRunsForVeryLargeDocuments() {
        XCTAssertTrue(
            MarkdownEditorView.shouldComputeHighlight(
                forLength: MarkdownEditorView.maxComputedHighlightLength + 1
            )
        )
    }

    func testHighlightedTextEqualityIsByRevisionOnly() {
        let first = HighlightedText(revision: 1, text: AttributedString("a"))
        let sameRevision = HighlightedText(revision: 1, text: AttributedString("b"))
        let nextRevision = HighlightedText(revision: 2, text: AttributedString("a"))

        XCTAssertEqual(first, sameRevision, "SwiftUI prop diffing must stay O(1) by revision")
        XCTAssertNotEqual(first, nextRevision)
    }

    func testTextViewUpdateSkipsIncomingTextWhileMarkedTextExists() {
        let policy = MarkdownTextViewUpdatePolicy(
            isUserEditing: false,
            hasMarkedText: true,
            incomingTextEqualsCurrentText: false
        )

        XCTAssertFalse(policy.shouldApplyIncomingText)
    }

    func testTextViewUpdateSkipsIncomingTextAfterUserEditingWhenTextAlreadyMatches() {
        let policy = MarkdownTextViewUpdatePolicy(
            isUserEditing: true,
            hasMarkedText: false,
            incomingTextEqualsCurrentText: true
        )

        XCTAssertFalse(policy.shouldApplyIncomingText)
    }

    func testTextViewUpdateDoesNotCompareIncomingTextWhenUserEditingAlreadySkips() {
        var comparisonCount = 0
        func compareIncomingText() -> Bool {
            comparisonCount += 1
            return false
        }

        let policy = MarkdownTextViewUpdatePolicy(
            isUserEditing: true,
            hasMarkedText: false,
            incomingTextEqualsCurrentText: compareIncomingText()
        )

        XCTAssertFalse(policy.shouldApplyIncomingText)
        XCTAssertEqual(comparisonCount, 0)
    }

    func testTextViewUpdateDoesNotCompareIncomingTextWhenMarkedTextAlreadySkips() {
        var comparisonCount = 0
        func compareIncomingText() -> Bool {
            comparisonCount += 1
            return false
        }

        let policy = MarkdownTextViewUpdatePolicy(
            isUserEditing: false,
            hasMarkedText: true,
            incomingTextEqualsCurrentText: compareIncomingText()
        )

        XCTAssertFalse(policy.shouldApplyIncomingText)
        XCTAssertEqual(comparisonCount, 0)
    }

    func testTextViewUpdateAppliesDifferentExternalTextWhenCompositionIsInactive() {
        let policy = MarkdownTextViewUpdatePolicy(
            isUserEditing: false,
            hasMarkedText: false,
            incomingTextEqualsCurrentText: false
        )

        XCTAssertTrue(policy.shouldApplyIncomingText)
    }

    func testEditorScrollLineIndexMapsUTF16OffsetsAndLines() {
        let index = EditorScrollLineIndex(text: "one\nemoji 🧪\nthree")

        XCTAssertEqual(index.oneBasedLine(containingUTF16Offset: 0), 1)
        XCTAssertEqual(index.oneBasedLine(containingUTF16Offset: 4), 2)
        XCTAssertEqual(index.oneBasedLine(containingUTF16Offset: 13), 3)
        XCTAssertEqual(index.utf16Offset(forOneBasedLine: 1), 0)
        XCTAssertEqual(index.utf16Offset(forOneBasedLine: 2), 4)
        XCTAssertEqual(index.utf16Offset(forOneBasedLine: 3), 13)
        XCTAssertEqual(index.utf16Offset(forOneBasedLine: 99), "one\nemoji 🧪\nthree".utf16.count)
    }
}
