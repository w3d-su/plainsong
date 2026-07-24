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

    // MARK: - Fixture shape

    static let token = "plainsong-needle"
    static let bulkFileCount = 2000
    static let bulkSectionCount = 20
    static let bulkMatchingStride = 4
    static let matchesPerMatchingFile = 2
    static let admittedFileByteCount = 524_288

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

    func testOneByteOverTheAdmissionCapIsSkippedWhileTheExactCapIsSearched() async throws {
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
        XCTAssertEqual(skipped, [
            WorkspaceSearchSkippedFile(
                relativePath: "oversized.md",
                reason: .oversized(byteCount: Self.admittedFileByteCount + 1)
            ),
        ])
        XCTAssertEqual(summary.candidateFileCount, 2)
        XCTAssertEqual(summary.searchedFileCount, 1)
        XCTAssertEqual(summary.skippedFileCount, 1)
        XCTAssertEqual(summary.totalEmittedMatchCount, 1)
        XCTAssertEqual(
            summary.readInstrumentation.diskReadByteCount,
            Self.admittedFileByteCount + (Self.admittedFileByteCount + 1)
        )
        XCTAssertEqual(terminalEventCount(in: run.events), 1)
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
            WorkspaceSearchLimits().maximumMatchesPerFile,
            "\(shape.rawValue) literal control"
        )
        XCTAssertTrue(literalResult.isTruncated, "\(shape.rawValue) literal control")

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

    // MARK: - Rapid cancellation of a saturated read window

    func testRapidCancellationOfASaturatedReadWindowDrainsWithoutTerminalEvent() async throws {
        let fixture = try await makeBulkWorkspaceFixture()
        defer { removeDirectory(fixture.rootURL) }

        let readWindow = WorkspaceSearchLimits.defaultMaximumConcurrentReads
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
            await reader.waitUntilStartCount(readWindow)
            let startedBeforeCancellation = await reader.startCount()
            let cancelledAt = DispatchTime.now().uptimeNanoseconds
            consumer.cancel()
            let events = await consumer.value
            await reader.waitUntilNoActiveReads()
            let drainMilliseconds = Self.milliseconds(since: cancelledAt)

            let activeReads = await reader.activeReadCount()
            let startCount = await reader.startCount()
            let cancelledReads = await reader.cancelledReadCount()

            XCTAssertEqual(startedBeforeCancellation, readWindow, "attempt \(attempt)")
            XCTAssertEqual(startCount, readWindow, "attempt \(attempt)")
            XCTAssertEqual(activeReads, 0, "attempt \(attempt)")
            XCTAssertEqual(cancelledReads, readWindow, "attempt \(attempt)")
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

// MARK: - Fixtures

private struct BulkWorkspaceFixture {
    let rootURL: URL
    let capture: WorkspaceDirectorySnapshotCapture
    let orderedRelativePaths: [String]
    let matchingRelativePaths: [String]
    let totalByteCount: Int
    let expectedMatchRanges: [NSRange]
}

private struct SingleFileFixture {
    let rootURL: URL
    let capture: WorkspaceDirectorySnapshotCapture
    let relativePath: String
    let byteCount: Int
    let expectedMatchRange: NSRange
    let expectedLine: Int
}

private struct DenseWholeWordFixture {
    let rootURL: URL
    let capture: WorkspaceDirectorySnapshotCapture
    let relativePath: String
    let byteCount: Int
    let pattern: String
}

/// Two whole-word rejection shapes at the admission cap. `suffixRejected` is ordinary ASCII
/// prose whose every literal hit is rejected by a trailing word character; `composedPeriodic`
/// is the adversarial non-ASCII periodic text whose overlapping candidates force composed
/// boundary work — the shape that motivated the 512 KiB admission cap.
private enum DenseWholeWordShape: String, CaseIterable {
    case suffixRejected = "ascii-suffix"
    case composedPeriodic = "unicode-periodic"

    /// Frozen from the 2026-07-25 measurements in `docs/perf-log.md`. The composed-periodic
    /// shape is the documented worst case at the admission cap: Debug median 1145 ms and
    /// Release median 612 ms, which is why a 1 MiB admission cap was rejected.
    var budgetMilliseconds: Double {
        switch self {
        case .suffixRejected:
            200
        case .composedPeriodic:
            2500
        }
    }
}

extension WorkspaceSearchPerformanceTests {
    private func makeBulkWorkspaceFixture() async throws -> BulkWorkspaceFixture {
        let root = try makeTemporaryDirectory(prefix: "WS4BBulkWorkspace")
        let filesPerSection = Self.bulkFileCount / Self.bulkSectionCount
        var orderedRelativePaths: [String] = []
        var matchingRelativePaths: [String] = []
        var totalByteCount = 0
        var matchingBody: String?

        for section in 0 ..< Self.bulkSectionCount {
            let directoryName = String(format: "section-%02d", section)
            let directoryURL = root.appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)

            for offset in 0 ..< filesPerSection {
                let index = section * filesPerSection + offset
                let includesToken = index.isMultiple(of: Self.bulkMatchingStride)
                let fileExtension = index.isMultiple(of: 5) ? "mdx" : "md"
                let name = String(format: "post-%04d.%@", index, fileExtension)
                let relativePath = "\(directoryName)/\(name)"
                let body = Self.makeBody(index: index, includesToken: includesToken)
                try Data(body.utf8).write(to: directoryURL.appendingPathComponent(name), options: .atomic)

                orderedRelativePaths.append(relativePath)
                totalByteCount += body.utf8.count
                if includesToken {
                    matchingRelativePaths.append(relativePath)
                    matchingBody = matchingBody ?? body
                }
            }
        }

        let capture = try await WorkspaceDirectoryScanner().snapshotCapture(root: root)
        let sampleMatchingBody = try XCTUnwrap(matchingBody)
        let expectedMatchRanges = Self.independentTokenRanges(in: sampleMatchingBody)
        XCTAssertEqual(expectedMatchRanges.count, Self.matchesPerMatchingFile)

        return BulkWorkspaceFixture(
            rootURL: root,
            capture: capture,
            orderedRelativePaths: orderedRelativePaths,
            matchingRelativePaths: matchingRelativePaths,
            totalByteCount: totalByteCount,
            expectedMatchRanges: expectedMatchRanges
        )
    }

    private func makeAdmittedFileFixture() async throws -> SingleFileFixture {
        let root = try makeTemporaryDirectory(prefix: "WS4BAdmittedFile")
        let body = Self.makeExactlyAdmittedBody()
        try Data(body.utf8).write(to: root.appendingPathComponent("admitted.md"), options: .atomic)

        let capture = try await WorkspaceDirectoryScanner().snapshotCapture(root: root)
        let ranges = Self.independentTokenRanges(in: body)
        XCTAssertEqual(ranges.count, 1)
        let range = try XCTUnwrap(ranges.first)
        XCTAssertGreaterThan(range.location, Self.admittedFileByteCount - 512)

        return SingleFileFixture(
            rootURL: root,
            capture: capture,
            relativePath: "admitted.md",
            byteCount: body.utf8.count,
            expectedMatchRange: range,
            expectedLine: Self.lineNumber(ofUTF16Location: range.location, in: body)
        )
    }

    private func makeAdmissionBoundaryFixture() async throws -> SingleFileFixture {
        let root = try makeTemporaryDirectory(prefix: "WS4BAdmissionBoundary")
        let admitted = Self.makeExactlyAdmittedBody()
        try Data(admitted.utf8).write(to: root.appendingPathComponent("admitted.md"), options: .atomic)
        try Data((admitted + "\n").utf8)
            .write(to: root.appendingPathComponent("oversized.md"), options: .atomic)

        let capture = try await WorkspaceDirectoryScanner().snapshotCapture(root: root)
        let range = try XCTUnwrap(Self.independentTokenRanges(in: admitted).first)

        return SingleFileFixture(
            rootURL: root,
            capture: capture,
            relativePath: "admitted.md",
            byteCount: admitted.utf8.count,
            expectedMatchRange: range,
            expectedLine: Self.lineNumber(ofUTF16Location: range.location, in: admitted)
        )
    }

    private func makeDenseWholeWordFixture(
        shape: DenseWholeWordShape
    ) async throws -> DenseWholeWordFixture {
        let root = try makeTemporaryDirectory(prefix: "WS4BDenseWholeWord")
        let unit: String
        let pattern: String
        switch shape {
        case .suffixRejected:
            // Every literal hit is immediately rejected because a word character follows it.
            unit = "\(Self.token)s "
            pattern = Self.token
        case .composedPeriodic:
            // Overlapping candidates in composed non-ASCII text: only the last position could
            // match, and every earlier one must be examined and rejected.
            unit = "e\u{0301}."
            pattern = String(repeating: unit, count: 64)
        }

        // Reserve at least one trailing word character so even the final candidate is rejected
        // by the closing boundary; every literal hit in the file must be examined and refused.
        let repetitions = (Self.admittedFileByteCount - 1) / unit.utf8.count
        let remainder = Self.admittedFileByteCount - repetitions * unit.utf8.count
        let body = String(repeating: unit, count: repetitions) + String(repeating: "z", count: remainder)
        XCTAssertEqual(body.utf8.count, Self.admittedFileByteCount, shape.rawValue)
        XCTAssertLessThanOrEqual(pattern.utf16.count, TextSearchEngine.maximumPatternUTF16Length)
        try Data(body.utf8).write(to: root.appendingPathComponent("dense.md"), options: .atomic)

        let capture = try await WorkspaceDirectoryScanner().snapshotCapture(root: root)
        return DenseWholeWordFixture(
            rootURL: root,
            capture: capture,
            relativePath: "dense.md",
            byteCount: body.utf8.count,
            pattern: pattern
        )
    }

    private static func makeBody(index: Int, includesToken: Bool) -> String {
        let filler = "This deterministic paragraph gives workspace search ordinary prose to scan."
        var lines: [String] = []
        lines.append(String(format: "# Post %04d", index))
        lines.append("")
        lines.append(includesToken ? "Intro mentions \(token) once." : "Intro mentions nothing here.")
        lines.append("")
        for _ in 0 ..< 18 {
            lines.append(filler)
        }
        lines.append("")
        lines.append(includesToken ? "Outro mentions \(token) again." : "Outro mentions nothing again.")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func makeExactlyAdmittedBody() -> String {
        let tail = "\nfinal line mentions \(token) at end of file.\n"
        let header = "# Admitted at exactly the workspace-search admission cap\n\n"
        let padding = admittedFileByteCount - header.utf8.count - tail.utf8.count
        precondition(padding > 0)
        return header + String(repeating: "a", count: padding) + tail
    }

    /// Locates the token with Foundation rather than `TextSearchEngine`, so the expected
    /// ranges are not produced by the code under measurement.
    private static func independentTokenRanges(in text: String) -> [NSRange] {
        let source = text as NSString
        var ranges: [NSRange] = []
        var searchStart = 0
        while searchStart < source.length {
            let searchRange = NSRange(location: searchStart, length: source.length - searchStart)
            let found = source.range(of: token, options: [.literal], range: searchRange)
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            searchStart = found.location + max(1, found.length)
        }
        return ranges
    }

    private static func lineNumber(ofUTF16Location location: Int, in text: String) -> Int {
        let source = text as NSString
        var line = 1
        var index = 0
        while index < location, index < source.length {
            let character = source.character(at: index)
            if character == 0x0D {
                line += 1
                if index + 1 < source.length, source.character(at: index + 1) == 0x0A {
                    index += 1
                }
            } else if character == 0x0A {
                line += 1
            }
            index += 1
        }
        return line
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try WorkspaceFileSystemRootAuthority(rootURL: url).canonicalRootURL
    }

    private func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Request and stream helpers

private struct SearchRun {
    let events: [WorkspaceSearchEvent]
    let elapsedMilliseconds: Double
}

extension WorkspaceSearchPerformanceTests {
    private func makeRequest(
        capture: WorkspaceDirectorySnapshotCapture,
        rootIdentity: String,
        query: TextSearchQuery,
        queryGeneration: UInt64 = 1
    ) throws -> WorkspaceSearchRequest {
        WorkspaceSearchRequest(
            rootAuthority: capture.rootAuthority,
            rootIdentity: rootIdentity,
            snapshot: capture.snapshot,
            workspaceGeneration: 1,
            queryGeneration: queryGeneration,
            query: query
        )
    }

    /// Consumes the complete stream from the production disk reader and returns wall-clock
    /// time for the whole request, including candidate planning and terminal delivery.
    private func collect(request: WorkspaceSearchRequest) async throws -> SearchRun {
        // `WorkspaceSearchService()` selects the production `WorkspaceSearchDiskFileReader`.
        // It is constructed before the clock starts so only request work is measured.
        let service = WorkspaceSearchService()
        let start = DispatchTime.now().uptimeNanoseconds
        var events: [WorkspaceSearchEvent] = []
        for await event in service.events(for: request) {
            events.append(event)
        }
        let elapsed = Self.milliseconds(since: start)
        return SearchRun(events: events, elapsedMilliseconds: elapsed)
    }

    private func assertBulkResults(
        _ events: [WorkspaceSearchEvent],
        fixture: BulkWorkspaceFixture,
        label: String
    ) throws {
        let results = fileResults(in: events)
        let summary = try XCTUnwrap(completedSummaries(in: events).first, label)
        let progress = progressEvents(in: events)
        let limits = WorkspaceSearchLimits()
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
        XCTAssertEqual(summary.readInstrumentation.maximumConcurrentReads, limits.maximumConcurrentReads, label)
        XCTAssertEqual(summary.readInstrumentation.maximumOutstandingReadCount, limits.maximumConcurrentReads, label)
        // Buffering behind an earlier path is completion-order dependent; only its ceiling is
        // contractual, so the exact peak is not asserted.
        XCTAssertLessThanOrEqual(
            summary.readInstrumentation.maximumBufferedReadCount,
            limits.maximumConcurrentReads,
            label
        )

        // Structural memory boundedness: production emits a finite, precomputable number of
        // events with per-file, per-query, snippet, and read-window ceilings intact.
        let expectedProgressEventCount = limits.maximumProgressEvents
        XCTAssertEqual(progress.count, expectedProgressEventCount, label)
        XCTAssertEqual(
            progress.last,
            WorkspaceSearchProgress(
                completedFileCount: Self.bulkFileCount,
                candidateFileCount: Self.bulkFileCount
            ),
            label
        )
        XCTAssertTrue(
            zip(progress, progress.dropFirst()).allSatisfy { $0.completedFileCount < $1.completedFileCount },
            label
        )
        XCTAssertEqual(
            events.count,
            results.count + expectedProgressEventCount + 1,
            label
        )
        XCTAssertLessThanOrEqual(expectedMatchCount, limits.maximumMatchesPerQuery, label)
        XCTAssertTrue(
            results.allSatisfy { $0.matches.count <= limits.maximumMatchesPerFile },
            label
        )
        XCTAssertEqual(terminalEventCount(in: events), 1, label)
        guard let lastEvent = events.last, case .completed = lastEvent else {
            return XCTFail("\(label): completion must be the final event")
        }
    }

    private func assertAdmittedFileResults(
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
        XCTAssertEqual(terminalEventCount(in: events), 1, label)
    }

    private func assertDenseRejectionResults(
        _ events: [WorkspaceSearchEvent],
        fixture: DenseWholeWordFixture,
        label: String
    ) throws {
        let summary = try XCTUnwrap(completedSummaries(in: events).first, label)

        XCTAssertTrue(fileResults(in: events).isEmpty, label)
        XCTAssertTrue(skippedFiles(in: events).isEmpty, label)
        XCTAssertEqual(summary.candidateFileCount, 1, label)
        XCTAssertEqual(summary.searchedFileCount, 1, label)
        XCTAssertEqual(summary.totalEmittedMatchCount, 0, label)
        XCTAssertEqual(summary.readInstrumentation.diskReadCount, 1, label)
        XCTAssertEqual(summary.readInstrumentation.diskReadByteCount, fixture.byteCount, label)
        XCTAssertEqual(terminalEventCount(in: events), 1, label)
    }

    private static func previewUTF16Bound(for match: TextSearchMatch) -> Int {
        match.range.length
            + 2 * TextSearchEngine.maximumPreviewContextUTF16PerSide
            + 2 * (TextSearchEngine.previewEllipsis as NSString).length
    }
}

// MARK: - Event and timing helpers

extension WorkspaceSearchPerformanceTests {
    private func fileResults(in events: [WorkspaceSearchEvent]) -> [WorkspaceSearchFileResult] {
        events.compactMap { event in
            guard case let .fileResult(_, result) = event else { return nil }
            return result
        }
    }

    private func skippedFiles(in events: [WorkspaceSearchEvent]) -> [WorkspaceSearchSkippedFile] {
        events.compactMap { event in
            guard case let .skippedFile(_, skipped) = event else { return nil }
            return skipped
        }
    }

    private func progressEvents(in events: [WorkspaceSearchEvent]) -> [WorkspaceSearchProgress] {
        events.compactMap { event in
            guard case let .progress(_, progress) = event else { return nil }
            return progress
        }
    }

    private func completedSummaries(in events: [WorkspaceSearchEvent]) -> [WorkspaceSearchSummary] {
        events.compactMap { event in
            guard case let .completed(_, summary) = event else { return nil }
            return summary
        }
    }

    private func failures(in events: [WorkspaceSearchEvent]) -> [WorkspaceSearchServiceFailure] {
        events.compactMap { event in
            guard case let .failed(_, failure) = event else { return nil }
            return failure
        }
    }

    private func terminalEventCount(in events: [WorkspaceSearchEvent]) -> Int {
        events.reduce(into: 0) { count, event in
            switch event {
            case .completed, .failed:
                count += 1
            case .fileResult, .skippedFile, .progress, .validationFailure:
                break
            }
        }
    }

    private func assertSearchBudget(
        _ value: Double,
        lessThan budget: Double,
        metric: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard value >= budget else { return }
        let message = String(
            format: "WS4B PERF %@ %.3f ms exceeded %.3f ms budget",
            metric,
            value,
            budget
        )
        if Self.isContinuousIntegration {
            print("\(message) on CI; informational per risk R15")
            return
        }
        XCTFail(message, file: file, line: line)
    }

    private static var isContinuousIntegration: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CI"] == "true" || environment["GITHUB_ACTIONS"] == "true"
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    private static func formatSamples(_ samples: [Double]) -> String {
        "[" + samples.map { String(format: "%.3f", $0) }.joined(separator: ", ") + "]"
    }
}

// MARK: - Controlled reader for deterministic cancellation

/// Blocks every candidate read so the producer saturates exactly the configured window and
/// cancellation has deterministic work to drain. Ignore-policy probes for `.gitignore` /
/// `.ignore` resolve immediately as missing, exactly as they do in the real fixture, so the
/// blocked reads are candidate reads only.
private actor BlockingSearchReader: WorkspaceSearchFileReading {
    private var activeReads = 0
    private var startedReads = 0
    private var cancelledReads = 0
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated func physicalPreflightError(at _: URL) -> WorkspaceSearchFileReadError? {
        nil
    }

    nonisolated func validateFile(at _: WorkspaceFileSystemLocation) async throws {}

    nonisolated func validateFileAuthority(
        at _: WorkspaceFileSystemLocation
    ) async throws -> WorkspaceSearchFileAuthority? {
        nil
    }

    func readFile(at location: WorkspaceFileSystemLocation, maximumByteCount: Int) async throws -> Data {
        try await block(name: location.fileURL.lastPathComponent, maximumByteCount: maximumByteCount)
    }

    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data {
        try await block(name: url.lastPathComponent, maximumByteCount: maximumByteCount)
    }

    func readFileWithAuthority(
        at location: WorkspaceFileSystemLocation,
        maximumByteCount: Int
    ) async throws -> WorkspaceSearchFileReadResult {
        let data = try await block(
            name: location.fileURL.lastPathComponent,
            maximumByteCount: maximumByteCount
        )
        return WorkspaceSearchFileReadResult(data: data, fileAuthority: nil)
    }

    func waitUntilStartCount(_ count: Int) async {
        if startedReads >= count { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func waitUntilNoActiveReads() async {
        if activeReads == 0 { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    func startCount() -> Int {
        startedReads
    }

    func activeReadCount() -> Int {
        activeReads
    }

    func cancelledReadCount() -> Int {
        cancelledReads
    }

    private func block(name: String, maximumByteCount: Int) async throws -> Data {
        guard !name.hasPrefix(".") else {
            throw WorkspaceSearchFileReadError.disappeared
        }

        startedReads += 1
        activeReads += 1
        resumeStartWaiters()
        defer {
            activeReads -= 1
            if activeReads == 0 {
                let waiters = idleWaiters
                idleWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }

        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return Data("unreachable".utf8.prefix(max(0, maximumByteCount)))
        } catch {
            cancelledReads += 1
            throw error
        }
    }

    private func resumeStartWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, continuation) in startWaiters {
            if startedReads >= target {
                continuation.resume()
            } else {
                remaining.append((target, continuation))
            }
        }
        startWaiters = remaining
    }
}
