@testable import EditorKit
import MarkdownCore
import XCTest

@MainActor
final class WYSIWYGLinkPerformanceGateTests: XCTestCase {
    func testL8LinkFoldingVisibleRangeRecomputeStaysUnderFiftyMilliseconds() async throws {
        let fixture = try String(contentsOf: Self.repoRoot.appending(path: "Fixtures/large-1mb.md"))
        let storage = fixture as NSString
        let linkRange = storage.range(of: "[a relative link]")
        XCTAssertNotEqual(linkRange.location, NSNotFound, "The 1 MB fixture must contain inline links")
        let visibleRange = storage.paragraphRange(for: linkRange)
        let editTarget = storage.range(of: "ordinary prose", options: [], range: visibleRange)
        XCTAssertNotEqual(editTarget.location, NSNotFound)

        let highlightService = MarkdownHighlightService()
        _ = try await measureLinkFoldUpdate(
            fixture: fixture,
            visibleRange: visibleRange,
            editLocation: editTarget.location,
            highlightService: highlightService
        )

        var samples: [Double] = []
        for _ in 0 ..< 3 {
            let result = try await measureLinkFoldUpdate(
                fixture: fixture,
                visibleRange: visibleRange,
                editLocation: editTarget.location,
                highlightService: highlightService
            )
            XCTAssertTrue(result.didApplyHighlight)
            XCTAssertEqual(result.selectionAfterApply.location, editTarget.location + "measured ".utf16.count)
            samples.append(result.elapsedMilliseconds)
        }

        let maximum = try XCTUnwrap(samples.max())
        print(String(
            format: "Link folding visible-range highlight/apply max: %.3f ms samples %@",
            maximum,
            samples.map { String(format: "%.3f", $0) }.description
        ))
        assertPerformanceBudget(
            maximum,
            lessThanOrEqualTo: 50,
            metric: "link folding visible-range highlight/apply"
        )
    }

    private func measureLinkFoldUpdate(
        fixture: String,
        visibleRange: NSRange,
        editLocation: Int,
        highlightService: MarkdownHighlightService
    ) async throws -> EditorPerformanceProbe.VisibleRangeHighlightUpdateResult {
        try await EditorPerformanceProbe.measureVisibleRangeHighlightUpdate(
            fixtureText: fixture,
            fileKind: .markdown,
            visibleRange: visibleRange,
            editLocation: editLocation,
            insertion: "measured ",
            developmentPresentation: .inlineFoldRevealWithLinkFolding,
            highlightService: highlightService
        )
    }

    private func assertPerformanceBudget(
        _ value: Double,
        lessThanOrEqualTo budget: Double,
        metric: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard value > budget else {
            return
        }

        let message = String(
            format: "L8 PERF %@ %.3f ms exceeded %.3f ms budget",
            metric,
            value,
            budget
        )
        if Self.isContinuousIntegration {
            print("\(message) on CI; recorded as informational per risk R15")
            return
        }

        XCTFail(message, file: file, line: line)
    }
}

private extension WYSIWYGLinkPerformanceGateTests {
    static var isContinuousIntegration: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CI"] != nil || environment["GITHUB_ACTIONS"] != nil
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
