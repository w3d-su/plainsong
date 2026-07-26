import Foundation
import MarkdownCore
import WorkspaceKit
import XCTest

/// Phase 3 WS4B production-shaped workspace-search performance gates.
///
/// Every probe drives the real `WorkspaceSearchService` over a real on-disk workspace. The
/// search probes use the production `WorkspaceSearchDiskFileReader`, so the measured cost
/// includes candidate planning, anchored no-follow reads, UTF-8 decoding, MarkdownCore
/// matching, and stream delivery. The cancellation probe is the one deliberate exception: it
/// substitutes a controlled reader that blocks every candidate read, because deterministic
/// cancellation needs a saturated read window that cannot finish on its own. Fixture creation
/// and workspace scanning are always performed before timing starts.
///
/// Wall-clock budgets are hard locally and informational on hosted CI (risk R15). Deterministic
/// results, exact summary/event accounting, read-window ceilings, and cancellation behavior
/// (every read released, no further read started, no terminal event) are hard assertions
/// everywhere, including CI; only the cancel-to-drain latency number follows the R15 rule.
///
/// Every run that reaches completion — measured sample, warm-up, and the dense-rejection literal
/// control alike — goes through `assertSharedStreamInvariants`, so the exact event count, progress
/// coalescing, read-window ceilings, skipped-detail cap, and completion ordering are checked on
/// all of them. The resource ceilings are pinned as literals in this file rather than read back
/// from `WorkspaceSearchLimits`; see `testProductionSearchLimitsStillMatchTheFrozenGateCeilings`.
///
/// Both case policies are covered. `.smart` is the UI default and resolves to the *insensitive*
/// backend for lowercase and CJK patterns, so it is a different comparison path from the
/// `.sensitive` probes here; see `WorkspaceSearchSmartCasePerformanceTests.swift`.
///
/// The probes are split across several files to stay near the ~400-line guidance in agent.md
/// §17.10: this file holds the class, the frozen constants, the ceiling pins, and the throughput
/// probes; `…SmartCase…`, `…Ceiling…`, and `…Cancellation…` hold the remaining probes;
/// `…Fixtures`, `…Assertions`, `…Support`, and `…BlockingReader` hold the shared machinery.
final class WorkspaceSearchPerformanceTests: XCTestCase {
    // MARK: - Frozen budgets

    // Budgets are frozen from the 2026-07-25 measurements recorded in `docs/perf-log.md`.
    // They must hold in the Debug configuration used by `make test`, which is roughly 2x
    // slower than Release on these paths, so each budget carries about 2-4x headroom over
    // the measured Debug median.

    /// Full 2,000-file workspace search. Debug median 1227 ms, Release median 714 ms.
    static let bulkWorkspaceBudgetMilliseconds = 3000.0
    /// One admitted 512 KiB file with the only match near EOF. Debug 39 ms, Release 8 ms.
    static let admittedFileBudgetMilliseconds = 150.0
    /// Cancel-to-drain latency for a saturated four-read window. Debug and Release < 0.3 ms.
    static let cancellationDrainBudgetMilliseconds = 50.0

    // The UI default is `.smart`, and `.smart` over a lowercase or CJK pattern resolves to the
    // *insensitive* backend — a different, more expensive Foundation comparison than the
    // `.sensitive` path the probes above measure. These budgets cover that default path and are
    // frozen from the 2026-07-26 Debug measurements recorded in `docs/perf-log.md`.

    /// Full 2,000-file workspace search under the default `.smart` case policy.
    /// Debug medians 1538.752, 1356.618, 1297.017 ms; budget is ~2.6x the slowest.
    static let bulkWorkspaceSmartCaseBudgetMilliseconds = 4000.0
    /// One admitted 512 KiB CJK file searched with a CJK pattern under `.smart`.
    /// Debug medians 34.729, 30.484, 28.548 ms; budget is ~4.3x the slowest.
    static let admittedCJKFileBudgetMilliseconds = 150.0

    // MARK: - Frozen production ceilings

    // The resource ceilings this gate measures against, pinned as literals instead of being read
    // back from `WorkspaceSearchLimits`. Deriving expectations from the production defaults makes
    // every bound below self-fulfilling: widening a default would silently widen the assertion
    // with it. `testProductionSearchLimitsStillMatchTheFrozenGateCeilings` is the single place
    // that compares these literals against production, so a deliberate limit change fails there
    // (one obvious, intentional edit) rather than passing everywhere unnoticed.

