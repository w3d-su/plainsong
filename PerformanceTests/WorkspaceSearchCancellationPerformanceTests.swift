import Foundation
import MarkdownCore
import WorkspaceKit
import XCTest

// Cancel-to-drain probe for a saturated read window.

extension WorkspaceSearchPerformanceTests {
    // MARK: - Rapid cancellation of a saturated read window

    func testRapidCancellationOfASaturatedReadWindowDrainsWithoutTerminalEvent() async throws {
        let fixture = try await makeBulkWorkspaceFixture()
        defer { removeDirectory(fixture.rootURL) }

        let readWindow = Self.expectedMaximumConcurrentReads
        var samples: [Double] = []

        for attempt in 1 ... 5 {
            let reader = BlockingSearchReader()
            let request = try makeRequest(
                capture: fixture.capture,
                rootIdentity: "ws4b-cancellation",
                query: TextSearchQuery(pattern: Self.token, caseSensitivity: .sensitive),
                queryGeneration: UInt64(attempt)
            )
            let service = WorkspaceSearchService(reader: reader)
            let consumer = Task {
                var events: [WorkspaceSearchEvent] = []
                for await event in service.events(for: request) {
                    events.append(event)
                }
                return events
            }

            // Every read blocks, so the producer saturates exactly the configured window.
            guard await reader.waitUntilStartCount(readWindow) else {
                let started = await reader.startCount()
                consumer.cancel()
                _ = await consumer.value
                return XCTFail(
                    """
                    attempt \(attempt): producer never saturated the \(readWindow)-read window \
                    (started \(started)); aborting instead of waiting out the job
                    """
                )
            }
            let startedBeforeCancellation = await reader.startCount()
            let cancelledAt = DispatchTime.now().uptimeNanoseconds
            consumer.cancel()
            let events = await consumer.value
            guard await reader.waitUntilNoActiveReads() else {
                let stillActive = await reader.activeReadCount()
                return XCTFail(
                    """
                    attempt \(attempt): \(stillActive) read(s) still active after cancellation; \
                    aborting instead of waiting out the job
                    """
                )
            }
            let drainMilliseconds = Self.milliseconds(since: cancelledAt)

            let activeReads = await reader.activeReadCount()
            let startCount = await reader.startCount()
            let cancelledReads = await reader.cancelledReadCount()

            XCTAssertEqual(startedBeforeCancellation, readWindow, "attempt \(attempt)")
            XCTAssertEqual(startCount, readWindow, "attempt \(attempt)")
            XCTAssertEqual(activeReads, 0, "attempt \(attempt)")
            XCTAssertEqual(cancelledReads, readWindow, "attempt \(attempt)")
            // Every read in this fixture blocks and none completes, so no plan item finishes:
            // there is no legitimate event of *any* kind, before or after the cancellation.
            // Asserting the stream is entirely silent covers progress, skipped files, and
            // validation failures too, which per-kind checks alone would let through.
            XCTAssertTrue(
                events.isEmpty,
                "attempt \(attempt): expected a silent stream, got \(events.count) event(s)"
            )
            XCTAssertTrue(completedSummaries(in: events).isEmpty, "attempt \(attempt)")
            XCTAssertTrue(failures(in: events).isEmpty, "attempt \(attempt)")
            XCTAssertEqual(terminalEventCount(in: events), 0, "attempt \(attempt)")
            XCTAssertTrue(fileResults(in: events).isEmpty, "attempt \(attempt)")
            samples.append(drainMilliseconds)
        }

        let median = Self.median(samples)
        print(String(
            format: "WS4B PERF cancellation drain median %.3f ms samples %@",
            median,
            Self.formatSamples(samples)
        ))
        assertSearchBudget(
            median,
            lessThan: Self.cancellationDrainBudgetMilliseconds,
            metric: "cancellation drain median"
        )
    }
}
