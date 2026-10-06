import AppKit
@testable import EditorKit
import MarkdownCore
import XCTest

@MainActor
final class EditorReplaceWYSIWYGPerformanceTests: XCTestCase {
    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    /// Measure real native insertion with WYSIWYG installed, not a source-mode proposal.
    /// This also covers publication/selection callbacks; debounced parsing stays off-main.
    func testLargeFixtureWYSIWYGTypingWithAppliedReplaceSnapshotStaysUnderBudget() async throws {
        let source = try String(contentsOf: EditorReplaceBatchSpikeSupport.repoRoot
            .appendingPathComponent("Fixtures/large-1mb.md"))
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: source, enableWYSIWYG: true)
        let service = MarkdownHighlightService()
        let highlighted = await service.highlight(source, fileKind: .markdown,
                                                  visibleRange: NSRange(location: 0, length: 2048), theme: .standard,
                                                  fontName: MarkdownSyntaxHighlighter.systemMonospacedFontName,
                                                  fontSize: MarkdownSyntaxHighlighter.defaultFont.pointSize,
                                                  developmentPresentation: .inlineFoldRevealWithLinkFolding,
                                                  selection: NSRange(location: 0, length: 0))
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(
            HighlightedText(
                revision: 1,
                range: highlighted.range,
                text: highlighted.text,
                foldPlan: highlighted.foldPlan
            ),
            to: fixture.textView
        ))
        XCTAssertNotNil(fixture.textView.replacePresentationSnapshot)
        var samples: [Double] = []
        for _ in 0 ..< 30 {
            let before = fixture.model.revision
            let start = DispatchTime.now().uptimeNanoseconds
            fixture.textView.insertText("a", replacementRange: fixture.textView.selectedRange())
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertEqual(fixture.model.revision, before + 1)
        }
        let maximum = try XCTUnwrap(samples.max())
        print("Replace WYSIWYG native typing large-1mb.md ms: \(samples)")
        assertPerformanceBudget(maximum, lessThanOrEqualTo: 16, metric: "Replace WYSIWYG native typing")
    }
}