    static let expectedMaximumConcurrentReads = 4
    static let expectedMaximumProgressEvents = 100
    static let expectedMaximumReportedSkippedFiles = 100
    static let expectedMaximumMatchesPerFile = 500
    static let expectedMaximumMatchesPerQuery = 10000
    static let expectedMaximumFileSizeBytes = 524_288
    static let expectedMaximumIgnoreFiles = 128
    static let expectedMaximumIgnoreFileSizeBytes = 64 * 1024
    static let expectedMaximumPatternUTF16Length = 256
    static let expectedMaximumPreviewContextUTF16PerSide = 1024

    // MARK: - Fixture shape

    static let token = "plainsong-needle"
    static let titleCaseToken = "Plainsong-Needle"
    static let upperCaseToken = "PLAINSONG-NEEDLE"
    /// CJK has no cased characters, so `.smart` always resolves to insensitive matching for it.
    static let cjkToken = "平明歌"
    /// Pure CJK text matches identically under either backend, so it cannot by itself prove which
    /// backend `.smart` selected. These two differ only in the case of a trailing Latin letter:
    /// the pattern is all-lowercase (so `.smart` resolves insensitive and matches the occurrence)
    /// while `.sensitive` must find nothing. That difference is what makes the CJK probes
    /// falsifiable rather than merely non-empty.
    static let cjkCasedPattern = "平明歌x"
    static let cjkCasedOccurrence = "平明歌X"
    static let bulkFileCount = 2000
    static let bulkSectionCount = 20
    static let bulkMatchingStride = 4
    static let matchesPerMatchingFile = 2
    static let admittedFileByteCount = 524_288
    /// 8x the admission cap, so a bounded read and an unbounded one report different byte counts.
    static let oversizedFileByteCount = 8 * 524_288
    /// What a correctly bounded read of any oversized file contributes: `inclusiveLimit(cap)`.
    static let boundedOversizedReadByteCount = 524_289

    /// `WorkspaceAnchoredFileSystem.readAllBytes` reads in 64 KiB chunks and emits one `readChunk`
    /// event per successful `read(2)`, so chunk counts distinguish "stopped at the limit" from
    /// "read everything, then truncated" — which byte counts derived from the returned buffer
    /// cannot do.
    static let readChunkByteCount = 64 * 1024
    /// `ceil(524,289 / 65,536)` = eight full chunks plus a one-byte tail.
    static let boundedOversizedReadChunkCount = 9
    /// What reading the whole 4 MiB sibling would cost.
    static let unboundedOversizedReadChunkCount = oversizedFileByteCount / readChunkByteCount
    /// The exactly-at-cap file stops one chunk earlier: its ninth read returns EOF and emits no
    /// event.
    static let admittedFileReadChunkCount = 8

    /// Well past the 64 KiB ignore ceiling, so a bounded read is distinguishable from a full one.
    static let oversizedIgnoreFileByteCount = 4 * 64 * 1024
    /// `ceil(65,537 / 65,536)` = one full chunk plus a one-byte tail.
    static let boundedIgnoreReadChunkCount = 2

    /// Candidate count for the progress-stride probe. Chosen so it is neither below the
    /// 100-event cap nor divisible by it: `ceil(250 / 100) = 3` while `floor` would give 2, and
    /// 250 is not a multiple of 3, so the final `N / N` event is required separately.
    static let progressStrideFileCount = 250

    /// Files in the global-cap fixture. Each holds one more than the per-file ceiling, so the
    /// first 20 files emit 500 matches each and land exactly on the 10,000 global ceiling; the
    /// remaining files must be drained for accounting without emitting any further result.
    static let globalCapFileCount = 24
    static let globalCapOccurrencesPerFile = expectedMaximumMatchesPerFile + 1
    static let globalCapEmittingFileCount = expectedMaximumMatchesPerQuery / expectedMaximumMatchesPerFile

    // MARK: - Process warm-up

    /// Runs before every test, but does real work only on the first call in the process. See
    /// `WorkspaceSearchPerformanceWarmUp` for why the per-probe warm-up is not sufficient.
    override func setUp() async throws {
        try await super.setUp()
        try await WorkspaceSearchPerformanceWarmUp.shared.warmUpIfNeeded()
    }

