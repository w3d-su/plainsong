import AppKit
@testable import EditorKit
import MarkdownCore
import XCTest

@MainActor
extension PerformanceBudgetTests {
    struct DocumentEndViewport {
        let label: String
        let visibleRange: NSRange
        let editLocation: Int
        /// Where the highlighted range must start: the viewport's first line, or the
        /// opening fence line when the viewport starts inside fenced code.
        let expectedHighlightStart: Int
    }

    /// The viewport at the end of `large-1mb.md`: the fence-context scan has to read the
    /// whole document before it, where the original gate probes near line 17. One
    /// viewport sits on prose, one starts inside the last fenced block.
    func testVisibleRangeHighlightUpdateAtTheEndOfLargeMarkdownStaysUnderBudget() async throws {
        let markdown = try Self.fixtureText("Fixtures/large-1mb.md")
        let source = markdown as NSString
        let proseRange = try Self.visibleRange(in: markdown, around: "[a relative link](./section-01274.md)")
        let proseLineStart = source.lineRange(for: NSRange(location: proseRange.location, length: 0)).location
        let codeLine = try Self.location(in: markdown, of: "let title = \"Section 01274\"")
        let viewports = try [
            DocumentEndViewport(
                label: "prose",
                visibleRange: proseRange,
                editLocation: Self.location(in: markdown, of: "Task item for section 01274"),
                expectedHighlightStart: proseLineStart
            ),
            DocumentEndViewport(
                label: "fenced code",
                visibleRange: NSRange(location: codeLine, length: min(6000, source.length - codeLine)),
                editLocation: codeLine,
                expectedHighlightStart: Self.location(in: markdown, of: "```swift\nstruct FixtureSection01274")
            ),
        ]

        let highlightService = MarkdownHighlightService()
        for viewport in viewports {
            let samples = try await measureDocumentEndHighlight(
                markdown,
                viewport: viewport,
                highlightService: highlightService
            )
            let maximum = samples.max() ?? 0
            print(String(
                format: "M5 PERF visible highlight markdown 1MB end %@ max %.3f ms samples %@",
                viewport.label,
                maximum,
                Self.formatSamples(samples)
            ))
            assertPerformanceBudget(
                maximum,
                lessThan: Self.visibleRangeHighlightBudgetMilliseconds,
                metric: "visible highlight markdown 1MB end \(viewport.label) max",
                isInformationalOnCI: true
            )
        }
    }

    private func measureDocumentEndHighlight(
        _ markdown: String,
        viewport: DocumentEndViewport,
        highlightService: MarkdownHighlightService
    ) async throws -> [Double] {
        _ = try await EditorPerformanceProbe.measureVisibleRangeHighlightUpdate(
            fixtureText: markdown,
            fileKind: .markdown,
            visibleRange: viewport.visibleRange,
            editLocation: viewport.editLocation,
            insertion: "warm ",
            highlightService: highlightService
        )

        return try await withSignpost("VisibleRangeHighlightMarkdown1MBEnd") {
            var samples: [Double] = []
            for attempt in 1 ... 3 {
                let result = try await EditorPerformanceProbe.measureVisibleRangeHighlightUpdate(
                    fixtureText: markdown,
                    fileKind: .markdown,
                    visibleRange: viewport.visibleRange,
                    editLocation: viewport.editLocation,
                    insertion: "e\(attempt)",
                    highlightService: highlightService
                )
                let context = "\(viewport.label) attempt \(attempt)"
                XCTAssertTrue(result.didApplyHighlight, context)
                XCTAssertEqual(result.selectionAfterApply.location, viewport.editLocation + 2, context)
                XCTAssertEqual(result.highlightedRange.location, viewport.expectedHighlightStart, context)
                samples.append(result.elapsedMilliseconds)
            }
            return samples
        }
    }
}
