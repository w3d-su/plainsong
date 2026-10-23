import AppKit
@testable import EditorKit
import MarkdownCore
import XCTest

/// B10, L8 and I8 time the fold recompute over one paragraph. Production requests the
/// native viewport, which STTextView 2.4 (#180) extends up to half a screen above the
/// visible area, padded by `EditorHighlightViewport.padded`. This gate times the shipped
/// link-folding presentation over that real request range for a laid-out 1200 x 800
/// editor on the 1 MB fixture, against the same agent.md §12 50 ms highlight budget.
@MainActor
final class WYSIWYGViewportPerformanceGateTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows.removeAll()
        super.tearDown()
    }

    func testFoldRecomputeOverTheProductionViewportRequestStaysUnderFiftyMilliseconds() async throws {
        let fixture = try String(contentsOf: Self.repoRoot.appending(path: "Fixtures/large-1mb.md"))
        let storage = fixture as NSString
        let secondHalf = NSRange(location: storage.length / 2, length: storage.length - storage.length / 2)
        let editLocation = storage.range(of: "ordinary prose", options: [], range: secondHalf).location
        XCTAssertNotEqual(editLocation, NSNotFound)
        let requestRange = try productionRequestRange(in: fixture, caret: editLocation)
        // A one-screen 1200 x 800 viewport of this fixture is several thousand UTF-16 units;
        // a paragraph-sized range would repeat the B10/L8 measurement.
        XCTAssertGreaterThan(requestRange.length, 4096)

        let highlightService = MarkdownHighlightService()
        _ = try await measure(fixture, requestRange, editLocation, highlightService)
        var samples: [Double] = []
        var highlightedLength = 0
        for _ in 0 ..< 3 {
            let result = try await measure(fixture, requestRange, editLocation, highlightService)
            XCTAssertTrue(result.didApplyHighlight)
            XCTAssertEqual(result.selectionAfterApply.location, editLocation + "measured ".utf16.count)
            highlightedLength = result.highlightedRange.length
            samples.append(result.elapsedMilliseconds)
        }

        let maximum = try XCTUnwrap(samples.max())
        print(String(
            format: "WYSIWYG production-viewport fold highlight/apply max: %.3f ms samples %@ " +
                "request %ld highlighted %ld UTF-16",
            maximum,
            samples.map { String(format: "%.3f", $0) }.description,
            requestRange.length,
            highlightedLength
        ))
        assertPerformanceBudget(
            maximum,
            lessThanOrEqualTo: 50,
            metric: "WYSIWYG production-viewport fold highlight/apply"
        )
    }
}

private extension WYSIWYGViewportPerformanceGateTests {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The range `MarkdownEditorView` requests after a WYSIWYG editor scrolls to `caret`.
    func productionRequestRange(in text: String, caret: Int) throws -> NSRange {
        let frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.orderFront(nil)
        windows.append(window)
        textView.text = text
        XCTAssertTrue(textView.setWYSIWYGZeroWidthFoldingEnabled(true))
        let selection = NSRange(location: caret, length: 0)
        textView.textSelection = selection
        // Each scroll corrects TextKit's estimate of the unlaid text above the caret.
        var visibleRange = NSRange(location: NSNotFound, length: 0)
        for _ in 0 ..< 8 where !NSLocationInRange(caret, visibleRange) {
            textView.scrollRangeToVisible(selection)
            textView.layoutSubtreeIfNeeded()
            visibleRange = try XCTUnwrap(MarkdownTextView.visibleTextRange(of: textView))
        }
        XCTAssertTrue(NSLocationInRange(caret, visibleRange), "viewport \(visibleRange) caret \(caret)")
        return MarkdownEditorView.highlightRequestRange(visibleRange: visibleRange, selection: selection)
    }

    func measure(
        _ fixture: String,
        _ requestRange: NSRange,
        _ editLocation: Int,
        _ highlightService: MarkdownHighlightService
    ) async throws -> EditorPerformanceProbe.VisibleRangeHighlightUpdateResult {
        try await EditorPerformanceProbe.measureVisibleRangeHighlightUpdate(
            fixtureText: fixture,
            fileKind: .markdown,
            visibleRange: requestRange,
            editLocation: editLocation,
            insertion: "measured ",
            developmentPresentation: .inlineFoldRevealWithLinkFolding,
            highlightService: highlightService
        )
    }
}