    // MARK: - Production ceilings this gate is pinned to

    /// Fails when a production default moves away from the ceiling the rest of this file asserts
    /// against. Without this, every bound below would be read back from the same value it claims
    /// to be checking, and raising a limit would keep the suite green.
    func testProductionSearchLimitsStillMatchTheFrozenGateCeilings() {
        XCTAssertEqual(
            WorkspaceSearchLimits.defaultMaximumConcurrentReads,
            Self.expectedMaximumConcurrentReads
        )
        XCTAssertEqual(
            WorkspaceSearchLimits.defaultMaximumProgressEvents,
            Self.expectedMaximumProgressEvents
        )
        XCTAssertEqual(
            WorkspaceSearchLimits.defaultMaximumReportedSkippedFiles,
            Self.expectedMaximumReportedSkippedFiles
        )
        XCTAssertEqual(
            WorkspaceSearchLimits.defaultMaximumMatchesPerFile,
            Self.expectedMaximumMatchesPerFile
        )
        XCTAssertEqual(
            WorkspaceSearchLimits.defaultMaximumMatchesPerQuery,
            Self.expectedMaximumMatchesPerQuery
        )
        XCTAssertEqual(
            WorkspaceSearchLimits.defaultMaximumFileSizeBytes,
            Self.expectedMaximumFileSizeBytes
        )
        XCTAssertEqual(
            WorkspaceSearchLimits.defaultMaximumIgnoreFiles,
            Self.expectedMaximumIgnoreFiles
        )
        XCTAssertEqual(
            WorkspaceSearchLimits.defaultMaximumIgnoreFileSizeBytes,
            Self.expectedMaximumIgnoreFileSizeBytes
        )

        // The requests in this file are built with the default limits, so the instance values
        // must agree with the statics as well.
        let limits = WorkspaceSearchLimits()
        XCTAssertEqual(limits.maximumConcurrentReads, Self.expectedMaximumConcurrentReads)
        XCTAssertEqual(limits.maximumProgressEvents, Self.expectedMaximumProgressEvents)
        XCTAssertEqual(limits.maximumReportedSkippedFiles, Self.expectedMaximumReportedSkippedFiles)
        XCTAssertEqual(limits.maximumMatchesPerFile, Self.expectedMaximumMatchesPerFile)
        XCTAssertEqual(limits.maximumMatchesPerQuery, Self.expectedMaximumMatchesPerQuery)
        XCTAssertEqual(limits.maximumFileSizeBytes, Self.expectedMaximumFileSizeBytes)
        XCTAssertEqual(limits.maximumIgnoreFiles, Self.expectedMaximumIgnoreFiles)
        XCTAssertEqual(limits.maximumIgnoreFileSizeBytes, Self.expectedMaximumIgnoreFileSizeBytes)

        // MarkdownCore owns the synchronous matcher bounds the snippet assertions rely on.
        XCTAssertEqual(
            TextSearchEngine.maximumPatternUTF16Length,
            Self.expectedMaximumPatternUTF16Length
        )
        XCTAssertEqual(
            TextSearchEngine.maximumPreviewContextUTF16PerSide,
            Self.expectedMaximumPreviewContextUTF16PerSide
        )

        // The admission-cap fixtures are sized against the file ceiling, so they must track it.
        XCTAssertEqual(Self.admittedFileByteCount, Self.expectedMaximumFileSizeBytes)
    }

    // MARK: - 2,000-file production workspace

    func testTwoThousandFileWorkspaceSearchIsDeterministicAndBounded() async throws {
        let fixture = try await makeBulkWorkspaceFixture()
        defer { removeDirectory(fixture.rootURL) }

        let request = try makeRequest(
            capture: fixture.capture,
            rootIdentity: "ws4b-bulk-workspace",
            query: TextSearchQuery(pattern: Self.token, caseSensitivity: .sensitive)
        )

        // Unmeasured warm-up: page cache, dyld, and actor machinery must not be charged to
        // the budget. Its results are still verified so a warm-up that silently searched
        // nothing cannot make the measured samples cheap.
        let warmUp = try await collect(request: request)
        try assertBulkResults(warmUp.events, fixture: fixture, label: "warm-up")

        var samples: [Double] = []
        for attempt in 1 ... 3 {
            let run = try await collect(request: request)
            try assertBulkResults(run.events, fixture: fixture, label: "sample \(attempt)")
            samples.append(run.elapsedMilliseconds)
        }

        let median = Self.median(samples)
        print(String(
            format: "WS4B PERF workspace search %d files median %.3f ms samples %@ (%d bytes read)",
            Self.bulkFileCount,
            median,
            Self.formatSamples(samples),
            fixture.totalByteCount
        ))
        assertSearchBudget(
            median,
            lessThan: Self.bulkWorkspaceBudgetMilliseconds,
            metric: "workspace search \(Self.bulkFileCount) files median"
        )
    }

