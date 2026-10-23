import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// `EditorTextElementCacheTrimmer` (#180/#197) postdates the WYSIWYG gates. Its
/// attribute-only edit notification makes `NSTextContentStorage` drop cached paragraph
/// elements, and the zero-width projection supplies every WYSIWYG paragraph element. These
/// tests prove a trim under the shipped link-folding presentation leaves the backing text,
/// fold attributes, selection, scroll position and Undo untouched, and that the dropped
/// paragraphs come back through the projection still folded.
@MainActor
final class WYSIWYGElementCacheTrimGateTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows.removeAll()
        super.tearDown()
    }

    func testTrimUnderFoldPresentationKeepsStorageSelectionScrollAndUndo() throws {
        let fixture = try makeFoldedEditor()
        let textView = fixture.textView
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: textView))
        jumpToEndAndBack(fixture)
        let before = try XCTUnwrap(storage.copy() as? NSAttributedString)
        let selection = textView.selectedRange()
        let origin = fixture.scrollView.contentView.bounds.origin
        let canUndo = textView.undoManager?.canUndo

        let trimmed = try trimAll(in: textView)
        textView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(trimmed.length, 0)
        XCTAssertTrue(storage.isEqual(to: before), "A trim must not change text or fold attributes")
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertEqual(fixture.scrollView.contentView.bounds.origin, origin)
        XCTAssertEqual(textView.undoManager?.canUndo, canUndo)
    }

    func testTrimmedParagraphsReturnThroughTheProjectionStillFolded() throws {
        let fixture = try makeFoldedEditor()
        let textView = fixture.textView
        let textContentStorage = try XCTUnwrap(textView.textContentManager as? NSTextContentStorage)
        let projection = try XCTUnwrap(textView.wysiwygZeroWidthContentStorageDelegate)
        let recorder = ParagraphRequestRecorder(forwardingTo: projection)
        textContentStorage.delegate = recorder

        jumpToEndAndBack(fixture)
        // The farthest paragraph the jump laid out; TextKit's height estimate can stop the
        // scroll short of the last one.
        let target = try XCTUnwrap(recorder.requestedRanges.max { $0.location < $1.location })
        let textRange = try XCTUnwrap(NSTextRange(target, in: textView.textContentManager))
        recorder.requestedRanges.removeAll()
        textView.textLayoutManager.ensureLayout(for: textRange)
        XCTAssertFalse(
            recorder.requestedRanges.contains { NSLocationInRange(target.location, $0) },
            "Control: a cached paragraph is laid out again without a new projection"
        )

        let trimmed = try trimAll(in: textView)
        XCTAssertTrue(NSLocationInRange(target.location, trimmed))
        recorder.requestedRanges.removeAll()
        textView.textLayoutManager.ensureLayout(for: textRange)

        XCTAssertTrue(
            recorder.requestedRanges.contains { NSLocationInRange(target.location, $0) },
            "A trimmed paragraph must be rebuilt by the zero-width projection"
        )
        let bold = fixture.source.range(of: "**bold**", options: [], range: target)
        let destination = fixture.source.range(of: "](https://", options: [], range: target)
        let closing = fixture.source.range(
            of: ")",
            options: [],
            range: NSRange(location: destination.location, length: NSMaxRange(target) - destination.location)
        )
        let hiddenRuns = [
            NSRange(location: bold.location, length: 2),
            NSRange(location: NSMaxRange(bold) - 2, length: 2),
            NSRange(location: destination.location, length: NSMaxRange(closing) - destination.location),
        ]
        for hiddenRun in hiddenRuns {
            XCTAssertLessThanOrEqual(
                try advance(of: hiddenRun, in: textView),
                0.5,
                "Expected \(fixture.source.substring(with: hiddenRun)) to stay folded after the trim"
            )
        }
        XCTAssertGreaterThan(try advance(of: NSRange(location: bold.location + 2, length: 4), in: textView), 1)
        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.string, fixture.source as String)
    }
}

