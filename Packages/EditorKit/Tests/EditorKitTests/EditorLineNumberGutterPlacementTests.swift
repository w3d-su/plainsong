import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// Where numbers land: each source line's first visual line, through wrapping, resizing,
/// scrolling and WYSIWYG presentation.
@MainActor
final class EditorLineNumberGutterPlacementTests: XCTestCase {
    private typealias Support = EditorLineNumberGutterTestSupport
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows.removeAll()
        super.tearDown()
    }

    func testNumbersSitOnTheBaselineOfEachSourceLinesFirstVisualLine() throws {
        let long = String(repeating: "wrapping words ", count: 12)
        let text = "# Heading\n\(long)\n\nshort\n\(long)\r\nlast"
        let editor = try makeEditor(text)

        let labels = try drawnLabels(editor)

        XCTAssertEqual(labels.map(\.number), Array(1 ... 6))
        try assertLabelsSitOnLineBaselines(labels, in: editor.textView, text: text)
        let wrapped = try XCTUnwrap(labels.first { $0.number == 2 })
        let next = try XCTUnwrap(labels.first { $0.number == 3 })
        XCTAssertGreaterThan(next.baseline - wrapped.baseline, 3 * lineHeight(editor.textView), "line 2 wraps")
    }

    func testEmptyDocumentAndFinalNewlineAreNumbered() throws {
        let editor = try makeEditor("")
        let empty = try drawnLabels(editor)
        XCTAssertEqual(empty.map(\.number), [1])

        editor.textView.insertText("first\n", replacementRange: NSRange(location: 0, length: 0))
        let labels = try drawnLabels(editor)
        XCTAssertEqual(labels.map(\.number), [1, 2])
        XCTAssertEqual(labels[0].baseline, empty[0].baseline, accuracy: 0.5)
        XCTAssertEqual(labels[1].baseline - labels[0].baseline, lineHeight(editor.textView), accuracy: 0.5)
        XCTAssertEqual(labels.map(\.isCurrent), [false, true])
        try assertLabelsSitOnLineBaselines(labels, in: editor.textView, text: "first\n")
    }

    func testResizingRewrapsAndNumbersFollow() throws {
        let long = String(repeating: "wrap me again ", count: 16)
        let text = "\(long)\nshort\n\(long)\n"
        let editor = try makeEditor(text, size: NSSize(width: 640, height: 400))
        let wide = try drawnLabels(editor)

        editor.window.setContentSize(NSSize(width: 360, height: 400))
        editor.textView.layoutSubtreeIfNeeded()
        let narrow = try drawnLabels(editor)

        XCTAssertEqual(wide.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(narrow.map(\.number), [1, 2, 3, 4])
        XCTAssertGreaterThan(narrow[1].baseline, wide[1].baseline, "line 1 wraps onto more lines")
        XCTAssertEqual(editor.gutter.frame.height, 400, accuracy: 1)
        try assertLabelsSitOnLineBaselines(narrow, in: editor.textView, text: text)
    }

    func testScrollingRedrawsTheNumbersOfTheNewVisibleLines() throws {
        let text = (1 ... 400).map { "line \($0)" }.joined(separator: "\n")
        let editor = try makeEditor(text)
        let top = try drawnLabels(editor)
        XCTAssertEqual(top.first?.number, 1)

        editor.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 2000))
        editor.scrollView.reflectScrolledClipView(editor.scrollView.contentView)
        XCTAssertTrue(editor.gutter.needsDisplay)
        editor.textView.layoutSubtreeIfNeeded()
        let scrolled = try drawnLabels(editor)

        let visible = editor.textView.visibleRect
        let shown = scrolled.filter { $0.frame.maxY > visible.minY && $0.frame.minY < visible.maxY }
        let firstShown = try XCTUnwrap(shown.first)
        XCTAssertGreaterThan(firstShown.number, 50)
        XCTAssertEqual(shown.map(\.number), Array(firstShown.number ..< firstShown.number + shown.count))
        try assertLabelsSitOnLineBaselines(shown, in: editor.textView, text: text)
        XCTAssertLessThan(
            editor.gutter.lastDrawFragmentVisits,
            3 * shown.count,
            "a draw visits the viewport, which extends at most half a screen around the visible lines"
        )
    }

    func testWYSIWYGFoldsAndImageThumbnailsMoveTheNumbersWithTheirLines() async throws {
        let source = "**Bold** first\n\(WYSIWYGImageThumbnailGateSupport.imageSource)\n`code` after\n"
        let fixture = try WYSIWYGImageThumbnailGateSupport.makeWindowedEditor(source: source)
        fixture.window.isReleasedWhenClosed = false
        windows.append(fixture.window)
        let imageRange = (source as NSString).range(of: WYSIWYGImageThumbnailGateSupport.imageSource)
        _ = try await WYSIWYGImageThumbnailGateSupport.waitForMarker(
            in: fixture.textView,
            range: imageRange,
            matching: { if case .ready = $0.visualState { true } else { false } }
        )
        fixture.textView.setLineNumberGutterStyle(Support.style)
        let gutter = try XCTUnwrap(fixture.textView.lineNumberGutter)
        WYSIWYGImageThumbnailGateSupport.ensureLayout(in: fixture.textView)
        let scrollView = try XCTUnwrap(fixture.textView.enclosingScrollView)
        let labels = try drawnLabels(Support.Editor(
            window: fixture.window, scrollView: scrollView, textView: fixture.textView, gutter: gutter
        ))

        XCTAssertEqual(labels.map(\.number), [1, 2, 3, 4])
        try assertLabelsSitOnLineBaselines(labels, in: fixture.textView, text: source)
        let textLine = labels[2].baseline - labels[1].baseline
        let imageLine = labels[1].baseline - labels[0].baseline
        XCTAssertGreaterThan(imageLine, 2 * (labels[3].baseline - labels[2].baseline), "the thumbnail line is tall")
        XCTAssertGreaterThan(textLine, 0)
    }

    private func makeEditor(
        _ text: String,
        size: NSSize = NSSize(width: 420, height: 320)
    ) throws -> Support.Editor {
        let editor = try Support.makeEditor(text, size: size)
        windows.append(editor.window)
        return editor
    }

    private func drawnLabels(_ editor: Support.Editor) throws -> [EditorLineNumberGutterLayout.Label] {
        try Support.drawnLabels(editor)
    }

    private func assertLabelsSitOnLineBaselines(
        _ labels: [EditorLineNumberGutterLayout.Label],
        in textView: STTextView,
        text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try Support.assertLabelsSitOnLineBaselines(labels, in: textView, text: text, file: file, line: line)
    }

    private func lineHeight(_ textView: STTextView) -> CGFloat {
        Support.lineHeight(textView)
    }
}
