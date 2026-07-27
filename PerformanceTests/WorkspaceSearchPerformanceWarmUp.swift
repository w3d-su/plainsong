import Foundation
import MarkdownCore
import WorkspaceKit
import XCTest

/// One-per-process warm-up for the WS4B workspace-search probes.
///
/// Why this exists on top of the per-probe warm-up: the per-probe warm-up amortizes cost paid
/// *per probe* — page cache for that probe's fixture, that request shape's actor machinery. It
/// cannot amortize cost paid *per process*: dyld work for the first call into WorkspaceKit and
/// MarkdownCore, Foundation/ICU table initialization on the first Unicode comparison, first
/// construction of the task-group read pipeline, and CPU frequency ramp from idle. Whichever
/// probe XCTest happens to run first absorbs all of that.
///
/// `docs/perf-log.md` records the consequence: on a cold first Debug run the whole suite was
/// uniformly 1.3x-2.8x slower than the runs after it, and `unicode-periodic` landed at a
/// 2462.412 ms median against its 2,500 ms budget, with one sample over it. This warm-up runs
/// before any measured sample, so the first probe no longer pays process start-up.
///
/// It is never measured: it runs from `setUp()`, outside every timed region. It is deliberately
/// self-contained rather than reusing the fixture helpers, so nothing here captures the
/// non-`Sendable` `XCTestCase` across an actor hop.
actor WorkspaceSearchPerformanceWarmUp {
    static let shared = WorkspaceSearchPerformanceWarmUp()

    /// The single in-flight or completed warm-up. Callers await *this task*, not a flag, so a
    /// second caller arriving mid-warm-up blocks until the work is actually finished instead of
    /// racing ahead and measuring against a half-warm process.
    private var warmUpTask: Task<Void, any Error>?

    /// Performs the warm-up once per process. Concurrent callers share the same task; a failed
    /// warm-up is not recorded as done, so the failure surfaces and a later caller can retry
    /// rather than every subsequent probe silently measuring an unwarmed process.
    func warmUpIfNeeded() async throws {
        if let warmUpTask {
            return try await warmUpTask.value
        }
        let task = Task { try await Self.performWarmUp() }
        warmUpTask = task
        do {
            try await task.value
        } catch {
            warmUpTask = nil
            throw error
        }
    }

    /// Bounded warm-up over a small workspace touching each expensive path the probes rely on:
    /// candidate planning, anchored reads, UTF-8 decoding, both case backends, composed
    /// whole-word rejection, snippet construction, and stream delivery.
    ///
    /// Deliberately small — tens of KiB rather than the 512 KiB admission cap — because the goal
    /// is to page in code and initialize Unicode tables, not to reproduce a probe.
    private static func performWarmUp() async throws {
        let root = try makeWarmUpDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Ordinary prose, exercising the literal scanner and the snippet builder.
        let prose = (0 ..< 8)
            .map { index in
                WorkspaceSearchPerformanceTests.makeBody(
                    index: index,
                    includesToken: index.isMultiple(of: 2)
                )
            }
            .joined(separator: "\n")
        try Data(prose.utf8).write(
            to: root.appendingPathComponent("warm-prose.md"),
            options: .atomic
        )

        // Composed non-ASCII with overlapping rejected candidates: the path that initializes the
        // Unicode machinery behind `unicode-periodic`, the probe closest to its budget.
        let unit = "e\u{0301}."
        let composed = String(repeating: unit, count: 4096) + "z"
        try Data(composed.utf8).write(
            to: root.appendingPathComponent("warm-composed.md"),
            options: .atomic
        )

        let capture = try await WorkspaceDirectoryScanner().snapshotCapture(root: root)
        let queries = [
            // Explicit case-sensitive literal matching.
            TextSearchQuery(
                pattern: WorkspaceSearchPerformanceTests.token,
                caseSensitivity: .sensitive
            ),
            // Default `.smart` over a lowercase pattern, i.e. the insensitive backend.
            TextSearchQuery(pattern: WorkspaceSearchPerformanceTests.token),
            // Composed whole-word rejection.
            TextSearchQuery(
                pattern: String(repeating: unit, count: 64),
                caseSensitivity: .sensitive,
                wholeWord: true
            ),
        ]

        for (index, query) in queries.enumerated() {
            let request = WorkspaceSearchRequest(
                rootAuthority: capture.rootAuthority,
                rootIdentity: "ws4b-warm-up-\(index)",
                snapshot: capture.snapshot,
                workspaceGeneration: 1,
                queryGeneration: UInt64(index + 1),
                query: query
            )
            let service = WorkspaceSearchService()

            // The stream's outcome is checked rather than discarded: a warm-up that failed, or
            // searched nothing, would otherwise "succeed" while leaving the very paths it exists
            // to warm untouched, and every probe after it would quietly measure a cold process.
            //
            // The full terminal contract is checked, not just the last value seen — exactly one
            // terminal event, no failure terminal, nothing emitted after it. Retaining only the
            // most recent summary would accept a duplicate `.completed`, or progress arriving
            // after completion, as a healthy warm-up.
            var summary: WorkspaceSearchSummary?
            var terminalCount = 0
            var sawFailure = false
            var eventsAfterTerminal = 0
            var matchingFileCount = 0
            for await event in service.events(for: request) {
                if terminalCount > 0 { eventsAfterTerminal += 1 }
                switch event {
                case let .completed(_, completedSummary):
                    terminalCount += 1
                    summary = summary ?? completedSummary
                case .failed:
                    terminalCount += 1
                    sawFailure = true
                case let .fileResult(_, result):
                    matchingFileCount += result.matches.isEmpty ? 0 : 1
                case .skippedFile, .progress, .validationFailure:
                    break
                }
            }

            guard !sawFailure else {
                throw WarmUpError.streamFailed(queryIndex: index)
            }
            guard terminalCount == 1 else {
                throw WarmUpError.unexpectedTerminalCount(queryIndex: index, actual: terminalCount)
            }
            guard eventsAfterTerminal == 0 else {
                throw WarmUpError.eventsAfterTerminal(
                    queryIndex: index,
                    actual: eventsAfterTerminal
                )
            }
            guard let summary else {
                throw WarmUpError.noTerminalEvent(queryIndex: index)
            }
            guard summary.searchedFileCount == 2 else {
                throw WarmUpError.unexpectedSearchedFileCount(
                    queryIndex: index,
                    actual: summary.searchedFileCount
                )
            }
            // Queries 0 and 1 must match the prose file; query 2 is a whole-word rejection shape
            // and is expected to match nothing, but it still has to have scanned both files.
            let expectedMatchingFiles = index == 2 ? 0 : 1
            guard matchingFileCount == expectedMatchingFiles else {
                throw WarmUpError.unexpectedMatchingFileCount(
                    queryIndex: index,
                    expected: expectedMatchingFiles,
                    actual: matchingFileCount
                )
            }
        }
    }

    enum WarmUpError: Error, CustomStringConvertible {
        case streamFailed(queryIndex: Int)
        case noTerminalEvent(queryIndex: Int)
        case unexpectedTerminalCount(queryIndex: Int, actual: Int)
        case eventsAfterTerminal(queryIndex: Int, actual: Int)
        case unexpectedSearchedFileCount(queryIndex: Int, actual: Int)
        case unexpectedMatchingFileCount(queryIndex: Int, expected: Int, actual: Int)

        var description: String {
            switch self {
            case let .streamFailed(index):
                "WS4B warm-up query \(index) emitted a failure terminal"
            case let .noTerminalEvent(index):
                "WS4B warm-up query \(index) produced no completion terminal"
            case let .unexpectedTerminalCount(index, actual):
                "WS4B warm-up query \(index) emitted \(actual) terminal events, expected 1"
            case let .eventsAfterTerminal(index, actual):
                "WS4B warm-up query \(index) emitted \(actual) events after its terminal"
            case let .unexpectedSearchedFileCount(index, actual):
                "WS4B warm-up query \(index) searched \(actual) files, expected 2"
            case let .unexpectedMatchingFileCount(index, expected, actual):
                "WS4B warm-up query \(index) matched \(actual) files, expected \(expected)"
            }
        }
    }

    private static func makeWarmUpDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WS4BWarmUp")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try WorkspaceFileSystemRootAuthority(rootURL: url).canonicalRootURL
    }
}
