import Foundation
import MarkdownCore
import WorkspaceKit
import XCTest

// Assertion helpers shared by the WS4B workspace-search performance probes.

extension WorkspaceSearchPerformanceTests {
    func assertBulkResults(
        _ events: [WorkspaceSearchEvent],
        fixture: BulkWorkspaceFixture,
        label: String
    ) throws {
        let results = fileResults(in: events)
        let summary = try XCTUnwrap(completedSummaries(in: events).first, label)
        let expectedMatchCount = fixture.matchingRelativePaths.count * Self.matchesPerMatchingFile

        XCTAssertEqual(results.map(\.relativePath), fixture.matchingRelativePaths, label)
        XCTAssertTrue(
            results.allSatisfy { $0.matches.map(\.range) == fixture.expectedMatchRanges },
            label
        )
        XCTAssertTrue(results.allSatisfy { $0.matches.map(\.line) == [3, 24] }, label)
        XCTAssertTrue(results.allSatisfy { !$0.isTruncated }, label)
        XCTAssertTrue(results.allSatisfy { $0.fileAuthority != nil }, label)
        XCTAssertTrue(
            results.allSatisfy { result in
                result.matches.allSatisfy { match in
                    (match.preview as NSString).length <= Self.previewUTF16Bound(for: match)
                        && (match.preview as NSString)
                        .substring(with: match.previewMatchRange) == Self.token
                }
            },
            label
        )

        XCTAssertEqual(fixture.orderedRelativePaths.count, Self.bulkFileCount, label)
        XCTAssertEqual(summary.candidateFileCount, fixture.orderedRelativePaths.count, label)
        XCTAssertEqual(summary.searchedFileCount, fixture.orderedRelativePaths.count, label)
        XCTAssertEqual(summary.skippedFileCount, 0, label)
        XCTAssertEqual(summary.ignoredFileCount, 0, label)
        XCTAssertEqual(summary.totalEmittedMatchCount, expectedMatchCount, label)
        XCTAssertFalse(summary.isTruncated, label)
        XCTAssertEqual(summary.omittedSkippedFileCount, 0, label)

        XCTAssertEqual(summary.readInstrumentation.diskReadCount, Self.bulkFileCount, label)
        XCTAssertEqual(summary.readInstrumentation.diskReadByteCount, fixture.totalByteCount, label)
        // 2,000 candidates genuinely saturate the window, so here the ceiling is reached exactly
        // rather than merely respected. Buffering behind an earlier path is completion-order
        // dependent, so only its ceiling is contractual (asserted in the shared invariants).
        XCTAssertEqual(
            summary.readInstrumentation.maximumConcurrentReads,
            Self.expectedMaximumConcurrentReads,
            label
        )
        XCTAssertEqual(
            summary.readInstrumentation.maximumOutstandingReadCount,
            Self.expectedMaximumConcurrentReads,
            label
        )

        // This fixture must stay clear of the global ceiling; the ceiling itself is driven by
        // `testGlobalMatchCeilingTruncatesAndDrainsRemainingCandidates`.
        XCTAssertLessThan(expectedMatchCount, Self.expectedMaximumMatchesPerQuery, label)
        XCTAssertTrue(
            results.allSatisfy { $0.matches.count <= Self.expectedMaximumMatchesPerFile },
            label
        )

        try assertSharedStreamInvariants(
            events,
            candidateFileCount: Self.bulkFileCount,
            expectedFileResultCount: fixture.matchingRelativePaths.count,
            expectedSkippedEventCount: 0,
            label: label
        )
    }

