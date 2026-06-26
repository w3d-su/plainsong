import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// Delimiter edge-snapping for the non-user-facing `_developmentPresentation:
/// .inlineFoldReveal` hook (release checklist §C.2). A *collapsed* caret that would rest
/// strictly inside a folded (zero-width) delimiter snaps to the delimiter-inner boundary
/// instead of relying on the next-pass reveal. Selections are never clamped — they may
/// still span raw delimiter offsets so copy stays exact raw Markdown (§C.3/§C.4).
@MainActor
final class WYSIWYGEdgeSnappingGateTests: XCTestCase {
    // MARK: - Pure snapping function

    func testSnapForwardFromDelimiterInteriorReturnsTrailingEdge() {
        let folded = [NSRange(location: 2, length: 2)] // e.g. opening `**`
        XCTAssertEqual(
            WYSIWYGCaretSnap.snap(offset: 3, foldedDelimiterRanges: folded, preferring: .forward),
            4
        )
    }

    func testSnapBackwardFromDelimiterInteriorReturnsLeadingEdge() {
        let folded = [NSRange(location: 8, length: 2)] // e.g. closing `**`
        XCTAssertEqual(
            WYSIWYGCaretSnap.snap(offset: 9, foldedDelimiterRanges: folded, preferring: .backward),
            8
        )
    }

    func testSnapNearestFromDelimiterInteriorReturnsNearerEdge() {
        let folded = [NSRange(location: 10, length: 3)] // 3-wide run, [10, 13)
        // Closer to the leading edge.
        XCTAssertEqual(
            WYSIWYGCaretSnap.snap(offset: 11, foldedDelimiterRanges: folded, preferring: .nearest),
            10
        )
        // Closer to the trailing edge.
        XCTAssertEqual(
            WYSIWYGCaretSnap.snap(offset: 12, foldedDelimiterRanges: folded, preferring: .nearest),
            13
        )
    }

    func testSnapNearestBreaksEvenInteriorTieTowardLeadingEdge() {
        let folded = [NSRange(location: 2, length: 2)] // [2, 4): only interior offset is 3
        XCTAssertEqual(
            WYSIWYGCaretSnap.snap(offset: 3, foldedDelimiterRanges: folded, preferring: .nearest),
            2
        )
    }

    func testSnapLeavesRunEdgesAndOutsideOffsetsUnchanged() {
        let folded = [NSRange(location: 2, length: 2)]
        for direction in [WYSIWYGCaretSnap.Direction.forward, .backward, .nearest] {
            // Leading edge, trailing edge, and an offset far outside are all untouched.
            XCTAssertEqual(WYSIWYGCaretSnap.snap(offset: 2, foldedDelimiterRanges: folded, preferring: direction), 2)
            XCTAssertEqual(WYSIWYGCaretSnap.snap(offset: 4, foldedDelimiterRanges: folded, preferring: direction), 4)
            XCTAssertEqual(WYSIWYGCaretSnap.snap(offset: 7, foldedDelimiterRanges: folded, preferring: direction), 7)
        }
    }

    func testSnapLeavesSingleCharacterDelimiterUnchanged() {
        // A single-backtick code delimiter has no interior offset, so nothing snaps.
        let folded = [NSRange(location: 2, length: 1)]
        for direction in [WYSIWYGCaretSnap.Direction.forward, .backward, .nearest] {
            XCTAssertEqual(WYSIWYGCaretSnap.snap(offset: 2, foldedDelimiterRanges: folded, preferring: direction), 2)
            XCTAssertEqual(WYSIWYGCaretSnap.snap(offset: 3, foldedDelimiterRanges: folded, preferring: direction), 3)
        }
    }

    // MARK: - Keyboard arrow snapping near folded delimiters

    func testArrowRightIntoFoldedBoldOpeningDelimiterSnapsToContentStart() {
        assertArrowSnap(
            source: "A **bold** done",
            span: "**bold**",
            content: "bold",
            edge: .opening
        )
    }

