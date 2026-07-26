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

    private var hasWarmed = false

    /// Performs the warm-up on the first call in this process and returns immediately after that.
    /// Actor isolation serializes concurrent callers, so the body cannot run twice.
    func warmUpIfNeeded() async throws {
        guard !hasWarmed else { return }
        hasWarmed = true
        try await Self.performWarmUp()
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
            for await _ in service.events(for: request) {}
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
