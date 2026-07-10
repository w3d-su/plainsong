import AppKit
@testable import EditorKit
import STTextView
import XCTest

@MainActor
final class WYSIWYGLinkNativeGateTests: XCTestCase {
    func testL3AsymmetricDestinationSnapUsesCompleteLongHiddenRun() {
        let destination = NSRange(location: 20, length: 240)

        XCTAssertEqual(
            WYSIWYGCaretSnap.snap(
                offset: destination.location + 17,
                foldedDelimiterRanges: [destination],
                preferring: .backward
            ),
            destination.location
        )
        XCTAssertEqual(
            WYSIWYGCaretSnap.snap(
                offset: NSMaxRange(destination) - 17,
                foldedDelimiterRanges: [destination],
                preferring: .forward
            ),
            NSMaxRange(destination)
        )
        XCTAssertEqual(
            WYSIWYGCaretSnap.snap(
                offset: destination.location + 17,
                foldedDelimiterRanges: [destination],
                preferring: .nearest
            ),
            destination.location
        )
    }

    func testL3ArrowAcrossDestinationSnapsToVisibleBoundaryWithoutURLTrap() throws {
        let url = "https://example.com/this/is/a/long/destination/that/exceeds/the/old/window"
        let source = "Read [linked text](\(url)) after."
        let result = try applyLinkPresentation(source, selection: NSRange(location: 0, length: 0))
        let link = try result.presentation.onlyLinkRegion()
        let destination = try XCTUnwrap(link.foldRanges.last)

        result.textView.textSelection = NSRange(location: link.contentRange.upperBound, length: 0)
        result.textView.moveRight(nil)
        XCTAssertEqual(
            result.textView.selectedRange(),
            NSRange(location: link.sourceRange.upperBound, length: 0)
        )
        XCTAssertNil(result.textView.wysiwygFoldedDelimiterRange(
            containingInterior: result.textView.selectedRange().location
        ))

        let deepDestinationOffset = destination.location + destination.length / 2
        XCTAssertEqual(
            result.textView.wysiwygFoldedDelimiterRange(containingInterior: deepDestinationOffset),
            destination
        )
        result.textView.textSelection = NSRange(location: deepDestinationOffset, length: 0)
        result.textView.moveLeft(nil)
        XCTAssertEqual(
            result.textView.selectedRange(),
            NSRange(location: destination.location, length: 0)
        )
    }

    func testL3ShiftSelectionAcrossDestinationKeepsRawUTF16Offsets() throws {
        let source = "前 [連結](https://example.com/path) 後"
        let result = try applyLinkPresentation(source, selection: NSRange(location: 0, length: 0))
        let link = try result.presentation.onlyLinkRegion()
        let partialURLEnd = source.nsRange(of: "https://example.com").location + "https://exa".utf16.count
        let expectedSelection = NSRange(
            location: link.contentRange.upperBound,
            length: partialURLEnd - link.contentRange.upperBound
        )

        result.textView.textSelection = NSRange(location: expectedSelection.location, length: 0)
        for _ in 0 ..< expectedSelection.length {
            result.textView.moveRightAndModifySelection(nil)
        }

        XCTAssertEqual(result.textView.selectedRange(), expectedSelection)
        assertRawCopy(
            from: result.textView,
            source: source,
            range: expectedSelection,
            expected: "](https://exa"
        )
    }

    func testL4WholeTextAndPartialURLSelectionsCopyExactRawRanges() throws {
        let source = "Read [visible text](https://example.com/path) after."
        let result = try applyLinkPresentation(source, selection: NSRange(location: 0, length: 0))
        let link = try result.presentation.onlyLinkRegion()
        let partialURLEnd = source.nsRange(of: "https://example.com").location + "https://exam".utf16.count
        let partialRange = NSRange(
            location: link.contentRange.location,
            length: partialURLEnd - link.contentRange.location
        )

        assertRawCopy(
            from: result.textView,
            source: source,
            range: link.sourceRange,
            expected: "[visible text](https://example.com/path)"
        )
        assertRawCopy(
            from: result.textView,
            source: source,
            range: link.contentRange,
            expected: "visible text"
        )
        assertRawCopy(
            from: result.textView,
            source: source,
            range: partialRange,
            expected: "visible text](https://exam"
        )
    }

