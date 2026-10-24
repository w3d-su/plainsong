import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// A WYSIWYG click maps its point against the laid-out viewport only: the work must not
/// depend on the document's length, and text away from the viewport stays without layout.
@MainActor
final class WYSIWYGPointerHitTestTests: XCTestCase {
    func testClickWorkDoesNotGrowWithTheDocument() throws {
        let short = try clickCost(lineCount: 1500)
        let long = try clickCost(lineCount: 60000)

        // The hit-test visits the TextKit viewport only: the same fragments for both documents.
        XCTAssertEqual(long.visits, short.visits, accuracy: 3)
        XCTAssertLessThan(long.visits, 120)
        XCTAssertEqual(long.laidOutAway, [], "the click laid out text far from the viewport")
        // Loose: timings are noisy on a loaded machine, but laying out the 60,000-line
        // document would cost a large multiple.
        XCTAssertLessThan(long.clickMilliseconds, max(short.clickMilliseconds * 4, 5), "\(short) \(long)")
    }

    func testClickAfterAScrollThatWasNotLaidOutLandsOnTheClickedLine() throws {
        let source = Self.document(lineCount: 2000)
        let editor = try WYSIWYGPointerClickTestSupport.makeEditor(source, size: NSSize(width: 640, height: 360))
        defer { editor.window.close() }
        let textView = editor.textView
        let storage = source as NSString
        let target = storage.range(of: "L301 **b301**")
        XCTAssertNotEqual(target.location, NSNotFound)
        let stale = try XCTUnwrap(WYSIWYGPointerClickTestSupport.viewportRange(of: textView))
        XCTAssertFalse(NSLocationInRange(target.location, stale))

        // Lay out down to the target line, so its frame is final, then scroll there without a
        // layout pass: the viewport still describes the top of the document.
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
        let caret = try WYSIWYGPointerClickTestSupport.click(at: point, in: editor)

        XCTAssertTrue((content.location ... NSMaxRange(content)).contains(caret), "caret \(caret) for \(content)")
        let viewport = try XCTUnwrap(WYSIWYGPointerClickTestSupport.viewportRange(of: textView))
        XCTAssertTrue(NSLocationInRange(target.location, viewport), "the click laid out the scrolled-to viewport")
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
        XCTAssertTrue(hit.coversPoint)
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

    /// Reads the layout state of the paragraph at `fraction` of the document. Enumerating
    /// without `.ensuresLayout` does not lay it out (`textLayoutFragment(for:)` does).
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