    /// Stream-shape invariants that must hold for **every** probe in this file, not just the bulk
    /// one: an exactly precomputable event count, monotonic progress ending at `N / N`, read-window
    /// ceilings, the skipped-detail cap, and completion as the final event. Each probe still
    /// asserts its own content (paths, ranges, lines, byte accounting) separately.
    func assertSharedStreamInvariants(
        _ events: [WorkspaceSearchEvent],
        candidateFileCount: Int,
        expectedFileResultCount: Int,
        expectedSkippedEventCount: Int,
        label: String
    ) throws {
        let summary = try XCTUnwrap(completedSummaries(in: events).first, label)
        let progress = progressEvents(in: events)
        let expectedProgressEventCount = Self.expectedProgressEventCount(
            candidateFileCount: candidateFileCount
        )

        XCTAssertEqual(fileResults(in: events).count, expectedFileResultCount, label)
        XCTAssertEqual(skippedFiles(in: events).count, expectedSkippedEventCount, label)

        // The whole coalesced sequence is compared, not just its length, the fact that it rises,
        // and its final value. Those three hold for many wrong sequences — a stride of 1 capped at
        // 100 events, or an off-by-one stride, satisfies all of them on the shapes used here.
        XCTAssertEqual(
            progress,
            Self.expectedProgressSequence(candidateFileCount: candidateFileCount),
            label
        )
        XCTAssertEqual(progress.count, expectedProgressEventCount, label)
        XCTAssertLessThanOrEqual(progress.count, Self.expectedMaximumProgressEvents, label)

        XCTAssertLessThanOrEqual(
            summary.readInstrumentation.maximumConcurrentReads,
            Self.expectedMaximumConcurrentReads,
            label
        )
        XCTAssertLessThanOrEqual(
            summary.readInstrumentation.maximumOutstandingReadCount,
            Self.expectedMaximumConcurrentReads,
            label
        )
        XCTAssertLessThanOrEqual(
            summary.readInstrumentation.maximumBufferedReadCount,
            Self.expectedMaximumConcurrentReads,
            label
        )
        XCTAssertLessThanOrEqual(
            summary.skippedFiles.count,
            Self.expectedMaximumReportedSkippedFiles,
            label
        )

        XCTAssertEqual(
            events.count,
            expectedFileResultCount + expectedSkippedEventCount + expectedProgressEventCount + 1,
            label
        )
        XCTAssertEqual(terminalEventCount(in: events), 1, label)
        guard let lastEvent = events.last, case .completed = lastEvent else {
            return XCTFail("\(label): completion must be the final event")
        }
    }

    /// Mirrors the production coalescing rule: stride `ceil(N / M)` with a final value, so the
    /// stream never exceeds `M` progress events regardless of workspace size.
    static func expectedProgressEventCount(candidateFileCount: Int) -> Int {
        expectedProgressSequence(candidateFileCount: candidateFileCount).count
    }

    /// The exact progress sequence production must emit: every multiple of the stride in
    /// `1 ... N`, plus a final `N / N` when `N` is not itself a multiple. Rebuilt here from the
    /// documented rule rather than read back from the stream, so a stride regression changes the
    /// observed sequence without changing the expectation.
    static func expectedProgressSequence(candidateFileCount: Int) -> [WorkspaceSearchProgress] {
        guard candidateFileCount > 0 else { return [] }
        let cap = expectedMaximumProgressEvents
        let stride = max(1, (candidateFileCount + cap - 1) / cap)
        var completed = stride
        var sequence: [Int] = []
        while completed < candidateFileCount {
            sequence.append(completed)
            completed += stride
        }
        sequence.append(candidateFileCount)
        return sequence.map {
            WorkspaceSearchProgress(completedFileCount: $0, candidateFileCount: candidateFileCount)
        }
    }

    func assertAdmittedFileResults(
        _ events: [WorkspaceSearchEvent],
        fixture: SingleFileFixture,
        label: String
    ) throws {
        let results = fileResults(in: events)
        let summary = try XCTUnwrap(completedSummaries(in: events).first, label)
        let result = try XCTUnwrap(results.first, label)
        let match = try XCTUnwrap(result.matches.first, label)

        XCTAssertEqual(results.count, 1, label)
        XCTAssertEqual(result.relativePath, fixture.relativePath, label)
        XCTAssertEqual(result.matches.count, 1, label)
        XCTAssertEqual(match.range, fixture.expectedMatchRange, label)
        XCTAssertEqual(match.line, fixture.expectedLine, label)
        XCTAssertEqual(
            (match.preview as NSString).substring(with: match.previewMatchRange),
            Self.token,
            label
        )
        XCTAssertLessThanOrEqual(
            (match.preview as NSString).length,
            Self.previewUTF16Bound(for: match),
            label
        )
        XCTAssertFalse(result.isTruncated, label)

        XCTAssertEqual(fixture.byteCount, Self.admittedFileByteCount, label)
        XCTAssertEqual(summary.candidateFileCount, 1, label)
        XCTAssertEqual(summary.searchedFileCount, 1, label)
        XCTAssertEqual(summary.skippedFileCount, 0, label)
        XCTAssertEqual(summary.totalEmittedMatchCount, 1, label)
        XCTAssertEqual(summary.readInstrumentation.diskReadCount, 1, label)
        XCTAssertEqual(
            summary.readInstrumentation.diskReadByteCount,
            Self.admittedFileByteCount,
            label
        )
        XCTAssertFalse(summary.isTruncated, label)
        XCTAssertEqual(summary.ignoredFileCount, 0, label)
        XCTAssertEqual(summary.omittedSkippedFileCount, 0, label)

        try assertSharedStreamInvariants(
            events,
            candidateFileCount: 1,
            expectedFileResultCount: 1,
            expectedSkippedEventCount: 0,
            label: label
        )
    }