    func testArrowLeftIntoFoldedBoldClosingDelimiterSnapsToContentEnd() {
        assertArrowSnap(
            source: "A **bold** done",
            span: "**bold**",
            content: "bold",
            edge: .closing
        )
    }

    func testArrowIntoFoldedStrikeOpeningDelimiterSnapsToContentStart() {
        assertArrowSnap(
            source: "A ~~gone~~ done",
            span: "~~gone~~",
            content: "gone",
            edge: .opening
        )
    }

    func testArrowIntoFoldedStrikeClosingDelimiterSnapsToContentEnd() {
        assertArrowSnap(
            source: "A ~~gone~~ done",
            span: "~~gone~~",
            content: "gone",
            edge: .closing
        )
    }

    func testArrowRightIntoFoldedHeadingMarkerSnapsToContentStart() {
        // The heading marker is folded only while the caret sits off the heading line.
        let source = "# Heading\n\nbody text"
        let textView = makeWYSIWYGTextView(source: source)
        let bodyRange = source.nsRange(of: "body")
        XCTAssertTrue(applyProductionPresentation(
            source,
            selection: NSRange(location: bodyRange.location, length: 0),
            revision: 1,
            to: textView
        ))

        let markerRange = source.nsRange(of: "# ")
        let contentRange = source.nsRange(of: "Heading")
        // Park the caret at the line start with the `# ` marker still folded.
        textView.textSelection = NSRange(location: markerRange.location, length: 0)
        textView.moveRight(nil)

        // Native movement would stop at offset 1 (inside the folded `# ` marker);
        // edge-snapping moves it to the content start.
        XCTAssertEqual(textView.selectedRange(), NSRange(location: contentRange.location, length: 0))
        assertCaretNotInsideFoldedDelimiter(textView)
    }

    func testArrowAcrossFoldedInlineCodeSingleBacktickPlacesCaretAtContentWithoutTrap() {
        // Single-backtick code delimiters have no interior offset: the caret already lands
        // on a visible boundary, so snapping is a no-op and the caret is never trapped.
        let source = "A `code` done"
        let codeSpan = source.nsRange(of: "`code`")
        let codeContent = source.nsRange(of: "code")

        let forward = makeWYSIWYGTextView(source: source)
        XCTAssertTrue(applyProductionPresentation(
            source,
            selection: NSRange(location: 0, length: 0),
            revision: 1,
            to: forward
        ))
        forward.textSelection = NSRange(location: codeSpan.location, length: 0)
        forward.moveRight(nil)
        XCTAssertEqual(forward.selectedRange(), NSRange(location: codeContent.location, length: 0))
        assertCaretNotInsideFoldedDelimiter(forward)

        let backward = makeWYSIWYGTextView(source: source)
        XCTAssertTrue(applyProductionPresentation(
            source,
            selection: NSRange(location: NSMaxRange(codeSpan), length: 0),
            revision: 1,
            to: backward
        ))
        backward.textSelection = NSRange(location: NSMaxRange(codeSpan), length: 0)
        backward.moveLeft(nil)
        XCTAssertEqual(backward.selectedRange(), NSRange(location: NSMaxRange(codeContent), length: 0))
        assertCaretNotInsideFoldedDelimiter(backward)
    }

    // MARK: - Pointer snapping near folded delimiters

