import Foundation
import MarkdownCore
@testable import PreviewKit
import XCTest

/// The diagnostics-only render timing, driven through the bridge transport seam.
@MainActor
final class PreviewRenderTimingTests: XCTestCase {
    func testObserverReportsEachRenderJavaScriptCompleted() {
        let harness = RenderDispatchHarness(testCase: self)
        harness.markReady()
        var timings: [PreviewRenderTiming] = []
        harness.controller.renderTimingObserver = { timings.append($0) }

        let first = harness.controller.renderForTesting(change("one", version: 1))
        let replaced = harness.controller.renderForTesting(change("two", version: 2))
        let third = harness.controller.renderForTesting(change("three", version: 3))
        XCTAssertTrue(timings.isEmpty, "Nothing is reported before JavaScript answers")

        harness.complete(first)
        harness.complete(third)
        XCTAssertEqual(timings.map(\.renderID), [first, third])
        XCTAssertEqual(timings.map(\.version), [1, 3])
        XCTAssertFalse(timings.contains { $0.renderID == replaced }, "A replaced render is never sent")
        for timing in timings {
            XCTAssertGreaterThanOrEqual(timing.duration, 0)
        }
        XCTAssertLessThanOrEqual(timings[0].completedUptime, timings[1].sentUptime)
    }

    func testRenderSentBeforeTheObserverWasSetReportsNothing() {
        let harness = RenderDispatchHarness(testCase: self)
        harness.markReady()
        let early = harness.controller.renderForTesting(change("early", version: 1))
        XCTAssertNil(harness.controller.renderDispatch.inFlightSentUptime, "No clock read without an observer")

        var timings: [PreviewRenderTiming] = []
        harness.controller.renderTimingObserver = { timings.append($0) }
        harness.complete(early)
        XCTAssertTrue(timings.isEmpty)

        let next = harness.controller.renderForTesting(change("next", version: 2))
        harness.complete(next)
        XCTAssertEqual(timings.map(\.renderID), [next])
        XCTAssertNil(harness.controller.renderDispatch.inFlightSentUptime, "Settling clears the send time")
    }

    func testRepeatedCompletionReportsOnce() {
        let harness = RenderDispatchHarness(testCase: self)
        harness.markReady()
        var timings: [PreviewRenderTiming] = []
        harness.controller.renderTimingObserver = { timings.append($0) }
        let render = harness.controller.renderForTesting(change("one", version: 1))
        harness.complete(render)
        harness.complete(render)
        XCTAssertEqual(timings.count, 1)
    }

    private func change(_ text: String, version: Int) -> DocumentTextChange {
        DocumentTextChange(text: text, version: version, fileKind: .markdown, fileURL: nil)
    }
}