    /// For a control that is expected to match nothing: proves the candidate was actually read and
    /// searched, rather than ignored, skipped, or never planned.
    ///
    /// "No results plus a clean completion" is satisfied just as well by a file the ignore policy
    /// removed, so a zero-result control that only checks stream shape cannot tell "searched and
    /// found nothing" from "never looked".
    func assertSearchedWithoutMatching(
        _ events: [WorkspaceSearchEvent],
        expectedDiskReadByteCount: Int,
        label: String
    ) throws {
        let summary = try XCTUnwrap(completedSummaries(in: events).first, label)

        XCTAssertTrue(fileResults(in: events).isEmpty, label)
        XCTAssertEqual(summary.totalEmittedMatchCount, 0, label)

        XCTAssertEqual(summary.candidateFileCount, 1, label)
        XCTAssertEqual(summary.searchedFileCount, 1, "\(label): the candidate must be searched")
        XCTAssertEqual(summary.ignoredFileCount, 0, "\(label): the candidate must not be ignored")
        XCTAssertEqual(summary.skippedFileCount, 0, "\(label): the candidate must not be skipped")
        XCTAssertEqual(summary.readInstrumentation.diskReadCount, 1, label)
        XCTAssertEqual(
            summary.readInstrumentation.diskReadByteCount,
            expectedDiskReadByteCount,
            "\(label): the whole candidate must have been read"
        )

        try assertSharedStreamInvariants(
            events,
            candidateFileCount: 1,
            expectedFileResultCount: 0,
            expectedSkippedEventCount: 0,
            label: label
        )
    }

    func assertSingleCJKMatch(
        _ events: [WorkspaceSearchEvent],
        fixture: SingleFileFixture,
        label: String
    ) throws {
        let summary = try XCTUnwrap(completedSummaries(in: events).first, label)
        let result = try XCTUnwrap(fileResults(in: events).first, label)
        let match = try XCTUnwrap(result.matches.first, label)

        XCTAssertEqual(result.relativePath, fixture.relativePath, label)
        XCTAssertEqual(result.matches.count, 1, label)
        XCTAssertEqual(match.range, fixture.expectedMatchRange, label)
        XCTAssertEqual(match.line, fixture.expectedLine, label)
        // The matched source text carries the upper-case suffix even though the pattern was
        // lower-case: that is the insensitive backend's fingerprint in the output.
        XCTAssertEqual(
            (match.preview as NSString).substring(with: match.previewMatchRange),
            Self.cjkCasedOccurrence,
            label
        )
        XCTAssertLessThanOrEqual(
            (match.preview as NSString).length,
            Self.previewUTF16Bound(for: match),
            label
        )
        XCTAssertFalse(result.isTruncated, label)

        XCTAssertEqual(summary.candidateFileCount, 1, label)
        XCTAssertEqual(summary.searchedFileCount, 1, label)
        XCTAssertEqual(summary.skippedFileCount, 0, label)
        XCTAssertEqual(summary.totalEmittedMatchCount, 1, label)
        XCTAssertFalse(summary.isTruncated, label)
        XCTAssertEqual(summary.readInstrumentation.diskReadCount, 1, label)
        XCTAssertEqual(
            summary.readInstrumentation.diskReadByteCount,
            Self.admittedFileByteCount,
            label
        )

        try assertSharedStreamInvariants(
            events,
            candidateFileCount: 1,
            expectedFileResultCount: 1,
            expectedSkippedEventCount: 0,
            label: label
        )
    }

    func assertDenseRejectionResults(
        _ events: [WorkspaceSearchEvent],
        fixture: DenseWholeWordFixture,
        label: String
    ) throws {
        let summary = try XCTUnwrap(completedSummaries(in: events).first, label)

        XCTAssertTrue(fileResults(in: events).isEmpty, label)
        XCTAssertTrue(skippedFiles(in: events).isEmpty, label)
        XCTAssertEqual(summary.candidateFileCount, 1, label)
        XCTAssertEqual(summary.searchedFileCount, 1, label)
        XCTAssertEqual(summary.skippedFileCount, 0, label)
        XCTAssertEqual(summary.ignoredFileCount, 0, label)
        XCTAssertEqual(summary.totalEmittedMatchCount, 0, label)
        XCTAssertFalse(summary.isTruncated, label)
        XCTAssertEqual(summary.readInstrumentation.diskReadCount, 1, label)
        XCTAssertEqual(summary.readInstrumentation.diskReadByteCount, fixture.byteCount, label)

        try assertSharedStreamInvariants(
            events,
            candidateFileCount: 1,
            expectedFileResultCount: 0,
            expectedSkippedEventCount: 0,
            label: label
        )
    }

    static func previewUTF16Bound(for match: TextSearchMatch) -> Int {
        match.range.length
            + 2 * TextSearchEngine.maximumPreviewContextUTF16PerSide
            + 2 * (TextSearchEngine.previewEllipsis as NSString).length
    }
}