    func testL4PasteMutatesRawSourceInFoldedAndRevealedLinkRegions() throws {
        let source = "Read [link](https://example.com/path) after."
        let folded = try applyLinkPresentation(source, selection: NSRange(location: 0, length: 0))
        let foldedLink = try folded.presentation.onlyLinkRegion()
        let hiddenInsertion = foldedLink.foldRanges[1].location + "](https://".utf16.count
        folded.textView.textSelection = NSRange(location: hiddenInsertion, length: 0)

        let foldedPasteboard = uniquePasteboard()
        foldedPasteboard.setString("secure.", forType: .string)
        XCTAssertTrue(folded.textView.readSelection(from: foldedPasteboard, type: .string))
        XCTAssertEqual(
            text(in: folded.textView),
            (source as NSString).replacingCharacters(
                in: NSRange(location: hiddenInsertion, length: 0),
                with: "secure."
            )
        )

        let revealedRange = source.nsRange(of: "example")
        let revealed = try applyLinkPresentation(source, selection: revealedRange)
        revealed.textView.textSelection = revealedRange
        let revealedPasteboard = uniquePasteboard()
        revealedPasteboard.setString("changed", forType: .string)
        XCTAssertTrue(revealed.textView.readSelection(from: revealedPasteboard, type: .string))
        XCTAssertEqual(text(in: revealed.textView), "Read [link](https://changed.com/path) after.")
        XCTAssertFalse(text(in: revealed.textView).contains("\u{FFFC}"))
    }

    func testL7AccessibilityValueIncludesRawFoldedLinkDestination() throws {
        let source = "Read [accessible link](https://example.com/private/path) after."
        let result = try applyLinkPresentation(source, selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(result.textView.accessibilityRole(), .textArea)
        XCTAssertEqual(result.textView.accessibilityValue() as? String, source)
        XCTAssertFalse((result.textView.accessibilityValue() as? String)?.contains("\u{FFFC}") ?? true)
    }

    func testL7AccessibilitySelectedTextAcrossFoldedLinkReturnsExactRawMarkdown() throws {
        let source = "Before [visible link](https://example.com/private/path) after."
        let result = try applyLinkPresentation(source, selection: NSRange(location: 0, length: 0))
        let prefix = source.nsRange(of: "Before ")
        let suffix = source.nsRange(of: " after.")
        let selection = NSRange(
            location: prefix.location,
            length: NSMaxRange(suffix) - prefix.location
        )
        result.textView.textSelection = selection

        let selectedText = try XCTUnwrap(result.textView.accessibilitySelectedText())
        let expected = (source as NSString).substring(with: selection)
        XCTAssertEqual(Data(selectedText.utf8), Data(expected.utf8))
    }

    func testL9LinkPresentationStaysOutOfUndoAndRecomputesAfterURLUndoRedo() throws {
        let source = "Read [docs](https://example.com/path) after."
        let (textView, undoManager) = try makeUndoReadyLinkTextView(source: source)
        let (outsideSelection, urlEditRange) = try assertPresentationStaysOutOfUndo(
            source,
            textView: textView,
            undoManager: undoManager
        )

        textView.insertText("changed", replacementRange: urlEditRange)
        let editedSource = "Read [docs](https://changed.com/path) after."
        let editedSelection = textView.selectedRange()
        XCTAssertEqual(text(in: textView), editedSource)
        XCTAssertTrue(undoManager.canUndo)
        try applyLinkAndAssertFoldState(
            editedSource,
            selection: editedSelection,
            revision: 3,
            isFolded: false,
            to: textView
        )

        undoManager.undo()
        XCTAssertEqual(text(in: textView), source)
        try applyLinkAndAssertFoldState(
            source,
            selection: outsideSelection,
            revision: 4,
            isFolded: true,
            to: textView
        )
        XCTAssertTrue(undoManager.canRedo)

        undoManager.redo()
        XCTAssertEqual(text(in: textView), editedSource)
        let editedURLRange = editedSource.nsRange(of: "changed")
        try applyLinkAndAssertFoldState(
            editedSource,
            selection: editedURLRange,
            revision: 5,
            isFolded: false,
            to: textView
        )
    }
}

@MainActor
private extension WYSIWYGLinkNativeGateTests {
    func assertPresentationStaysOutOfUndo(
        _ source: String,
        textView: MarkdownSTTextView,
        undoManager: UndoManager
    ) throws -> (outsideSelection: NSRange, urlEditRange: NSRange) {
        let outsideSelection = NSRange(location: 0, length: 0)
        try applyLinkAndAssertFoldState(
            source,
            selection: outsideSelection,
            revision: 1,
            isFolded: true,
            to: textView
        )
        XCTAssertFalse(undoManager.canUndo)

        let urlEditRange = source.nsRange(of: "example")
        try applyLinkAndAssertFoldState(
            source,
            selection: urlEditRange,
            revision: 2,
            isFolded: false,
            to: textView
        )
        XCTAssertFalse(undoManager.canUndo)
        return (outsideSelection, urlEditRange)
    }

