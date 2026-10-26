import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// Windowed Experimental WYSIWYG editors for pointer-click cost tests: the visible range is
/// folded as the app's visible-range highlight folds it, and clicks are real `NSEvent`s.
@MainActor
enum WYSIWYGPointerClickTestSupport {
    struct Editor {
        let window: NSWindow
        let textView: MarkdownSTTextView
    }

    /// The caller closes the returned window.
    static func makeEditor(
        _ source: String,
        size: NSSize = NSSize(width: 900, height: 800),
        paragraphSpacing: CGFloat = 0
    ) throws -> Editor {
        let frame = NSRect(origin: .zero, size: size)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        scrollView.scrollerStyle = .overlay
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.isEditable = true
        textView.isSelectable = true
        textView.highlightSelectedLine = true
        textView.isHorizontallyResizable = false
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.25
        paragraphStyle.paragraphSpacing = paragraphSpacing
        textView.defaultParagraphStyle = paragraphStyle
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        textView.text = source
        textView.setWYSIWYGZeroWidthFoldingEnabled(true)
        window.makeFirstResponder(textView)
        settle(window, textView)
        return Editor(window: window, textView: textView)
    }

    /// Scrolls the line holding `fraction` of the document into view and folds the laid-out
    /// viewport plus 4 Ki of padding, as the app's visible-range highlight does.
    static func scroll(_ editor: Editor, toFraction fraction: Double, source: String) throws {
        let textView = editor.textView
        let length = (source as NSString).length
        let target = min(Int(Double(length) * fraction), max(length - 1, 0))
        let line = (source as NSString).lineRange(for: NSRange(location: target, length: 0))
        textView.textSelection = NSRange(location: line.location, length: 0)
        textView.scrollRangeToVisible(textView.selectedRange())
        settle(editor.window, textView)

        let viewport = try XCTUnwrap(viewportRange(of: textView))
        let start = max(0, viewport.location - 4096)
        let end = min(length, NSMaxRange(viewport) + 4096)
        let highlighted = MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: NSRange(location: start, length: end - start),
            developmentPresentation: .inlineFoldRevealWithLinkFolding,
            selection: textView.selectedRange()
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
        settle(editor.window, textView)
    }

    /// Thumbnail placeholders for the images in `range`, as a folder workspace shows them.
    static func placeImageThumbnails(_ editor: Editor, in range: NSRange, source: String) {
        let storage = source as NSString
        var markers: [WYSIWYGImagePresentationMarker] = []
        var searchRange = range
        while true {
            let image = storage.range(of: "![", options: [], range: searchRange)
            guard image.location != NSNotFound else { break }
            let end = storage.range(of: ")", options: [], range: NSRange(
                location: image.location,
                length: NSMaxRange(range) - image.location
            ))
            guard end.location != NSNotFound else { break }
            let sourceRange = NSRange(location: image.location, length: NSMaxRange(end) - image.location)
            markers.append(WYSIWYGImagePresentationMarker(
                generation: 1,
                sourceRange: sourceRange,
                source: "image.png",
                altText: "sample",
                canvasSize: NSSize(width: 160, height: 96),
                outcome: nil
            ))
            searchRange = NSRange(
                location: NSMaxRange(sourceRange),
                length: NSMaxRange(range) - NSMaxRange(sourceRange)
            )
        }
        editor.textView.applyWYSIWYGImagePresentationMarkers(markers, replacing: [], generation: 1, forceReapply: true)
        settle(editor.window, editor.textView)
    }

    static func viewportRange(of textView: STTextView) -> NSRange? {
        textView.textLayoutManager.textViewportLayoutController.viewportRange
            .map { NSRange($0, in: textView.textContentManager) }
    }

    /// The visible window point of the character at `offset`, or nil when it is folded to
    /// zero width or outside the visible rect.
    static func visiblePoint(ofCharacterAt offset: Int, in editor: Editor) -> CGPoint? {
        let screenRect = editor.textView.firstRect(
            forCharacterRange: NSRange(location: offset, length: 1),
            actualRange: nil
        )
        guard screenRect.width > 0.5, screenRect.height > 0.5 else { return nil }
        let windowPoint = editor.window.convertPoint(fromScreen: CGPoint(x: screenRect.midX, y: screenRect.midY))
        let viewPoint = editor.textView.convert(windowPoint, from: nil)
        guard editor.textView.visibleRect.insetBy(dx: 0, dy: 4).contains(viewPoint) else { return nil }
        return windowPoint
    }

    /// Dispatches a real left-mouse-down and returns the caret it placed.
    static func click(at windowPoint: CGPoint, in editor: Editor, shift: Bool = false) throws -> Int {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: shift ? .shift : [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: editor.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        editor.textView.mouseDown(with: event)
        return editor.textView.selectedRange().location
    }

    static func settle(_ window: NSWindow, _ textView: STTextView) {
        textView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    static var largeFixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/large-1mb.md")
    }
}
