import Foundation
import MarkdownCore
import WorkspaceKit
import XCTest

// Probes for the case policy the UI actually ships with (`.smart`). Split out of
// `WorkspaceSearchPerformanceTests.swift` to keep each file near the ~400-line guidance
// in agent.md §17.10.

extension WorkspaceSearchPerformanceTests {
    // MARK: - Default `.smart` case policy

    /// Anti-vacuity gate for the two `.smart` budgets below. `.smart` is only interesting here if
    /// it actually resolves to insensitive matching; if it silently resolved to sensitive, those
    /// probes would be re-measuring the already-budgeted `.sensitive` path under a new name.
    /// Proves the resolution behaviorally: the same lowercase pattern finds the title-case and
    /// upper-case occurrences under `.smart` but only the exact one under `.sensitive`, and a CJK
    /// pattern (no cased characters at all) finds every CJK occurrence.
    func testSmartCaseResolvesToInsensitiveMatchingForLowercaseAndCJKPatterns() async throws {
        let fixture = try await makeSmartCaseFixture()
        defer { removeDirectory(fixture.rootURL) }

        let smartRun = try await collect(request: makeRequest(
            capture: fixture.capture,
            rootIdentity: "ws4b-smart-case-smart",
            query: TextSearchQuery(pattern: Self.token)
        ))
        let sensitiveRun = try await collect(request: makeRequest(
            capture: fixture.capture,
            rootIdentity: "ws4b-smart-case-sensitive",
            query: TextSearchQuery(pattern: Self.token, caseSensitivity: .sensitive)
        ))
        let cjkSmartRun = try await collect(request: makeRequest(
            capture: fixture.capture,
            rootIdentity: "ws4b-smart-case-cjk",
            query: TextSearchQuery(pattern: Self.cjkToken)
        ))

        let smartResult = try XCTUnwrap(fileResults(in: smartRun.events).first)
        let sensitiveResult = try XCTUnwrap(fileResults(in: sensitiveRun.events).first)
        let cjkResult = try XCTUnwrap(fileResults(in: cjkSmartRun.events).first)

        // Default `.smart` over an all-lowercase pattern: case-insensitive, so all three spellings.
        XCTAssertEqual(smartResult.matches.count, 3, "smart must match all three case spellings")
        // Explicit `.sensitive`: only the exact lowercase spelling.
        XCTAssertEqual(sensitiveResult.matches.count, 1, "sensitive must match only the exact case")
        XCTAssertGreaterThan(
            smartResult.matches.count,
            sensitiveResult.matches.count,
            "smart and sensitive must take observably different backends here"
        )
        // A pure CJK pattern matches its occurrences, but note this alone proves nothing about
        // the backend: CJK is caseless, so both backends return the same thing. The two extra
        // occurrences here are the `平明歌` in `平明歌X`, hence 3 rather than 2.
        XCTAssertEqual(cjkResult.matches.count, 3, "smart CJK must match every CJK occurrence")

        // This is the CJK case that *does* discriminate: a lower-case Latin suffix on a CJK
        // pattern, against an upper-case occurrence.
        let cjkCasedSmart = try await collect(request: makeRequest(
            capture: fixture.capture,
            rootIdentity: "ws4b-smart-case-cjk-cased-smart",
            query: TextSearchQuery(pattern: Self.cjkCasedPattern)
        ))
        let cjkCasedSensitive = try await collect(request: makeRequest(
            capture: fixture.capture,
            rootIdentity: "ws4b-smart-case-cjk-cased-sensitive",
            query: TextSearchQuery(pattern: Self.cjkCasedPattern, caseSensitivity: .sensitive)
        ))
        XCTAssertEqual(
            try XCTUnwrap(fileResults(in: cjkCasedSmart.events).first).matches.count,
            1,
            "smart must match the upper-case CJK+Latin occurrence"
        )
        XCTAssertTrue(
            fileResults(in: cjkCasedSensitive.events).isEmpty,
            "sensitive must not match the upper-case CJK+Latin occurrence"
        )

        for (run, label) in [
            (smartRun, "smart"), (sensitiveRun, "sensitive"), (cjkSmartRun, "cjk smart"),
        ] {
            try assertSharedStreamInvariants(
                run.events,
                candidateFileCount: 1,
                expectedFileResultCount: 1,
                expectedSkippedEventCount: 0,
                label: label
            )
        }
    }