    func makeUndoReadyLinkTextView(source: String) throws -> (MarkdownSTTextView, UndoManager) {
        let textView = MarkdownSTTextView(frame: .zero)
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        textView.text = source
        XCTAssertTrue(textView.setWYSIWYGZeroWidthFoldingEnabled(true))
        let undoManager = try XCTUnwrap(textView.undoManager)
        undoManager.removeAllActions()
        return (textView, undoManager)
    }

    func applyLinkAndAssertFoldState(
        _ source: String,
        selection: NSRange,
        revision: Int,
        isFolded: Bool,
        to textView: MarkdownSTTextView
    ) throws {
        textView.textSelection = selection
        XCTAssertTrue(applyLinkPresentation(
            source,
            selection: selection,
            revision: revision,
            to: textView
        ))
        let link = try linkPresentation(source, selection: selection).onlyLinkRegion()
        assertFoldState(in: textView, ranges: link.foldRanges, isFolded: isFolded)
    }

    func assertRawCopy(
        from textView: STTextView,
        source: String,
        range: NSRange,
        expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        textView.textSelection = range
        let pasteboard = uniquePasteboard()
        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: [.string]), file: file, line: line)
        XCTAssertEqual(pasteboard.string(forType: .string), expected, file: file, line: line)
        XCTAssertEqual((source as NSString).substring(with: range), expected, file: file, line: line)
    }

    func assertFoldState(
        in textView: STTextView,
        ranges: [NSRange],
        isFolded: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let textStorage = MarkdownTextView.textStorage(of: textView) else {
            XCTFail("Expected text storage", file: file, line: line)
            return
        }
        for range in ranges {
            textStorage.enumerateAttribute(
                WYSIWYGInlineFoldPresentation.foldedDelimiterAttribute,
                in: range
            ) { value, _, _ in
                XCTAssertEqual(value as? Bool == true, isFolded, file: file, line: line)
            }
        }
    }

    func uniquePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PlainsongLinkNativeGate.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    func text(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }
}

private extension MarkdownHighlightResult {
    func onlyLinkRegion() throws -> WYSIWYGFoldRegion {
        try XCTUnwrap(foldPlan).onlyLinkRegion()
    }
}

private extension HighlightedText {
    func onlyLinkRegion() throws -> WYSIWYGFoldRegion {
        try XCTUnwrap(foldPlan).onlyLinkRegion()
    }
}

private extension WYSIWYGFoldPlan {
    func onlyLinkRegion() throws -> WYSIWYGFoldRegion {
        let links = regions.filter { $0.kind == .link }
        XCTAssertEqual(links.count, 1)
        return try XCTUnwrap(links.first)
    }
}

private extension NSRange {
    var upperBound: Int {
        NSMaxRange(self)
    }
}

private extension String {
    func nsRange(of substring: String) -> NSRange {
        let range = (self as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected to find '\(substring)'")
        return range
    }
}