    // MARK: - Exactly admitted 512 KiB file

    func testExactlyAdmittedFiveHundredTwelveKiBFileIsSearchedToEndOfFile() async throws {
        let fixture = try await makeAdmittedFileFixture()
        defer { removeDirectory(fixture.rootURL) }

        let request = try makeRequest(
            capture: fixture.capture,
            rootIdentity: "ws4b-admitted-file",
            query: TextSearchQuery(pattern: Self.token, caseSensitivity: .sensitive)
        )

        let warmUp = try await collect(request: request)
        try assertAdmittedFileResults(warmUp.events, fixture: fixture, label: "warm-up")

        var samples: [Double] = []
        for attempt in 1 ... 3 {
            let run = try await collect(request: request)
            try assertAdmittedFileResults(run.events, fixture: fixture, label: "sample \(attempt)")
            samples.append(run.elapsedMilliseconds)
        }

        let median = Self.median(samples)
        print(String(
            format: "WS4B PERF admitted %d-byte file median %.3f ms samples %@",
            Self.admittedFileByteCount,
            median,
            Self.formatSamples(samples)
        ))
        assertSearchBudget(
            median,
            lessThan: Self.admittedFileBudgetMilliseconds,
            metric: "admitted \(Self.admittedFileByteCount)-byte file median"
        )
    }

    func testOversizedSiblingIsSkippedWithABoundedReadWhileTheExactCapIsSearched() async throws {
        let fixture = try await makeAdmissionBoundaryFixture()
        defer { removeDirectory(fixture.rootURL) }

        let request = try makeRequest(
            capture: fixture.capture,
            rootIdentity: "ws4b-admission-boundary",
            query: TextSearchQuery(pattern: Self.token, caseSensitivity: .sensitive)
        )

        let run = try await collect(request: request)
        let results = fileResults(in: run.events)
        let skipped = skippedFiles(in: run.events)
        let summary = try XCTUnwrap(completedSummaries(in: run.events).first)

        XCTAssertEqual(results.map(\.relativePath), [fixture.relativePath])
        XCTAssertEqual(results.first?.matches.count, 1)
        XCTAssertEqual(results.first?.matches.first?.range, fixture.expectedMatchRange)
        XCTAssertEqual(results.first?.matches.first?.line, fixture.expectedLine)
        // The sibling on disk is 4,194,304 bytes, but the read stops at the inclusive limit, so
        // the reported size is the bounded read (524,289) rather than the real file size. That
        // difference is the whole point of the oversized fixture being far past the cap.
        XCTAssertEqual(skipped, [
            WorkspaceSearchSkippedFile(
                relativePath: "oversized.md",
                reason: .oversized(byteCount: Self.boundedOversizedReadByteCount)
            ),
        ])
        XCTAssertEqual(summary.candidateFileCount, 2)
        XCTAssertEqual(summary.searchedFileCount, 1)
        XCTAssertEqual(summary.skippedFileCount, 1)
        XCTAssertEqual(summary.totalEmittedMatchCount, 1)

        // Exactly the admitted file plus one bounded read of the oversized sibling. An unbounded
        // read would make this 4,718,592.
        XCTAssertEqual(
            summary.readInstrumentation.diskReadByteCount,
            Self.admittedFileByteCount + Self.boundedOversizedReadByteCount
        )
        XCTAssertLessThan(
            summary.readInstrumentation.diskReadByteCount,
            Self.admittedFileByteCount + Self.oversizedFileByteCount,
            "the oversized sibling must not be read in full"
        )
        XCTAssertEqual(summary.omittedSkippedFileCount, 0)

        try assertSharedStreamInvariants(
            run.events,
            candidateFileCount: 2,
            expectedFileResultCount: 1,
            expectedSkippedEventCount: 1,
            label: "admission boundary"
        )
    }
}
