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
        let visible = try visibleRange(textView)
        var allowed = false
        trimmer.visibleRangeDidChange(visible, in: textView) { allowed }
        try await Task.sleep(nanoseconds: EditorTextElementCacheTrimmer.settleNanoseconds + 200_000_000)
        XCTAssertEqual(trimmer.trimmedLength, 0, "a refused trim must stop without releasing anything")

        allowed = true
        trimmer.visibleRangeDidChange(visible, in: textView) { allowed }
        try await Task.sleep(nanoseconds: EditorTextElementCacheTrimmer.settleNanoseconds / 2)
        trimmer.visibleRangeDidChange(visible, in: textView) { allowed }
        XCTAssertEqual(trimmer.trimmedLength, 0)
        let storageLength = try XCTUnwrap(MarkdownTextView.textStorage(of: textView)?.length)
        let expected = storageLength - NSMaxRange(visible) - max(visible.length, 8192)
        // Chunks yield between run-loop turns, so the release completes over several.
        let deadline = Date().addingTimeInterval(5)
        while trimmer.trimmedLength < expected, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(trimmer.trimmedLength, expected)
    }

    func testScheduledTrimProtectsNewViewportAndCaretAfterSixteenthChunk() async throws {
        let source = String(repeating: "line of text\n", count: 90000)
        let textView = try makeTextView(source).textView
        textView.textSelection = NSRange(location: 0, length: 0)
        let capturedViewport = try visibleRange(textView)
        let destination = (source as NSString).lineRange(for: NSRange(location: source.utf16.count / 2, length: 0))
        let trimmer = EditorTextElementCacheTrimmer()
        defer { trimmer.cancel() }
        var released: [NSRange] = []
        var stopped = false
        var navigatedViewport: NSRange?
        trimmer.probeHandler = { event, range in
            if event == "trimmed", let range {
                released.append(range)
                if released.count == 16 {
                    // Keep the task's original top capture while native navigation
                    // installs a new viewport and caret between production chunks.
                    textView.textSelection = NSRange(location: destination.location, length: 0)
                    textView.scrollRangeToVisible(textView.selectedRange())
                    textView.layoutSubtreeIfNeeded()
                    navigatedViewport = MarkdownTextView.visibleTextRange(of: textView)
                }
            }
            if event == "complete" || event == "refused" {
                stopped = true
            }
        }
        trimmer.visibleRangeDidChange(capturedViewport, in: textView) { true }
        let deadline = Date().addingTimeInterval(5)
        while !stopped, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(stopped)
        let viewport = try XCTUnwrap(navigatedViewport)
        XCTAssertGreaterThanOrEqual(released.count, 16, "navigation must occur after sixteen real chunks")
        let protectedSelection = try selectionProtection(in: textView)
        let keepEnd = NSMaxRange(viewport) + max(viewport.length, 8192)
        for range in released.dropFirst(16) {
            XCTAssertGreaterThanOrEqual(range.location, keepEnd)
            XCTAssertEqual(NSIntersectionRange(range, protectedSelection).length, 0)
            XCTAssertLessThanOrEqual(range.length, EditorTextElementCacheTrimmer.chunkLength)
        }
        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.string, source)
        XCTAssertEqual(textView.selectedRange().location, destination.location)
    }

    func testScheduledTrimRechecksCaretProtectionBetweenChunks() async throws {
        let source = String(repeating: "line of text\n", count: 20000)
        let textView = try makeTextView(source).textView
        textView.textSelection = NSRange(location: 0, length: 0)
        let capturedViewport = try visibleRange(textView)
        let destination = source.utf16.count - EditorTextElementCacheTrimmer.chunkLength - 16384
        let trimmer = EditorTextElementCacheTrimmer()
        defer { trimmer.cancel() }
        var admissions = 0
        var released: [NSRange] = []
        var stopped = false
        trimmer.probeHandler = { event, range in
            if event == "trimmed", let range {
                released.append(range)
            }
            if event == "complete" || event == "refused" {
                stopped = true
            }
        }
        trimmer.visibleRangeDidChange(capturedViewport, in: textView) {
            admissions += 1
            if admissions == 2 {
                // Leave the viewport at the top: the moved caret must independently
                // protect input whose viewport notification has not arrived yet.
                textView.textSelection = NSRange(location: destination, length: 0)
            }
            return true
        }
        let deadline = Date().addingTimeInterval(5)
        while !stopped, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(stopped)
        XCTAssertGreaterThan(admissions, 2)
        XCTAssertGreaterThan(released.count, 2, "the pass must continue on both safe sides of the moved caret")
        let protectedSelection = try selectionProtection(in: textView)
        for range in released {
            XCTAssertEqual(NSIntersectionRange(range, protectedSelection).length, 0)
            XCTAssertLessThanOrEqual(range.length, EditorTextElementCacheTrimmer.chunkLength)
        }
        XCTAssertTrue(released.contains { $0.location == NSMaxRange(protectedSelection) },
                      "retain the safe suffix above the selected-paragraph band")
        XCTAssertTrue(released.contains { NSMaxRange($0) == protectedSelection.location },
                      "continue with a preceding chunk after skipping the selected-paragraph band")
        XCTAssertEqual(textView.selectedRange().location, destination)
    }

    func testScheduledTrimStillReleasesMiddleTextWithAnOldOffscreenEndCaret() async throws {
        let source = String(repeating: "line of text\n", count: 20000) + "last caret paragraph"
        let (scrollView, textView) = try makeTextView(source)
        let length = source.utf16.count
        textView.textSelection = NSRange(location: length, length: 0)
        textView.scrollRangeToVisible(textView.selectedRange())
        textView.layoutSubtreeIfNeeded()
        // Manual scrolling leaves the insertion point at the end. Its local protected
        // band must not prevent the settled top viewport from releasing the middle.
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.layoutSubtreeIfNeeded()
        let visible = try visibleRange(textView)
        let keepEnd = NSMaxRange(visible) + max(visible.length, 8192)
        let protectedSelection = try selectionProtection(in: textView)
        XCTAssertLessThan(keepEnd, length / 2)
        XCTAssertEqual(textView.selectedRange().location, length)
        let trimmer = EditorTextElementCacheTrimmer()
        defer { trimmer.cancel() }
        var released: [NSRange] = []
        var stopped = false
        trimmer.probeHandler = { event, range in
            if event == "trimmed", let range {
                released.append(range)
            }
            if event == "complete" || event == "refused" {
                stopped = true
            }
        }
        trimmer.visibleRangeDidChange(visible, in: textView) { true }
        let deadline = Date().addingTimeInterval(5)
        while !stopped, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(stopped)
        XCTAssertEqual(trimmer.trimmedLength, protectedSelection.location - keepEnd)
        XCTAssertTrue(released.contains { NSLocationInRange(length / 2, $0) }, "the cached middle must be released")
        for range in released {
            XCTAssertGreaterThanOrEqual(range.location, keepEnd)
            XCTAssertEqual(NSIntersectionRange(range, protectedSelection).length, 0)
            XCTAssertLessThanOrEqual(range.length, EditorTextElementCacheTrimmer.chunkLength)
        }
        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.string, source)
        XCTAssertEqual(textView.selectedRange().location, length)
    }

    func testAdmissionProtectsWholeLongParagraphAndKeepsSafeTextOnBothSides() throws {
        let prefix = String(repeating: "line of text\n", count: 2000)
        let paragraph = String(repeating: "x", count: 70000) + "\n"
        let source = prefix + paragraph + String(repeating: "line of text\n", count: 4000)
        let textView = try makeTextView(source).textView
        textView.textSelection = NSRange(location: prefix.utf16.count + 1000, length: 0)
        let protectedSelection = try selectionProtection(in: textView)
        XCTAssertEqual(protectedSelection.location, prefix.utf16.count - 8192)
        XCTAssertEqual(protectedSelection.length, paragraph.utf16.count + 16384)

        // This range lies inside the paragraph, far beyond a caret-only 8192 margin.
        let candidate = NSRange(location: prefix.utf16.count + paragraph.utf16.count - 20000, length: 20000)
        let preceding = try XCTUnwrap(EditorTextElementCacheTrimmer.protectedChunk(candidate, in: textView))
        XCTAssertEqual(NSMaxRange(preceding), protectedSelection.location)
        XCTAssertEqual(NSIntersectionRange(preceding, protectedSelection).length, 0)
        XCTAssertLessThanOrEqual(preceding.length, EditorTextElementCacheTrimmer.chunkLength)

        let end = NSMaxRange(protectedSelection) + 4000
        let suffix = try XCTUnwrap(EditorTextElementCacheTrimmer.protectedChunk(
            NSRange(location: end - EditorTextElementCacheTrimmer.chunkLength,
                    length: EditorTextElementCacheTrimmer.chunkLength),
            in: textView
        ))
        XCTAssertEqual(suffix, NSRange(location: NSMaxRange(protectedSelection), length: 4000))
    }

    func testScheduledTrimRefusesAnUnlaidOutViewportCreatedDuringAdmission() async throws {
        let source = String(repeating: "line of text\n", count: 20000)
        let textView = try makeTextView(source).textView
        textView.textSelection = NSRange(location: 0, length: 0)
        let capturedViewport = try visibleRange(textView)
        XCTAssertGreaterThan(capturedViewport.length, 0, "the scheduled capture must be laid out")
        let contentManager = textView.textContentManager
        let destination = try XCTUnwrap(contentManager.location(
            contentManager.documentRange.location, offsetBy: source.utf16.count / 2
        ))
        let controller = textView.textLayoutManager.textViewportLayoutController
        let trimmer = EditorTextElementCacheTrimmer()
        defer { trimmer.cancel() }
        var admissions = 0
        var released: [NSRange] = []
        var refused = false
        var stopped = false
        trimmer.probeHandler = { event, range in
            if event == "trimmed", let range {
                released.append(range)
            }
            if event == "refused" {
                refused = true
            }
            if event == "complete" || event == "refused" {
                stopped = true
            }
        }
        trimmer.visibleRangeDidChange(capturedViewport, in: textView) {
            admissions += 1
            // The input callback is allowed to change native layout state. Re-reading
            // the real viewport after it returns must reject this unlaid-out anchor;
            // the visible-range helper's selection fallback is not a substitute.
            _ = controller.relocateViewport(to: destination)
            XCTAssertTrue(controller.viewportRange?.isEmpty == true)
            return true
        }
        let deadline = Date().addingTimeInterval(5)
        while !stopped, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(stopped)
        XCTAssertTrue(refused)
        XCTAssertEqual(admissions, 1)
        XCTAssertEqual(released, [])
        XCTAssertEqual(trimmer.trimmedLength, 0)
        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.string, source)
        XCTAssertEqual(textView.selectedRange().location, 0)
    }

    private func document() -> String {
        (1 ... 24000).map { "Paragraph \($0) with **bold** text and 中文.\n" }.joined()
    }

    private func selectionProtection(in textView: STTextView) throws -> NSRange {
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: textView))
        let paragraphs = storage.mutableString.paragraphRange(for: textView.selectedRange())
        let start = max(0, paragraphs.location - 8192)
        let end = min(storage.length, NSMaxRange(paragraphs) + 8192)
        return NSRange(location: start, length: end - start)
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