private extension WYSIWYGElementCacheTrimGateTests {
    struct FoldedEditor {
        let source: NSString
        let scrollView: NSScrollView
        let textView: MarkdownSTTextView
    }

    /// Forwards to the production projection and records which paragraphs TextKit rebuilt.
    final class ParagraphRequestRecorder: NSObject, NSTextContentStorageDelegate {
        let projection: WYSIWYGZeroWidthTextContentStorageDelegate
        var requestedRanges: [NSRange] = []

        init(forwardingTo projection: WYSIWYGZeroWidthTextContentStorageDelegate) {
            self.projection = projection
        }

        func textContentStorage(
            _ textContentStorage: NSTextContentStorage,
            textParagraphWith range: NSRange
        ) -> NSTextParagraph? {
            requestedRanges.append(range)
            return projection.textContentStorage(textContentStorage, textParagraphWith: range)
        }
    }

    /// About 100 K UTF-16 units: enough past one viewport for `minimumTrimLength`.
    func makeFoldedEditor() throws -> FoldedEditor {
        let source = (1 ... 1500)
            .map { "Paragraph \($0) with **bold** and [a link](https://example.com/\($0)) 中文.\n" }
            .joined() as NSString
        let frame = NSRect(x: 0, y: 0, width: 700, height: 800)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.isEditable = true
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.orderFront(nil)
        windows.append(window)
        textView.text = source as String
        textView.setWYSIWYGZeroWidthFoldingEnabled(true)

        let highlighted = MarkdownSyntaxHighlighter().highlight(
            source as String,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: source.length),
            developmentPresentation: .inlineFoldRevealWithLinkFolding,
            selection: NSRange(location: 0, length: 0)
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
        textView.undoManager?.removeAllActions()
        textView.layoutSubtreeIfNeeded()
        return FoldedEditor(source: source, scrollView: scrollView, textView: textView)
    }

    /// Lays out the document end so TextKit caches its paragraph elements, then returns the
    /// viewport to the middle (`EditorTextElementCacheTrimmerTests` uses the same walk).
    func jumpToEndAndBack(_ fixture: FoldedEditor) {
        fixture.textView.scrollRangeToVisible(NSRange(location: fixture.source.length, length: 0))
        fixture.textView.layoutSubtreeIfNeeded()
        let middle = fixture.source.length / 2
        fixture.textView.textSelection = NSRange(location: middle, length: 0)
        fixture.textView.scrollRangeToVisible(NSRange(location: middle, length: 0))
        fixture.textView.layoutSubtreeIfNeeded()
    }

    /// Releases everything below the current viewport, as the settled trimmer would, and
    /// returns the released range.
    func trimAll(in textView: STTextView) throws -> NSRange {
        let visible = try XCTUnwrap(MarkdownTextView.visibleTextRange(of: textView))
        let length = MarkdownTextView.textStorage(of: textView)?.length ?? 0
        var end = length
        while let chunk = EditorTextElementCacheTrimmer.nextChunk(below: visible, endingAt: end, in: textView) {
            XCTAssertTrue(EditorTextElementCacheTrimmer.trim(chunk, in: textView))
            end = chunk.location
        }
        return NSRange(location: end, length: length - end)
    }

    func advance(of range: NSRange, in textView: STTextView) throws -> CGFloat {
        let textRange = try XCTUnwrap(NSTextRange(range, in: textView.textContentManager))
        let fragment = try XCTUnwrap(textView.textLayoutManager.textLayoutFragment(for: textRange.location))
        let elementStart = NSRange(fragment.rangeInElement, in: textView.textContentManager).location
        let local = range.location - elementStart
        let line = try XCTUnwrap(fragment.textLineFragments.first {
            NSLocationInRange(local, $0.characterRange)
        })
        let start = line.locationForCharacter(at: local)
        let end = line.locationForCharacter(at: local + range.length)
        return abs(end.x - start.x)
    }
}