    func testFoldedDelimiterInteriorLookupReadsLiveFoldAttributes() {
        let source = "A **bold** done"
        let textView = makeWYSIWYGTextView(source: source)
        XCTAssertTrue(applyProductionPresentation(
            source,
            selection: NSRange(location: 0, length: 0),
            revision: 1,
            to: textView
        ))

        let opening = source.nsRange(of: "**bold**", selecting: "**")
        let closing = source.nsRange(of: "**bold**", selectingLast: "**")

        // Interior offsets resolve to the folded run; edges and content do not.
        XCTAssertEqual(textView.wysiwygFoldedDelimiterRange(containingInterior: opening.location + 1), opening)
        XCTAssertEqual(textView.wysiwygFoldedDelimiterRange(containingInterior: closing.location + 1), closing)
        XCTAssertNil(textView.wysiwygFoldedDelimiterRange(containingInterior: opening.location))
        XCTAssertNil(textView.wysiwygFoldedDelimiterRange(containingInterior: NSMaxRange(opening)))
        XCTAssertNil(textView.wysiwygFoldedDelimiterRange(containingInterior: source.nsRange(of: "bold").location + 1))
    }

    func testPointerCaretSnapResolvesHiddenDelimiterOffsetToVisibleBoundary() {
        let source = "A **bold** done"
        let textView = makeWYSIWYGTextView(source: source)
        XCTAssertTrue(applyProductionPresentation(
            source,
            selection: NSRange(location: 0, length: 0),
            revision: 1,
            to: textView
        ))

        let opening = source.nsRange(of: "**bold**", selecting: "**")
        let closing = source.nsRange(of: "**bold**", selectingLast: "**")

        // A pointer hit-test that resolved into a hidden delimiter snaps to a visible edge
        // (the mouseDown path uses `.nearest`).
        for interiorOffset in [opening.location + 1, closing.location + 1] {
            let snapped = textView.wysiwygSnappedCaretOffset(interiorOffset, preferring: .nearest)
            XCTAssertNil(
                textView.wysiwygFoldedDelimiterRange(containingInterior: snapped),
                "Snapped caret \(snapped) must not be inside a folded delimiter"
            )
        }

        // Content and edge offsets are returned unchanged.
        let content = source.nsRange(of: "bold")
        XCTAssertEqual(textView.wysiwygSnappedCaretOffset(content.location, preferring: .nearest), content.location)
        XCTAssertEqual(textView.wysiwygSnappedCaretOffset(opening.location, preferring: .nearest), opening.location)
    }

    func testRealPointerClicksAtFoldedDelimiterEdgesLandOnVisibleBoundary() throws {
        let source = "A **bold** mid ~~gone~~ and `code` end"
        let cases = ["bold", "gone", "code"]

        for content in cases {
            let contentRange = source.nsRange(of: content)
            let firstChar = NSRange(location: contentRange.location, length: 1)
            let lastChar = NSRange(location: NSMaxRange(contentRange) - 1, length: 1)

            for (charRange, fraction) in [(firstChar, 0.05), (lastChar, 0.95)] {
                let fixture = try makeWindowedEditor(source: source)
                XCTAssertTrue(applyProductionPresentation(
                    source,
                    selection: NSRange(location: 0, length: 0),
                    revision: 1,
                    to: fixture.textView
                ))

                let caret = try pointerClick(onCharacterRange: charRange, in: fixture, fraction: fraction)
                // The integrated mouseDown snap keeps the caret on a visible boundary, and
                // the touched span reveals on the next presentation pass.
                XCTAssertNil(
                    fixture.textView.wysiwygFoldedDelimiterRange(containingInterior: caret),
                    "Pointer caret \(caret) for '\(content)' must not rest inside a folded delimiter"
                )
            }
        }
    }

    // MARK: - Selection and copy stay raw (snapping must not clamp selections)

