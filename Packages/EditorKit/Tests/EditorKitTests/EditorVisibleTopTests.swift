@testable import EditorKit
import STTextView
import XCTest

@MainActor
final class EditorVisibleTopTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows.removeAll()
        super.tearDown()
    }

    func testTopIsTheFragmentAtTheVisibleEdgeNotTheViewportStart() throws {
        let (scrollView, textView) = try makeTextView()
        scroll(scrollView, textView, toY: 40000)

        let viewportStart = try viewportStartOffset(textView)
        let top = try XCTUnwrap(EditorVisibleTop.utf16Offset(in: textView))

        // TextKit's own hit test at the visible edge is the reference answer.
        XCTAssertEqual(top, try hitTestOffset(textView, y: textView.visibleRect.minY + 1))
        // The viewport starts in STTextView's prefetch band, well above the visible top.
        XCTAssertLessThan(lineNumber(textView, viewportStart) + 10, lineNumber(textView, top))
    }

    func testTopAtTheDocumentStartIsTheFirstLine() throws {
        let (_, textView) = try makeTextView()

        XCTAssertEqual(EditorVisibleTop.utf16Offset(in: textView), 0)
    }

    func testScrollSyncReportsTheVisibleTopLine() async throws {
        let (scrollView, textView) = try makeTextView()
        let proxy = EditorScrollProxy()
        var lines: [Int] = []
        proxy.onScrollIntent = { intent in
            if case let .viewportChanged(line) = intent { lines.append(line) }
        }
        proxy.attach(to: textView)

        scroll(scrollView, textView, toY: 40000)
        let expected = try lineNumber(textView, hitTestOffset(textView, y: textView.visibleRect.minY + 1))
        for _ in 0 ..< 20 where lines.last != expected {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(lines.last, expected)
    }

    private func makeTextView() throws -> (scrollView: NSScrollView, textView: MarkdownSTTextView) {
        let frame = NSRect(x: 0, y: 0, width: 700, height: 800)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.orderFront(nil)
        windows.append(window)
        textView.text = (1 ... 6000).map { "Line \($0) of the scroll sync fixture.\n" }.joined()
        textView.layoutSubtreeIfNeeded()
        return (scrollView, textView)
    }

    private func scroll(_ scrollView: NSScrollView, _ textView: STTextView, toY y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.layoutSubtreeIfNeeded()
    }

    private func viewportStartOffset(_ textView: STTextView) throws -> Int {
        let range = try XCTUnwrap(textView.textLayoutManager.textViewportLayoutController.viewportRange)
        let contentManager = textView.textContentManager
        return contentManager.offset(from: contentManager.documentRange.location, to: range.location)
    }

    private func hitTestOffset(_ textView: STTextView, y: CGFloat) throws -> Int {
        let fragment = try XCTUnwrap(textView.textLayoutManager.textLayoutFragment(for: CGPoint(x: 1, y: y)))
        let contentManager = textView.textContentManager
        return contentManager.offset(from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
    }

    private func lineNumber(_ textView: STTextView, _ offset: Int) -> Int {
        let text = (textView.text ?? "") as NSString
        return text.substring(to: offset).components(separatedBy: "\n").count
    }
}