    /// The 2,000-file workspace under the case policy the UI actually ships with.
    func testTwoThousandFileWorkspaceSearchUnderDefaultSmartCaseStaysWithinBudget() async throws {
        let fixture = try await makeBulkWorkspaceFixture()
        defer { removeDirectory(fixture.rootURL) }

        // No `caseSensitivity:` argument — this is the production default.
        let request = try makeRequest(
            capture: fixture.capture,
            rootIdentity: "ws4b-bulk-workspace-smart",
            query: TextSearchQuery(pattern: Self.token)
        )

        let warmUp = try await collect(request: request)
        try assertBulkResults(warmUp.events, fixture: fixture, label: "smart warm-up")

        var samples: [Double] = []
        for attempt in 1 ... 3 {
            let run = try await collect(request: request)
            try assertBulkResults(run.events, fixture: fixture, label: "smart sample \(attempt)")
            samples.append(run.elapsedMilliseconds)
        }

        let median = Self.median(samples)
        print(String(
            format: "WS4B PERF workspace search %d files smart-case median %.3f ms samples %@",
            Self.bulkFileCount,
            median,
            Self.formatSamples(samples)
        ))
        assertSearchBudget(
            median,
            lessThan: Self.bulkWorkspaceSmartCaseBudgetMilliseconds,
            metric: "workspace search \(Self.bulkFileCount) files smart-case median"
        )
    }

    /// A full admission-cap file of CJK text searched under `.smart`, i.e. the insensitive backend
    /// over non-ASCII at the largest admissible size.
    ///
    /// The pattern's trailing Latin letter is lower-case while the file's occurrence is
    /// upper-case, so this probe is self-proving: `.smart` matches only because it resolved
    /// insensitive, and the `.sensitive` control below must find nothing in the same file. A pure
    /// CJK pattern would match identically under either backend and could not show which ran.
    func testAdmittedCJKFileUnderDefaultSmartCaseStaysWithinBudget() async throws {
        let fixture = try await makeAdmittedCJKFileFixture()
        defer { removeDirectory(fixture.rootURL) }

        let request = try makeRequest(
            capture: fixture.capture,
            rootIdentity: "ws4b-admitted-cjk",
            query: TextSearchQuery(pattern: Self.cjkCasedPattern)
        )

        // Unmeasured control: the same pattern under `.sensitive` must match nothing here, so the
        // measured samples cannot be passing through the already-budgeted sensitive path.
        let sensitiveRun = try await collect(request: makeRequest(
            capture: fixture.capture,
            rootIdentity: "ws4b-admitted-cjk-sensitive",
            query: TextSearchQuery(pattern: Self.cjkCasedPattern, caseSensitivity: .sensitive)
        ))
        XCTAssertTrue(
            fileResults(in: sensitiveRun.events).isEmpty,
            "sensitive control must not match the upper-case occurrence"
        )
        try assertSharedStreamInvariants(
            sensitiveRun.events,
            candidateFileCount: 1,
            expectedFileResultCount: 0,
            expectedSkippedEventCount: 0,
            label: "cjk sensitive control"
        )

        let warmUp = try await collect(request: request)
        try assertSingleCJKMatch(warmUp.events, fixture: fixture, label: "cjk warm-up")

        var samples: [Double] = []
        for attempt in 1 ... 3 {
            let run = try await collect(request: request)
            try assertSingleCJKMatch(run.events, fixture: fixture, label: "cjk sample \(attempt)")
            samples.append(run.elapsedMilliseconds)
        }

        let median = Self.median(samples)
        print(String(
            format: "WS4B PERF admitted %d-byte CJK file smart-case median %.3f ms samples %@",
            Self.admittedFileByteCount,
            median,
            Self.formatSamples(samples)
        ))
        assertSearchBudget(
            median,
            lessThan: Self.admittedCJKFileBudgetMilliseconds,
            metric: "admitted \(Self.admittedFileByteCount)-byte CJK file smart-case median"
        )
    }
}
