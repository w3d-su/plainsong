import Foundation
import MarkdownCore
import WorkspaceKit
import XCTest

// Probes for the workspace-search resource ceilings: the global per-query match ceiling and
// dense whole-word rejection at the admission cap.

extension WorkspaceSearchPerformanceTests {
    // MARK: - Global 10,000-match ceiling

    /// Drives the global per-query ceiling for real: 24 files each holding one more than the
    /// per-file ceiling, so the first 20 files emit exactly 10,000 matches and the remaining four
    /// must be read and accounted without emitting a further result.
    func testGlobalMatchCeilingTruncatesAndDrainsRemainingCandidates() async throws {
        let fixture = try await makeGlobalCapFixture()
        defer { removeDirectory(fixture.rootURL) }

        let request = try makeRequest(
            capture: fixture.capture,
            rootIdentity: "ws4b-global-match-cap",
            query: TextSearchQuery(pattern: Self.token, caseSensitivity: .sensitive)
        )

        let run = try await collect(request: request)
        let results = fileResults(in: run.events)
        let summary = try XCTUnwrap(completedSummaries(in: run.events).first)

        // Only the files up to the ceiling emit results, in path order.
        XCTAssertEqual(
            results.map(\.relativePath),
            Array(fixture.orderedRelativePaths.prefix(Self.globalCapEmittingFileCount))
        )
        XCTAssertTrue(results.allSatisfy { $0.matches.count == Self.expectedMaximumMatchesPerFile })
        XCTAssertTrue(results.allSatisfy(\.isTruncated))

        // The ceiling is hit exactly, not overshot.
        XCTAssertEqual(summary.totalEmittedMatchCount, Self.expectedMaximumMatchesPerQuery)
        XCTAssertEqual(
            results.reduce(0) { $0 + $1.matches.count },
            Self.expectedMaximumMatchesPerQuery
        )
        XCTAssertTrue(summary.isGloballyTruncated)
        XCTAssertTrue(summary.isTruncated)

        // Accounting continues past the ceiling: every candidate is still read and counted.
        XCTAssertEqual(summary.candidateFileCount, Self.globalCapFileCount)
        XCTAssertEqual(summary.searchedFileCount, Self.globalCapFileCount)
        XCTAssertEqual(summary.skippedFileCount, 0)
        XCTAssertEqual(summary.ignoredFileCount, 0)
        XCTAssertEqual(summary.readInstrumentation.diskReadCount, Self.globalCapFileCount)
        XCTAssertEqual(summary.readInstrumentation.diskReadByteCount, fixture.totalByteCount)

        try assertSharedStreamInvariants(
            run.events,
            candidateFileCount: Self.globalCapFileCount,
            expectedFileResultCount: Self.globalCapEmittingFileCount,
            expectedSkippedEventCount: 0,
            label: "global match ceiling"
        )
    }

    func testDenseWholeWordRejectionAtTheAdmissionCapStaysWithinBudget() async throws {
        for shape in DenseWholeWordShape.allCases {
            try await measureDenseWholeWordRejection(shape: shape)
        }
    }

    private func measureDenseWholeWordRejection(shape: DenseWholeWordShape) async throws {
        let fixture = try await makeDenseWholeWordFixture(shape: shape)
        defer { removeDirectory(fixture.rootURL) }

        let request = try makeRequest(
            capture: fixture.capture,
            rootIdentity: "ws4b-dense-whole-word-\(shape.rawValue)",
            query: TextSearchQuery(
                pattern: fixture.pattern,
                caseSensitivity: .sensitive,
                wholeWord: true
            )
        )

        // Anti-vacuity check: the same pattern without whole-word matching finds many literal
        // hits in this file, so the whole-word run above is genuinely examining and rejecting
        // candidates rather than never finding any.
        let literalRequest = try makeRequest(
            capture: fixture.capture,
            rootIdentity: "ws4b-dense-literal-\(shape.rawValue)",
            query: TextSearchQuery(pattern: fixture.pattern, caseSensitivity: .sensitive)
        )
        let literalRun = try await collect(request: literalRequest)
        let literalResult = try XCTUnwrap(
            fileResults(in: literalRun.events).first,
            "\(shape.rawValue) literal control"
        )
        XCTAssertEqual(
            literalResult.matches.count,
            Self.expectedMaximumMatchesPerFile,
            "\(shape.rawValue) literal control"
        )
        XCTAssertTrue(literalResult.isTruncated, "\(shape.rawValue) literal control")
        try assertSharedStreamInvariants(
            literalRun.events,
            candidateFileCount: 1,
            expectedFileResultCount: 1,
            expectedSkippedEventCount: 0,
            label: "\(shape.rawValue) literal control"
        )

        let warmUp = try await collect(request: request)
        try assertDenseRejectionResults(warmUp.events, fixture: fixture, label: "\(shape.rawValue) warm-up")

        var samples: [Double] = []
        for attempt in 1 ... 3 {
            let run = try await collect(request: request)
            try assertDenseRejectionResults(
                run.events,
                fixture: fixture,
                label: "\(shape.rawValue) sample \(attempt)"
            )
            samples.append(run.elapsedMilliseconds)
        }

        let median = Self.median(samples)
        print(String(
            format: "WS4B PERF dense whole-word rejection (%@) %d-byte file median %.3f ms samples %@",
            shape.rawValue,
            Self.admittedFileByteCount,
            median,
            Self.formatSamples(samples)
        ))
        assertSearchBudget(
            median,
            lessThan: shape.budgetMilliseconds,
            metric: "dense whole-word rejection (\(shape.rawValue)) \(Self.admittedFileByteCount)-byte file median"
        )
    }
}
