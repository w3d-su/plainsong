import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// Numbers against the text STTextView paints, not TextKit's metrics: STTextView raises
/// each line by half the height its line-height multiple adds, so a number placed on
/// TextKit's baseline sits 2-3 pt below body text (more on headings and image lines).
@MainActor
final class EditorLineNumberGutterPaintedBaselineTests: XCTestCase {
    private typealias Support = EditorLineNumberGutterTestSupport
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows.removeAll()
        super.tearDown()
    }

    func testNumbersEndOnTheSamePixelRowAsTheSameDigitInTheText() throws {
        // The rendering has a transparent background, so ink is told apart by color and
        // alpha. The default secondary-label numbers are only ~50% opaque black in light
        // mode, which made the comparison depend on the system appearance. Both columns
        // therefore use one opaque color, under a fixed appearance, in light and dark.
        for (appearance, ink) in [(NSAppearance.Name.aqua, NSColor.black), (.darkAqua, .white)] {
            try assertNumbersEndWithTheirText(appearance: appearance, ink: ink)
        }
    }

    /// Each line's text is its own number in the gutter's font, so in a rendering of the
    /// editor the digit in both columns must bottom out on the same pixel row.
    private func assertNumbersEndWithTheirText(appearance: NSAppearance.Name, ink: NSColor) throws {
        let editor = try Support.makeEditor("1\n2\n3\n4")
        windows.append(editor.window)
        editor.window.appearance = NSAppearance(named: appearance)
        editor.textView.highlightSelectedLine = false
        editor.textView.textColor = ink
        editor.textView.setLineNumberGutterStyle(EditorLineNumberGutterView.Style(
            font: Support.style.font,
            textColor: ink,
            currentLineTextColor: ink
        ))
        editor.textView.textSelection = NSRange(location: 7, length: 0)
        let gutterView = try XCTUnwrap(editor.textView.lineNumberGutter)
        let current = Support.Editor(
            window: editor.window, scrollView: editor.scrollView, textView: editor.textView, gutter: gutterView
        )
        let labels = try Support.drawnLabels(current)
        let rep = try render(editor.scrollView)
        let scale = CGFloat(rep.pixelsWide) / editor.scrollView.bounds.width
        let gutterColumns = columns(gutterView.frame, in: editor.scrollView, rep: rep)
        let textColumns = columns(editor.scrollView.contentView.frame, in: editor.scrollView, rep: rep)

        XCTAssertEqual(labels.filter { !$0.isCurrent }.map(\.number), [1, 2, 3], "\(appearance.rawValue)")
        for label in labels where !label.isCurrent {
            let band = editor.scrollView.convert(label.frame, from: editor.textView)
            let rows = rows(band, in: editor.scrollView, rep: rep)
            let context = "\(appearance.rawValue) line \(label.number)"
            let gutter = try XCTUnwrap(inkBottom(rep, columns: gutterColumns, rows: rows), "gutter, \(context)")
            let text = try XCTUnwrap(inkBottom(rep, columns: textColumns, rows: rows), "text, \(context)")
            XCTAssertEqual(
                CGFloat(gutter), CGFloat(text), accuracy: max(1, scale),
                "\(context): number ends \(CGFloat(gutter - text) / scale) pt from its text"
            )
        }
    }

    func testShiftFollowsTheLineHeightMultiple() {
        let style = NSMutableParagraphStyle()
        XCTAssertEqual(EditorLineNumberGutterFragments.paintedBaselineShift(lineHeight: 20, paragraphStyle: nil), 0)
        XCTAssertEqual(EditorLineNumberGutterFragments.paintedBaselineShift(lineHeight: 20, paragraphStyle: style), 0)
        style.lineHeightMultiple = 1.25
        XCTAssertEqual(
            EditorLineNumberGutterFragments.paintedBaselineShift(lineHeight: 20, paragraphStyle: style),
            -2.5
        )
        style.lineHeightMultiple = 1
        XCTAssertEqual(EditorLineNumberGutterFragments.paintedBaselineShift(lineHeight: 20, paragraphStyle: style), 0)
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        view.window?.layoutIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Pixel columns of `rect` (in `view` coordinates).
    private func columns(_ rect: NSRect, in view: NSView, rep: NSBitmapImageRep) -> Range<Int> {
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let lower = max(0, Int((rect.minX * scale).rounded(.up)))
        let upper = min(rep.pixelsWide, Int((rect.maxX * scale).rounded(.down)))
        return lower ..< max(lower, upper)
    }

    /// Pixel rows of `rect`, counted from the top as `NSBitmapImageRep` does.
    private func rows(_ rect: NSRect, in view: NSView, rep: NSBitmapImageRep) -> Range<Int> {
        let scale = CGFloat(rep.pixelsHigh) / view.bounds.height
        let top = view.isFlipped ? rect.minY : view.bounds.height - rect.maxY
        let lower = max(0, Int((top * scale).rounded(.up)))
        let upper = min(rep.pixelsHigh, Int(((top + rect.height) * scale).rounded(.down)))
        return lower ..< max(lower, upper)
    }

    /// The lowest row in `rows` with a pixel clearly unlike the band's first row.
    private func inkBottom(_ rep: NSBitmapImageRep, columns: Range<Int>, rows: Range<Int>) -> Int? {
        guard let first = rows.first, !columns.isEmpty else { return nil }
        var bottom: Int?
        for y in rows {
            for x in columns where differs(rep.colorAt(x: x, y: y), rep.colorAt(x: x, y: first)) {
                bottom = y
                break
            }
        }
        return bottom
    }

    private func differs(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        guard let lhs = lhs?.usingColorSpace(.deviceRGB), let rhs = rhs?.usingColorSpace(.deviceRGB) else {
            return false
        }
        let delta = abs(lhs.redComponent - rhs.redComponent) + abs(lhs.greenComponent - rhs.greenComponent)
            + abs(lhs.blueComponent - rhs.blueComponent) + abs(lhs.alphaComponent - rhs.alphaComponent)
        return delta > 0.6
    }
}
