import AppKit
@testable import EditorKit
import STTextView
import XCTest

@MainActor
final class EditorTextElementCacheTrimmerTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows.removeAll()
        super.tearDown()
    }

    func testChunksWalkBackFromTheEndToAMarginBelowTheViewport() throws {
        let textView = try makeTextView(String(repeating: "a", count: 100_000)).textView
        let visible = NSRange(location: 1000, length: 2000)
        let keepEnd = 3000 + 8192

        var end = 100_000
        var chunks: [NSRange] = []
        while let chunk = EditorTextElementCacheTrimmer.nextChunk(below: visible, endingAt: end, in: textView) {
            chunks.append(chunk)
            end = chunk.location
        }
        XCTAssertEqual(chunks.first, NSRange(location: 100_000 - 32768, length: 32768))
        XCTAssertEqual(chunks.last?.location, keepEnd)
        XCTAssertEqual(chunks.map(\.length).reduce(0, +), 100_000 - keepEnd)
        // A short tail stays cached: rewriting its ranges on edits is cheap.
        let nearEnd = NSRange(location: 100_000 - 20000, length: 2000)
        XCTAssertNil(EditorTextElementCacheTrimmer.nextChunk(below: nearEnd, endingAt: 100_000, in: textView))
        XCTAssertNil(EditorTextElementCacheTrimmer.nextChunk(
            below: NSRange(location: NSNotFound, length: 0), endingAt: 100_000, in: textView
        ))
    }

    func testTrimChangesNoTextAttributesSelectionUndoOrScrollPosition() throws {
        let (scrollView, textView) = try makeTextView(document())
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: textView))
        storage.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 10, length: 500))
        storage.addAttribute(
            .foregroundColor,
            value: NSColor.systemBlue,
            range: NSRange(location: storage.length - 900, length: 400)
        )
        jumpToEndAndBack(scrollView, textView)
        textView.insertText("typed", replacementRange: textView.selectedRange())
        let before = try XCTUnwrap(storage.copy() as? NSAttributedString)
        let selection = textView.selectedRange()
        let origin = scrollView.contentView.bounds.origin
        let canUndo = textView.undoManager?.canUndo

        try trimAll(below: visibleRange(textView), in: textView)
        textView.layoutSubtreeIfNeeded()

        XCTAssertTrue(storage.isEqual(to: before))
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertEqual(scrollView.contentView.bounds.origin, origin)
        XCTAssertEqual(textView.undoManager?.canUndo, canUndo)
        textView.undoManager?.undo()
        XCTAssertFalse(storage.string.contains("typed"))
    }

    /// Ratio, not an absolute budget: with the tail cached each edit rewrote every later
    /// element's range (~50 ms per keystroke at 1 MiB in release builds, ~2 ms trimmed).
    func testTrimRestoresCheapEditsAfterTheDocumentEndWasInView() throws {
        let (scrollView, textView) = try makeTextView(document())
        jumpToEndAndBack(scrollView, textView)
        let cached = medianInsertMilliseconds(textView)
        try trimAll(below: visibleRange(textView), in: textView)
        let trimmed = medianInsertMilliseconds(textView)
        XCTAssertLessThan(trimmed, cached / 4, "cached \(cached) ms, trimmed \(trimmed) ms")
    }

    func testTrimIsRefusedDuringMarkedTextComposition() throws {
        let textView = try makeTextView(String(repeating: "段落\n", count: 1000)).textView
        textView.textSelection = NSRange(location: 0, length: 0)
        textView.setMarkedText("ㄓ", selectedRange: NSRange(location: 1, length: 0), replacementRange: .notFound)
        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertFalse(EditorTextElementCacheTrimmer.trim(NSRange(location: 1500, length: 100), in: textView))
        textView.unmarkText()
        XCTAssertTrue(EditorTextElementCacheTrimmer.trim(NSRange(location: 1500, length: 100), in: textView))
    }

    func testScheduledTrimRunsAfterTheViewportSettlesAndRestartsOnChange() async throws {
        let textView = try makeTextView(String(repeating: "line of text\n", count: 20000)).textView
        let trimmer = EditorTextElementCacheTrimmer()
        var allowed = false
        trimmer.visibleRangeDidChange(NSRange(location: 0, length: 1000), in: textView) { allowed }
        try await Task.sleep(nanoseconds: EditorTextElementCacheTrimmer.settleNanoseconds + 200_000_000)
        XCTAssertEqual(trimmer.trimmedLength, 0, "a refused trim must stop without releasing anything")

        allowed = true
        trimmer.visibleRangeDidChange(NSRange(location: 0, length: 1000), in: textView) { allowed }
        try await Task.sleep(nanoseconds: EditorTextElementCacheTrimmer.settleNanoseconds / 2)
        trimmer.visibleRangeDidChange(NSRange(location: 0, length: 1000), in: textView) { allowed }
        XCTAssertEqual(trimmer.trimmedLength, 0)
        let storageLength = try XCTUnwrap(MarkdownTextView.textStorage(of: textView)?.length)
        let expected = storageLength - 1000 - 8192
        // Chunks yield between run-loop turns, so the release completes over several.
        let deadline = Date().addingTimeInterval(5)
        while trimmer.trimmedLength < expected, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(trimmer.trimmedLength, expected)
    }

    private func document() -> String {
        (1 ... 24000).map { "Paragraph \($0) with **bold** text and 中文.\n" }.joined()
    }

    private func makeTextView(_ text: String) throws -> (scrollView: NSScrollView, textView: MarkdownSTTextView) {
        let frame = NSRect(x: 0, y: 0, width: 700, height: 800)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.isEditable = true
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.orderFront(nil)
        windows.append(window)
        textView.text = text
        textView.undoManager?.removeAllActions()
        textView.layoutSubtreeIfNeeded()
        return (scrollView, textView)
    }

    private func jumpToEndAndBack(_ scrollView: NSScrollView, _ textView: MarkdownSTTextView) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, textView.frame.height - 800)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.layoutSubtreeIfNeeded()
        let middle = (MarkdownTextView.textStorage(of: textView)?.length ?? 0) / 2
        textView.textSelection = NSRange(location: middle, length: 0)
        textView.scrollRangeToVisible(NSRange(location: middle, length: 0))
        textView.layoutSubtreeIfNeeded()
    }

    private func visibleRange(_ textView: STTextView) throws -> NSRange {
        try XCTUnwrap(MarkdownTextView.visibleTextRange(of: textView))
    }

    private func trimAll(below visible: NSRange, in textView: STTextView) {
        var end = MarkdownTextView.textStorage(of: textView)?.length ?? 0
        while let chunk = EditorTextElementCacheTrimmer.nextChunk(below: visible, endingAt: end, in: textView) {
            XCTAssertTrue(EditorTextElementCacheTrimmer.trim(chunk, in: textView))
            end = chunk.location
        }
    }

    private func medianInsertMilliseconds(_ textView: STTextView) -> Double {
        var samples: [Double] = []
        for _ in 0 ..< 9 {
            let start = DispatchTime.now().uptimeNanoseconds
            textView.insertText("a", replacementRange: textView.selectedRange())
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            textView.layoutSubtreeIfNeeded()
        }
        return samples.sorted()[samples.count / 2]
    }
}