    func testShiftSelectionAcrossFoldedDelimitersStillCopiesExactRawMarkdown() {
        let source = "A **bold** and `code` done"
        let textView = makeWYSIWYGTextView(source: source)
        XCTAssertTrue(applyProductionPresentation(
            source,
            selection: NSRange(location: 0, length: 0),
            revision: 1,
            to: textView
        ))

        let boldRange = source.nsRange(of: "**bold**")
        textView.textSelection = NSRange(location: boldRange.location, length: 0)
        for _ in 0 ..< boldRange.length {
            textView.moveRightAndModifySelection(nil)
        }

        // Edge-snapping never clamps a selection: it spans the raw delimiter offsets and
        // copy is exact raw Markdown.
        XCTAssertEqual(textView.selectedRange(), boldRange)
        let pasteboard = uniquePasteboard()
        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: [.string]))
        XCTAssertEqual(pasteboard.string(forType: .string), "**bold**")
    }

    // MARK: - Composed-character movement stays valid with snapping enabled

    func testComposedCharacterMovementStaysValidWithSnappingEnabled() {
        let source = "😀漢 **強** tail"
        let textView = makeWYSIWYGTextView(source: source)
        XCTAssertTrue(applyProductionPresentation(
            source,
            selection: NSRange(location: 0, length: 0),
            revision: 1,
            to: textView
        ))

        let emoji = source.nsRange(of: "😀")
        let cjk = source.nsRange(of: "漢")
        let boldSpan = source.nsRange(of: "**強**")
        let boldContent = source.nsRange(of: "強")

        // Step across the surrogate-pair emoji and the CJK ideograph: each endpoint stays
        // on a composed-character boundary.
        textView.textSelection = NSRange(location: emoji.location, length: 0)
        textView.moveRight(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: NSMaxRange(emoji), length: 0))
        assertComposedBoundary(textView.selectedRange().location, in: source)

        textView.moveRight(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: NSMaxRange(cjk), length: 0))
        assertComposedBoundary(textView.selectedRange().location, in: source)

        // Stepping into the folded bold span snaps to the content boundary while staying on
        // a composed-character boundary.
        textView.textSelection = NSRange(location: boldSpan.location, length: 0)
        textView.moveRight(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: boldContent.location, length: 0))
        assertComposedBoundary(textView.selectedRange().location, in: source)
        assertCaretNotInsideFoldedDelimiter(textView)
    }
}

// MARK: - Helpers

@MainActor
private extension WYSIWYGEdgeSnappingGateTests {
    enum DelimiterEdge {
        case opening
        case closing
    }

    /// Folds `span`, parks the caret at the span boundary nearest `edge` while that
    /// delimiter is still folded, drives a single arrow toward the content, and asserts
    /// the caret snaps to the delimiter-inner (content) boundary.
    func assertArrowSnap(
        source: String,
        span: String,
        content: String,
        edge: DelimiterEdge,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let textView = makeWYSIWYGTextView(source: source)
        let spanRange = source.nsRange(of: span)
        let contentRange = source.nsRange(of: content)

        // Fold the whole span by placing the fold-plan selection just before it (a caret
        // touching the span would reveal it).
        let outsideSelection = NSRange(location: max(0, spanRange.location - 1), length: 0)
        XCTAssertTrue(
            applyProductionPresentation(source, selection: outsideSelection, revision: 1, to: textView),
            file: file,
            line: line
        )

        switch edge {
        case .opening:
            textView.textSelection = NSRange(location: spanRange.location, length: 0)
            textView.moveRight(nil)
            XCTAssertEqual(
                textView.selectedRange(),
                NSRange(location: contentRange.location, length: 0),
                file: file,
                line: line
            )
        case .closing:
            textView.textSelection = NSRange(location: NSMaxRange(spanRange), length: 0)
            textView.moveLeft(nil)
            XCTAssertEqual(
                textView.selectedRange(),
                NSRange(location: NSMaxRange(contentRange), length: 0),
                file: file,
                line: line
            )
        }

        assertCaretNotInsideFoldedDelimiter(textView, file: file, line: line)
    }

    func assertCaretNotInsideFoldedDelimiter(
        _ textView: MarkdownSTTextView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(
            textView.wysiwygFoldedDelimiterRange(containingInterior: textView.selectedRange().location),
            "Caret \(textView.selectedRange().location) rests inside a folded delimiter",
            file: file,
            line: line
        )
    }

