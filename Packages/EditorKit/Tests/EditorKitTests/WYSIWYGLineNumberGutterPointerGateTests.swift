import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// The B5/L6/I6 pointer gates run with line numbers off. Since #189 the line numbers are
/// EditorKit's own gutter, tiled by `EditorScrollView` beside the clip view instead of
/// inside the text view, so a WYSIWYG hit-test must not offset for it. These tests send
/// real `NSEvent` clicks to a folded document with that gutter showing.
@MainActor
final class WYSIWYGLineNumberGutterPointerGateTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows.removeAll()
        super.tearDown()
    }

    func testRealPointerClicksBesideTheGutterLandOnTheClickedVisibleCharacter() throws {
        let source = "# Heading\n\nA **bold** word and [a link](https://example.com/x) tail\n\nPlain ~~gone~~ end\n"
        let editor = try makeFoldedEditor(source)
        XCTAssertGreaterThan(editor.gutter.frame.width, 0)
        XCTAssertGreaterThanOrEqual(editor.scrollView.contentView.frame.minX, editor.gutter.frame.maxX)

        for target in ["Heading", "bold", "word", "a link", "tail", "gone", "end"] {
            let range = (source as NSString).range(of: target)
            // The middle character of each visible word, after zero-width delimiters.
            let character = NSRange(location: range.location + range.length / 2, length: 1)
            let caret = try click(character, in: editor)
            XCTAssertTrue(
                caret == character.location || caret == NSMaxRange(character),
                "Click on \(target) landed at \(caret), expected \(character.location) or \(NSMaxRange(character))"
            )
        }
        XCTAssertEqual(MarkdownTextView.textStorage(of: editor.textView)?.string, source)
    }
}

private extension WYSIWYGLineNumberGutterPointerGateTests {
    func makeFoldedEditor(_ source: String) throws -> EditorLineNumberGutterTestSupport.Editor {
        let editor = try EditorLineNumberGutterTestSupport.makeEditor(source, size: NSSize(width: 640, height: 360))
        windows.append(editor.window)
        editor.window.makeKeyAndOrderFront(nil)
        editor.window.makeFirstResponder(editor.textView)
        XCTAssertTrue(editor.textView.setWYSIWYGZeroWidthFoldingEnabled(true))
        // Park the caret at the end so every span on the earlier lines stays folded.
        let end = (source as NSString).length
        let highlighted = MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: end),
            developmentPresentation: .inlineFoldRevealWithLinkFolding,
            selection: NSRange(location: end, length: 0)
        )
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(
            HighlightedText(
                revision: 1,
                range: highlighted.range,
                text: highlighted.text,
                foldPlan: highlighted.foldPlan
            ),
            to: editor.textView
        ))
        editor.textView.layoutSubtreeIfNeeded()
        return editor
    }

    /// A left click at the centre of `character`'s laid-out rect; returns the resulting caret.
    func click(_ character: NSRange, in editor: EditorLineNumberGutterTestSupport.Editor) throws -> Int {
        let screenRect = editor.textView.firstRect(forCharacterRange: character, actualRange: nil)
        XCTAssertGreaterThan(screenRect.width, 0, "Expected a laid-out rect for \(character)")
        let windowPoint = editor.window.convertPoint(fromScreen: CGPoint(x: screenRect.midX, y: screenRect.midY))
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: editor.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        editor.textView.mouseDown(with: event)
        let selection = editor.textView.selectedRange()
        XCTAssertEqual(selection.length, 0)
        return selection.location
    }
}
