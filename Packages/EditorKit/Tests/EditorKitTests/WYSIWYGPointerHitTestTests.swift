import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// A WYSIWYG click maps its point against the laid-out viewport only, or, when the viewport is
/// stale, against a band of lines laid out around the point: the work must not depend on the
/// document's length, text away from the point stays without layout, the click runs no view
/// layout, and an unmapped point gets no caret rather than a wrong line.
@MainActor
final class WYSIWYGPointerHitTestTests: XCTestCase {
    func testClickWorkDoesNotGrowWithTheDocument() throws {
        let short = try clickCost(lineCount: 1500)
        let long = try clickCost(lineCount: 60000)

        // The hit-test visits the TextKit viewport only: the same fragments for both documents.
        XCTAssertEqual(long.visits, short.visits, accuracy: 3)
        XCTAssertLessThan(long.visits, 120)
        XCTAssertEqual(long.laidOutAway, [], "the click laid out text far from the point")
        // Diagnostics only: one wall-clock sample per document is too noisy to assert on.
        print("WYSIWYG click cost: 1,500 lines \(short); 60,000 lines \(long)")
    }

    func testClickAfterAScrollThatWasNotLaidOutLandsOnTheClickedLine() throws {
        let editor = try Self.editor(lineCount: 2000)
        defer { editor.window.close() }
        let scrolled = try scrollToTargetWithoutLayout(editor)

        let caret = try WYSIWYGPointerClickTestSupport.click(at: scrolled.point, in: editor)

        XCTAssertTrue(
            (scrolled.content.location ... NSMaxRange(scrolled.content)).contains(caret),
            "caret \(caret) for \(scrolled.content)"
        )
        // The click ran no view layout: the next layout pass lays out the scrolled-to viewport.
        XCTAssertEqual(WYSIWYGPointerClickTestSupport.viewportRange(of: editor.textView), scrolled.staleViewport)
        WYSIWYGPointerClickTestSupport.settle(editor.window, editor.textView)
        let viewport = try XCTUnwrap(WYSIWYGPointerClickTestSupport.viewportRange(of: editor.textView))
        XCTAssertTrue(NSLocationInRange(scrolled.content.location, viewport))
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: caret, length: 0))
    }

    /// Select Word, Select Line and moving by line leave STTextView a pending scroll to the
    /// selection, which its next `layout()` runs. A click must not run it.
    func testClickWithAPendingScrollToTheOldSelectionDoesNotJumpThere() throws {
        let editor = try Self.editor(lineCount: 2000)
        defer { editor.window.close() }
        let textView = editor.textView
        textView.textSelection = NSRange(location: 1, length: 0)
        textView.selectWord(nil)
        XCTAssertEqual(textView.selectedRange().location, 0)
        let scrolled = try scrollToTargetWithoutLayout(editor)
        let clipView = try XCTUnwrap(textView.enclosingScrollView?.contentView)
        let scrollOrigin = clipView.bounds.origin

        let caret = try WYSIWYGPointerClickTestSupport.click(at: scrolled.point, in: editor)

        XCTAssertTrue(
            (scrolled.content.location ... NSMaxRange(scrolled.content)).contains(caret),
            "caret \(caret) for \(scrolled.content)"
        )
        XCTAssertEqual(clipView.bounds.origin, scrollOrigin, "the click scrolled to the old selection")
        WYSIWYGPointerClickTestSupport.settle(editor.window, textView)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: caret, length: 0))
        XCTAssertEqual(clipView.bounds.origin.y, scrollOrigin.y, accuracy: 1, "the view left the clicked caret")
    }

    /// STTextView marks itself for layout from the clip view's bounds notification, but a
    /// request made during its own viewport pass only sets a private flag: a stale viewport
    /// can come with `needsLayout == false`. Holding the notification back reproduces that.
    func testClickOutsideAStaleViewportWithNoPendingLayoutLandsOnTheClickedLine() throws {
        let editor = try Self.editor(lineCount: 2000)
        defer { editor.window.close() }
        let clipView = try XCTUnwrap(editor.textView.enclosingScrollView?.contentView)
        clipView.postsBoundsChangedNotifications = false
        let scrolled = try scrollToTargetWithoutLayout(editor)
        XCTAssertFalse(editor.textView.needsLayout)

        let caret = try WYSIWYGPointerClickTestSupport.click(at: scrolled.point, in: editor)
        clipView.postsBoundsChangedNotifications = true

        XCTAssertTrue(
            (scrolled.content.location ... NSMaxRange(scrolled.content)).contains(caret),
            "caret \(caret) for \(scrolled.content)"
        )
        XCTAssertFalse(
            try hasLayout(atFraction: 0.9, in: editor.textView),
            "the click laid out text far from the point"
        )
    }

    /// After a scroll into text TextKit has never laid out, the next layout pass lays out the
    /// viewport from its top edge, by TextKit's height estimate of the text above it. The
    /// click must land where that pass draws the text under the pointer.
    func testClickInTextNeverLaidOutLandsWhereTheNextLayoutPassDrawsIt() throws {
        let source = (1 ... 600).map { "P\($0) alpha beta gamma delta" }.joined(separator: "\n")
        let editor = try WYSIWYGPointerClickTestSupport.makeEditor(source, size: NSSize(width: 640, height: 360))
        defer { editor.window.close() }
        let textView = editor.textView
        // Every third paragraph in a large font, as headings are: TextKit estimates the height
        // of text it has not laid out from its length, so the estimates are off.
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: textView))
        (source as NSString).enumerateSubstrings(
            in: NSRange(location: 0, length: storage.length),
            options: .byParagraphs
        ) { paragraph, range, _, _ in
            if let number = paragraph.flatMap({ Int($0.dropFirst().prefix { $0.isNumber }) }),
               number.isMultiple(of: 3)
            {
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 40), range: range)
            }
        }
        WYSIWYGPointerClickTestSupport.settle(editor.window, textView)
        let clipView = try XCTUnwrap(textView.enclosingScrollView?.contentView)
        let stale = WYSIWYGPointerClickTestSupport.viewportRange(of: textView)
        clipView.scroll(to: NSPoint(x: 0, y: textView.visibleRect.height * 4))
        textView.enclosingScrollView?.reflectScrolledClipView(clipView)
        XCTAssertEqual(WYSIWYGPointerClickTestSupport.viewportRange(of: textView), stale)
        let windowPoint = textView.convert(
            CGPoint(x: textView.visibleRect.minX + 120, y: textView.visibleRect.midY),
            to: nil
        )

        let caret = try WYSIWYGPointerClickTestSupport.click(at: windowPoint, in: editor)
        WYSIWYGPointerClickTestSupport.settle(editor.window, textView)

        let viewPoint = textView.convert(windowPoint, from: nil)
        let laidOut = WYSIWYGPointerHitTest.characterIndex(
            at: CGPoint(x: viewPoint.x - (textView.gutterView?.frame.width ?? 0), y: viewPoint.y),
            in: textView
        )
        XCTAssertFalse(laidOut.laidOutBand)
        XCTAssertEqual(laidOut.offset, caret, "the laid-out viewport maps the pointer elsewhere")
    }

    /// Paragraphs 300 pt apart: a point midway between two of them below the viewport has no
    /// line within the band's reach on one side, so it maps to no offset, not the line above.
    func testPointFartherFromTheTextThanTheBandReachesMapsToNoOffset() throws {
        let source = (1 ... 400).map { "P\($0) text" }.joined(separator: "\n")
        let editor = try WYSIWYGPointerClickTestSupport.makeEditor(
            source,
            size: NSSize(width: 640, height: 360),
            paragraphSpacing: 300
        )
        defer { editor.window.close() }
        let textView = editor.textView
        let storage = source as NSString
        let above = storage.range(of: "P50 text")
        let below = storage.range(of: "P51 text")
        let viewport = try XCTUnwrap(WYSIWYGPointerClickTestSupport.viewportRange(of: textView))
        XCTAssertFalse(NSLocationInRange(above.location, viewport))

        let contentManager = textView.textContentManager
        try textView.textLayoutManager.ensureLayout(for: XCTUnwrap(NSTextRange(
            NSRange(location: 0, length: NSMaxRange(below)),
            in: contentManager
        )))
        let aboveLine = try lineFrame(at: above.location, in: textView)
        let belowLine = try lineFrame(at: below.location, in: textView)
        XCTAssertGreaterThan(belowLine.minY - aboveLine.maxY, 250)

        let gap = WYSIWYGPointerHitTest.characterIndex(
            at: CGPoint(x: aboveLine.minX + 4, y: (aboveLine.maxY + belowLine.minY) / 2),
            in: textView
        )
        XCTAssertTrue(gap.laidOutBand)
        XCTAssertNil(gap.offset, "a line \(gap.offset ?? -1) outside the band's reach")

        let onLine = WYSIWYGPointerHitTest.characterIndex(
            at: CGPoint(x: belowLine.minX + 4, y: belowLine.midY),
            in: textView
        )
        XCTAssertTrue(onLine.laidOutBand)
        let offset = try XCTUnwrap(onLine.offset)
        XCTAssertTrue((below.location ... NSMaxRange(below)).contains(offset), "offset \(offset) for \(below)")
    }

    // MARK: - Helpers

    private struct ClickCost: CustomStringConvertible {
        let visits: Int
        let clickMilliseconds: Double
        /// Document fractions away from the viewport whose paragraph has layout after the click.
        let laidOutAway: [Double]

        var description: String {
            "visits \(visits), click \(String(format: "%.2f", clickMilliseconds)) ms, laid out \(laidOutAway)"
        }
    }

    /// Clicks folded bold text in the middle of the document and reports what the click
    /// visited and laid out.
    private func clickCost(lineCount: Int) throws -> ClickCost {
        let source = Self.document(lineCount: lineCount)
        let editor = try WYSIWYGPointerClickTestSupport.makeEditor(source)
        defer { editor.window.close() }
        let textView = editor.textView
        try WYSIWYGPointerClickTestSupport.scroll(editor, toFraction: 0.5, source: source)

        let storage = source as NSString
        // A few lines below the visible top, so the text above the point is laid out too.
        let top = try XCTUnwrap(EditorVisibleTop.utf16Offset(in: textView))
        let clicked = storage.range(of: "**b", options: [], range: NSRange(location: top + 200, length: 4000))
        XCTAssertNotEqual(clicked.location, NSNotFound)
        let content = NSRange(location: clicked.location + 2, length: 3)
        let point = try XCTUnwrap(WYSIWYGPointerClickTestSupport.visiblePoint(
            ofCharacterAt: content.location + 1,
            in: editor
        ))
        let away = [0.1, 0.25, 0.75, 0.9, 0.999]
        XCTAssertEqual(try away.filter { try hasLayout(atFraction: $0, in: textView) }, [])

        let viewPoint = textView.convert(point, from: nil)
        let containerPoint = CGPoint(x: viewPoint.x - (textView.gutterView?.frame.width ?? 0), y: viewPoint.y)
        let hit = WYSIWYGPointerHitTest.characterIndex(at: containerPoint, in: textView)
        XCTAssertNotNil(hit.offset)
        XCTAssertFalse(hit.laidOutBand)
        let start = DispatchTime.now().uptimeNanoseconds
        let caret = try WYSIWYGPointerClickTestSupport.click(at: point, in: editor)
        let clickMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        XCTAssertEqual(hit.offset, caret)
        XCTAssertTrue((content.location ... NSMaxRange(content)).contains(caret), "caret \(caret) for \(content)")
        return try ClickCost(
            visits: hit.visitedFragments,
            clickMilliseconds: clickMilliseconds,
            laidOutAway: away.filter { try hasLayout(atFraction: $0, in: textView) }
        )
    }

    private struct StaleScroll {
        /// Folded bold text on the line scrolled to.
        let content: NSRange
        /// A window point on `content`.
        let point: CGPoint
        let staleViewport: NSRange
    }

    private static func editor(lineCount: Int) throws -> WYSIWYGPointerClickTestSupport.Editor {
        try WYSIWYGPointerClickTestSupport.makeEditor(
            document(lineCount: lineCount),
            size: NSSize(width: 640, height: 360)
        )
    }

    /// Lays out the text down to line 301, so its frame is final, then scrolls there without
    /// a layout pass: the viewport still describes the top of the document.
    private func scrollToTargetWithoutLayout(_ editor: WYSIWYGPointerClickTestSupport.Editor) throws -> StaleScroll {
        let textView = editor.textView
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: textView)?.string) as NSString
        let target = storage.range(of: "L301 **b301**")
        XCTAssertNotEqual(target.location, NSNotFound)
        let stale = try XCTUnwrap(WYSIWYGPointerClickTestSupport.viewportRange(of: textView))
        XCTAssertFalse(NSLocationInRange(target.location, stale))

        let contentManager = textView.textContentManager
        let throughTarget = try XCTUnwrap(NSTextRange(
            NSRange(location: 0, length: NSMaxRange(target)),
            in: contentManager
        ))
        textView.textLayoutManager.ensureLayout(for: throughTarget)
        let targetLocation = try XCTUnwrap(contentManager.location(
            contentManager.documentRange.location,
            offsetBy: target.location
        ))
        let frame = try XCTUnwrap(textView.textLayoutManager.textLayoutFragment(for: targetLocation))
            .layoutFragmentFrame
        let clipView = try XCTUnwrap(textView.enclosingScrollView?.contentView)
        clipView.scroll(to: NSPoint(x: 0, y: frame.minY - 100))
        textView.enclosingScrollView?.reflectScrolledClipView(clipView)
        XCTAssertEqual(WYSIWYGPointerClickTestSupport.viewportRange(of: textView), stale)

        let content = NSRange(location: target.location + "L301 **".utf16.count, length: "b301".utf16.count)
        let point = try XCTUnwrap(WYSIWYGPointerClickTestSupport.visiblePoint(
            ofCharacterAt: content.location + 2,
            in: editor
        ))
        return StaleScroll(content: content, point: point, staleViewport: stale)
    }

    /// The first line of the paragraph at `offset`, in text container coordinates.
    private func lineFrame(at offset: Int, in textView: STTextView) throws -> CGRect {
        let contentManager = textView.textContentManager
        let location = try XCTUnwrap(contentManager.location(contentManager.documentRange.location, offsetBy: offset))
        let fragment = try XCTUnwrap(textView.textLayoutManager.textLayoutFragment(for: location))
        XCTAssertEqual(fragment.state, .layoutAvailable)
        let line = try XCTUnwrap(fragment.textLineFragments.first)
        return line.typographicBounds.offsetBy(
            dx: fragment.layoutFragmentFrame.minX,
            dy: fragment.layoutFragmentFrame.minY
        )
    }

    /// Reads the layout state of the paragraph at `fraction` of the document. Enumerating
    /// without `.ensuresLayout` reads the state without laying the paragraph out.
    private func hasLayout(atFraction fraction: Double, in textView: STTextView) throws -> Bool {
        let contentManager = textView.textContentManager
        let length = contentManager.offset(
            from: contentManager.documentRange.location,
            to: contentManager.documentRange.endLocation
        )
        let location = try XCTUnwrap(contentManager.location(
            contentManager.documentRange.location,
            offsetBy: Int(Double(length) * fraction)
        ))
        var state: NSTextLayoutFragment.State?
        textView.textLayoutManager.enumerateTextLayoutFragments(from: location, options: []) { fragment in
            state = fragment.state
            return false
        }
        return state == .layoutAvailable
    }

    private static func document(lineCount: Int) -> String {
        (1 ... lineCount).map { line in
            line.isMultiple(of: 25) ? "## Part \(line)" : "L\(line) **b\(line)** and [k\(line)](./\(line).md) end"
        }.joined(separator: "\n")
    }
}
