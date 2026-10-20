import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// The gutter view in its scroll view: tiling, settings and redraw triggers.
@MainActor
final class EditorLineNumberGutterViewTests: XCTestCase {
    private typealias Support = EditorLineNumberGutterTestSupport
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows.removeAll()
        super.tearDown()
    }

    func testGutterReplacesSTTextViewGutterAndNarrowsTheClipView() throws {
        let editor = try makeEditor("one\ntwo\n")
        let scrollView = try XCTUnwrap(editor.scrollView as? EditorScrollView)

        XCTAssertFalse(editor.textView.showsLineNumbers)
        XCTAssertNil(editor.textView.gutterView)
        XCTAssertTrue(scrollView.lineNumberGutter === editor.gutter)
        XCTAssertEqual(editor.gutter.thickness, EditorLineNumberGutterView.thickness(
            digits: 3,
            digitWidth: digitWidth(MarkdownSyntaxHighlighter.defaultFont)
        ))
        XCTAssertEqual(editor.gutter.frame, NSRect(x: 0, y: 0, width: editor.gutter.thickness, height: 320))
        XCTAssertEqual(scrollView.contentView.frame.minX, editor.gutter.frame.maxX)
        XCTAssertEqual(scrollView.contentView.bounds.minX, 0)
        XCTAssertEqual(editor.textView.frame.width, 420 - editor.gutter.thickness, accuracy: 1)
        XCTAssertEqual(editor.textView.textContainer.size.width, 420 - editor.gutter.thickness, accuracy: 1)
    }

    func testRetilingDoesNotPassTheTextThroughTheFullClipWidth() throws {
        let editor = try makeEditor("one\ntwo\n")
        let width = editor.textView.frame.width
        var widths: [CGFloat] = []
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: editor.textView,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated { widths.append(editor.textView.frame.width) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        editor.scrollView.tile()
        XCTAssertEqual(widths.filter { $0 != width }, [], "a text container change re-lays out the whole document")

        editor.window.setContentSize(NSSize(width: 520, height: 320))
        XCTAssertEqual(editor.textView.frame.width, 520 - editor.gutter.thickness, accuracy: 1)
        XCTAssertFalse(widths.contains { $0 > 520 - editor.gutter.thickness + 1 })
    }

    func testHidingRemovesTheGutterAndRestoresTheTextWidth() throws {
        let editor = try makeEditor("one\ntwo\n")
        let narrow = editor.textView.textContainer.size.width

        editor.textView.setLineNumberGutterStyle(nil)
        editor.textView.layoutSubtreeIfNeeded()

        XCTAssertNil(editor.textView.lineNumberGutter)
        XCTAssertNil((editor.scrollView as? EditorScrollView)?.lineNumberGutter)
        XCTAssertNil(editor.gutter.superview)
        XCTAssertEqual(editor.scrollView.contentView.frame.minX, 0)
        XCTAssertEqual(editor.textView.textContainer.size.width, narrow + editor.gutter.thickness, accuracy: 1)
        XCTAssertNil(editor.textView.gutterView)

        editor.textView.setLineNumberGutterStyle(Support.style)
        editor.textView.layoutSubtreeIfNeeded()
        let shown = try XCTUnwrap(editor.textView.lineNumberGutter)
        XCTAssertFalse(shown === editor.gutter)
        XCTAssertEqual(editor.textView.textContainer.size.width, narrow, accuracy: 1)
        XCTAssertEqual(try drawnLabels(Support.Editor(
            window: editor.window, scrollView: editor.scrollView, textView: editor.textView, gutter: shown
        )).map(\.number), [1, 2, 3])
    }

    func testSettingsUpdatesWithUnchangedSettingsKeepTheStyle() {
        // `MarkdownTextView` rebuilds the style on every SwiftUI update; an equal style must
        // not reset the typeset numbers or the width.
        let font = {
            MarkdownSyntaxHighlighter.editorFont(named: MarkdownSyntaxHighlighter.systemMonospacedFontName, size: 13)
        }
        for theme in MarkdownEditorTheme.allCases {
            let style = EditorLineNumberGutterView.Style(showing: true, theme: theme, font: font())
            XCTAssertEqual(style, EditorLineNumberGutterView.Style(showing: true, theme: theme, font: font()))
            XCTAssertEqual(style?.textColor, MarkdownSyntaxTheme.builtIn(theme).mutedColor)
            XCTAssertEqual(style?.currentLineTextColor, MarkdownSyntaxTheme.builtIn(theme).textColor)
            XCTAssertNil(EditorLineNumberGutterView.Style(showing: false, theme: theme, font: font()))
        }
    }

    func testStyleChangesRedrawAndAFontChangeResizes() throws {
        let editor = try makeEditor("one\ntwo\n")
        _ = try drawnLabels(editor)
        let thickness = editor.gutter.thickness

        var recolored = Support.style
        recolored.textColor = .systemRed
        editor.gutter.update(style: recolored)
        XCTAssertTrue(editor.gutter.needsDisplay)
        XCTAssertEqual(editor.gutter.thickness, thickness)

        let larger = try XCTUnwrap(NSFont.monospacedSystemFont(ofSize: 20, weight: .regular))
        editor.textView.setLineNumberGutterStyle(EditorLineNumberGutterView.Style(
            font: larger,
            textColor: .systemRed,
            currentLineTextColor: .labelColor
        ))
        XCTAssertGreaterThan(editor.gutter.thickness, thickness)
        XCTAssertEqual(editor.gutter.frame.width, editor.gutter.thickness)
        XCTAssertEqual(editor.scrollView.contentView.frame.minX, editor.gutter.thickness)

        _ = try drawnLabels(editor)
        editor.gutter.appearance = NSAppearance(named: .darkAqua)
        XCTAssertTrue(editor.gutter.needsDisplay, "dynamic colors resolve again for the new appearance")
    }

    private func makeEditor(_ text: String) throws -> Support.Editor {
        let editor = try Support.makeEditor(text)
        windows.append(editor.window)
        return editor
    }

    private func drawnLabels(_ editor: Support.Editor) throws -> [EditorLineNumberGutterLayout.Label] {
        try Support.drawnLabels(editor)
    }

    private func digitWidth(_ font: NSFont) -> CGFloat {
        "0123456789".map { (String($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    }
}
