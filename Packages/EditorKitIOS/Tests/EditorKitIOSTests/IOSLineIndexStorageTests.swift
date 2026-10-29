@testable import EditorKitIOS
import MarkdownCore
import UIKit
import XCTest

/// The line index follows every storage edit path, not only `shouldChangeTextIn`.
/// Each step compares the incremental index with a full rebuild of the same text.
@MainActor
final class IOSLineIndexStorageTests: XCTestCase {
    func testRandomEditsMarkedTextAndUndoMatchAFullRebuild() {
        let harness = IOSEditorHarness(text: "one\ntwo\n三\n")
        var random = SeededGenerator(seed: 0x5EED_2280)
        let pieces = ["a", "\n", "中文", "\n\n", "😀", "- [ ] x\n", "", "ㄓㄨ"]
        for step in 0 ..< 300 {
            let length = harness.textView.textStorage.length
            let location = Int.random(in: 0 ... length, using: &random)
            let span = Int.random(in: 0 ... min(6, length - location), using: &random)
            let range = safeRange(NSRange(location: location, length: span), in: harness)
            let piece = pieces.randomElement(using: &random) ?? ""
            switch step % 6 {
            case 0:
                harness.textView.selectedRange = range
                harness.textView.insertText(piece)
            case 1:
                harness.textView.selectedRange = range
                harness.textView.deleteBackward()
            case 2:
                // Composition: several marked updates, then commit.
                harness.textView.selectedRange = NSRange(location: range.location, length: 0)
                harness.textView.setMarkedText("ㄓ", selectedRange: NSRange(location: 1, length: 0))
                assertIndex(harness, step: step)
                harness.textView.setMarkedText("ㄓㄨ\n", selectedRange: NSRange(location: 3, length: 0))
                assertIndex(harness, step: step)
                harness.textView.unmarkText()
            case 3:
                harness.textView.undoManager?.undo()
            case 4:
                // A path that never reaches shouldChangeTextIn (autocorrect, system replace).
                harness.textView.textStorage.replaceCharacters(in: range, with: piece)
                // UIKit registered no undo for this edit; older groups no longer address it.
                harness.textView.undoManager?.removeAllActions()
            default:
                if let start = harness.textView.position(
                    from: harness.textView.beginningOfDocument, offset: range.location
                ), let end = harness.textView.position(from: start, offset: range.length),
                let textRange = harness.textView.textRange(from: start, to: end) {
                    harness.textView.replace(textRange, withText: piece)
                }
            }
            assertIndex(harness, step: step)
        }
    }

    func testAuthorizedEditUpdatesTheIndexOnce() throws {
        let harness = IOSEditorHarness(text: "a\nb\nc")
        let edit = try harness.edit(MarkdownEditResult(
            replacementRange: NSRange(location: 2, length: 1),
            replacementString: "x\ny",
            newSelection: NSRange(location: 5, length: 0)
        ))
        _ = harness.controller.apply(edit)
        XCTAssertEqual(harness.textView.textStorage.string, "a\nx\ny\nc")
        assertIndex(harness, step: 0)
        XCTAssertEqual(harness.controller.lineIndex.lineCount, 4)
    }

    private func safeRange(_ range: NSRange, in harness: IOSEditorHarness) -> NSRange {
        // Keep surrogate pairs whole so UIKit does not adjust the range under the test.
        let source = harness.textView.textStorage.string as NSString
        guard source.length > 0 else { return NSRange(location: 0, length: 0) }
        let start = source.rangeOfComposedCharacterSequence(at: min(range.location, source.length - 1))
        let location = range.location >= source.length ? source.length : start.location
        let end = min(location + range.length, source.length)
        guard end > location else { return NSRange(location: location, length: 0) }
        let last = source.rangeOfComposedCharacterSequence(at: end - 1)
        return NSRange(location: location, length: NSMaxRange(last) - location)
    }

    private func assertIndex(_ harness: IOSEditorHarness, step: Int, line: UInt = #line) {
        let text = harness.textView.textStorage.string
        XCTAssertEqual(harness.controller.lineIndex, IOSSourceLineIndex(text: text), "step \(step)", line: line)
    }
}

@MainActor
final class IOSScrollToLineInsetTests: XCTestCase {
    func testScrollTargetIncludesTheContainerAndBarInsets() {
        let inset = UIEdgeInsets(top: 100, left: 0, bottom: 20, right: 0)
        XCTAssertEqual(
            IOSSourceEditorController.scrollTarget(
                fragmentY: 0, containerInsetTop: 8, adjustedInset: inset, contentHeight: 2000, boundsHeight: 700
            ),
            -100
        )
        XCTAssertEqual(
            IOSSourceEditorController.scrollTarget(
                fragmentY: 400, containerInsetTop: 8, adjustedInset: inset, contentHeight: 2000, boundsHeight: 700
            ),
            308
        )
        XCTAssertEqual(
            IOSSourceEditorController.scrollTarget(
                fragmentY: 1900, containerInsetTop: 8, adjustedInset: inset, contentHeight: 2000, boundsHeight: 700
            ),
            1320
        )
    }

    func testScrolledLineSitsAtTheTopOfTheVisibleArea() throws {
        let lines = (1 ... 120).map { "line \($0)" }.joined(separator: "\n")
        let harness = IOSEditorHarness(text: lines)
        harness.textView.contentInset.top = 60
        harness.textView.layoutIfNeeded()

        let early = try XCTUnwrap(
            harness.textView.contentY(
                forUTF16Offset: harness.controller.lineIndex.utf16Offset(forOneBasedLine: 2)
            )
        )
        let late = try XCTUnwrap(
            harness.textView.contentY(
                forUTF16Offset: harness.controller.lineIndex.utf16Offset(forOneBasedLine: 100)
            )
        )
        XCTAssertGreaterThan(
            late,
            early,
            "a later line is below an earlier one without laying out the prefix as the requested range"
        )

        harness.controller.scrollToSourceLine(1)
        XCTAssertEqual(harness.textView.contentOffset.y, -harness.textView.adjustedContentInset.top, accuracy: 0.5)

        harness.controller.scrollToSourceLine(40)
        let offset = harness.controller.lineIndex.utf16Offset(forOneBasedLine: 40)
        let fragmentY = try XCTUnwrap(harness.textView.contentY(forUTF16Offset: offset))
        let visibleTop = harness.textView.contentOffset.y + harness.textView.adjustedContentInset.top
        XCTAssertEqual(fragmentY + harness.textView.textContainerInset.top, visibleTop, accuracy: 0.5)
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