    func assertComposedBoundary(
        _ offset: Int,
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let text = source as NSString
        let onBoundary: Bool = if offset <= 0 || offset >= text.length {
            true
        } else {
            NSMaxRange(text.rangeOfComposedCharacterSequence(at: offset - 1)) == offset
        }
        XCTAssertTrue(onBoundary, "Offset \(offset) is inside a composed character", file: file, line: line)
    }

    func productionPresentation(_ source: String, selection: NSRange, revision: Int) -> HighlightedText {
        let highlighted = MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (source as NSString).length),
            developmentPresentation: .inlineFoldReveal,
            selection: selection
        )
        return HighlightedText(
            revision: revision,
            range: highlighted.range,
            text: highlighted.text,
            foldPlan: highlighted.foldPlan
        )
    }

    @discardableResult
    func applyProductionPresentation(
        _ source: String,
        selection: NSRange,
        revision: Int,
        to textView: STTextView
    ) -> Bool {
        MarkdownTextView.applyHighlightedText(
            productionPresentation(source, selection: selection, revision: revision),
            to: textView
        )
    }

    func makeWYSIWYGTextView(source: String) -> MarkdownSTTextView {
        let textView = MarkdownSTTextView(frame: .zero)
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        textView.text = source
        textView.setWYSIWYGZeroWidthFoldingEnabled(true)
        return textView
    }

    func uniquePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PlainsongEdgeSnap.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }
}

// MARK: - Windowed pointer helpers

@MainActor
private extension WYSIWYGEdgeSnappingGateTests {
    struct WindowedEditor {
        let window: NSWindow
        let textView: MarkdownSTTextView
    }

    func makeWindowedEditor(source: String) throws -> WindowedEditor {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.isEditable = true
        textView.isSelectable = true
        textView.showsLineNumbers = false
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        textView.text = source
        textView.setWYSIWYGZeroWidthFoldingEnabled(true)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)

        textView.layoutSubtreeIfNeeded()
        textView.textLayoutManager.ensureLayout(for: textView.textLayoutManager.documentRange)
        return WindowedEditor(window: window, textView: textView)
    }

    func pointerClick(
        onCharacterRange characterRange: NSRange,
        in fixture: WindowedEditor,
        fraction: CGFloat = 0.5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Int {
        let screenRect = fixture.textView.firstRect(forCharacterRange: characterRange, actualRange: nil)
        XCTAssertGreaterThan(screenRect.width, 0, file: file, line: line)
        XCTAssertGreaterThan(screenRect.height, 0, file: file, line: line)

        let screenPoint = CGPoint(x: screenRect.minX + screenRect.width * fraction, y: screenRect.midY)
        let windowPoint = fixture.window.convertPoint(fromScreen: screenPoint)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), file: file, line: line)

        fixture.textView.mouseDown(with: event)
        return fixture.textView.selectedRange().location
    }
}

private extension String {
    func nsRange(of substring: String) -> NSRange {
        let range = (self as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected substring '\(substring)' in '\(self)'")
        return range
    }

    func nsRange(of containingSubstring: String, selecting selectedSubstring: String) -> NSRange {
        let containerRange = nsRange(of: containingSubstring)
        let container = (self as NSString).substring(with: containerRange) as NSString
        let selectedRange = container.range(of: selectedSubstring)
        XCTAssertNotEqual(selectedRange.location, NSNotFound)
        return NSRange(location: containerRange.location + selectedRange.location, length: selectedRange.length)
    }

    func nsRange(of containingSubstring: String, selectingLast selectedSubstring: String) -> NSRange {
        let containerRange = nsRange(of: containingSubstring)
        let container = (self as NSString).substring(with: containerRange) as NSString
        let selectedRange = container.range(of: selectedSubstring, options: .backwards)
        XCTAssertNotEqual(selectedRange.location, NSNotFound)
        return NSRange(location: containerRange.location + selectedRange.location, length: selectedRange.length)
    }
}
