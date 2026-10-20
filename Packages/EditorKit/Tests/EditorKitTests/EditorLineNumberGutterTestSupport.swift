import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// Windowed editors with EditorKit's line-number gutter, drawn into a bitmap.
@MainActor
enum EditorLineNumberGutterTestSupport {
    struct Editor {
        let window: NSWindow
        let scrollView: NSScrollView
        let textView: MarkdownSTTextView
        let gutter: EditorLineNumberGutterView
    }

    static let style = EditorLineNumberGutterView.Style(
        font: MarkdownSyntaxHighlighter.defaultFont,
        textColor: .secondaryLabelColor,
        currentLineTextColor: .labelColor
    )

    /// The caller closes the returned window.
    static func makeEditor(
        _ text: String,
        size: NSSize = NSSize(width: 420, height: 320)
    ) throws -> Editor {
        let frame = NSRect(origin: .zero, size: size)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.isEditable = true
        textView.isSelectable = true
        textView.highlightSelectedLine = true
        textView.isHorizontallyResizable = false
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.25
        textView.defaultParagraphStyle = paragraphStyle
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.orderFront(nil)
        textView.text = text
        textView.setLineNumberGutterStyle(style)
        let gutter = try XCTUnwrap(textView.lineNumberGutter)
        textView.layoutSubtreeIfNeeded()
        return Editor(window: window, scrollView: scrollView, textView: textView, gutter: gutter)
    }

    static func drawnLabels(_ editor: Editor) throws -> [EditorLineNumberGutterLayout.Label] {
        editor.window.layoutIfNeeded()
        editor.textView.layoutSubtreeIfNeeded()
        let draws = editor.gutter.drawCount
        // Draws into a bitmap: the window server may not display windows of a test
        // process (or of a locked screen).
        let gutter = editor.gutter
        let rep = try XCTUnwrap(gutter.bitmapImageRepForCachingDisplay(in: gutter.bounds))
        gutter.cacheDisplay(in: gutter.bounds, to: rep)
        XCTAssertGreaterThan(gutter.drawCount, draws, "frame \(gutter.frame)")
        return gutter.lastDrawnLabels
    }

    /// Independent of the gutter's fragment walk: TextKit's segment baseline at each
    /// source line start that is visible.
    static func assertLabelsSitOnLineBaselines(
        _ labels: [EditorLineNumberGutterLayout.Label],
        in textView: STTextView,
        text: String,
        file: StaticString,
        line: UInt
    ) throws {
        let index = EditorScrollLineIndex(text: text)
        let contentManager = textView.textContentManager
        for label in labels {
            let offset = index.utf16Offset(forOneBasedLine: label.number)
            let location = try XCTUnwrap(contentManager.location(
                contentManager.documentRange.location,
                offsetBy: offset
            ))
            var baseline: CGFloat?
            textView.textLayoutManager.enumerateTextSegments(
                in: NSTextRange(location: location),
                type: .standard,
                options: [.upstreamAffinity]
            ) { _, frame, baselinePosition, _ in
                baseline = frame.minY + baselinePosition
                return false
            }
            let expected = try XCTUnwrap(baseline, file: file, line: line)
            XCTAssertEqual(label.baseline, expected, accuracy: 0.5, "line \(label.number)", file: file, line: line)
        }
    }

    static func lineHeight(_ textView: STTextView) -> CGFloat {
        var height: CGFloat = 0
        textView.textLayoutManager.enumerateTextLayoutFragments(
            from: textView.textLayoutManager.documentRange.location
        ) { fragment in
            height = fragment.textLineFragments.first?.typographicBounds.height ?? 0
            return false
        }
        return height
    }
}
