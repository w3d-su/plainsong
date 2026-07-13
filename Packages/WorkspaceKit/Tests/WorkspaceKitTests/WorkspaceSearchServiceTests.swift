import MarkdownCore
@testable import WorkspaceKit
import XCTest

final class WorkspaceSearchServiceTests: XCTestCase {
    func testSearchesOnlyMarkdownSnapshotEntriesAndUsesDirtyOverlayFingerprint() async throws {
        let root = try makeTemporaryDirectory()
        let reader = ScriptedReader(responses: [
            root.appendingPathComponent("disk.md").path: .data("needle on disk"),
            root.appendingPathComponent("page.mdx").path: .data("needle in mdx"),
            root.appendingPathComponent("notes.markdown").path: .data("needle in markdown"),
        ])
        let request = try makeRequest(
            root: root,
            entries: [
                entry("disk.md", kind: .markdown),
                entry("page.mdx", kind: .mdx),
                entry("notes.markdown", kind: .markdown),
                entry("image.png", kind: .image),
                entry("readme.txt", kind: .other),
                entry("folder", kind: .directory),
            ],
            query: "needle",
            overlays: WorkspaceSearchOverlayCollection([
                WorkspaceSearchOverlay(
                    relativePath: "disk.md",
                    text: "needle from overlay"
                ),
            ])
        )

        let events = await collectEvents(from: WorkspaceSearchService(reader: reader), request: request)
        let results = fileResults(in: events)

        XCTAssertEqual(results.map(\.relativePath), ["disk.md", "notes.markdown", "page.mdx"])
        XCTAssertEqual(
            results.first?.contentFingerprint,
            WorkspaceSearchContentFingerprint(text: "needle from overlay")
        )
        XCTAssertEqual(results.first?.matches.count, 1)
        XCTAssertEqual(completedSummary(in: events)?.candidateFileCount, 3)
        XCTAssertEqual(completedSummary(in: events)?.searchedFileCount, 3)
        let diskReadCount = await reader.readCount(for: root.appendingPathComponent("disk.md").path)
        XCTAssertEqual(diskReadCount, 0)
    }

    func testReportsReadFailuresAndByteLimitsWithoutFailingQuery() async throws {
        let root = try makeTemporaryDirectory()
        let reader = ScriptedReader(responses: [
            root.appendingPathComponent("bad.md").path: .bytes([0xFF]),
            root.appendingPathComponent("gone.md").path: .failure(.disappeared),
            root.appendingPathComponent("huge.md").path: .data("12345"),
            root.appendingPathComponent("unreadable.md").path: .failure(.unreadable),
        ])
        let request = try makeRequest(
            root: root,
            entries: [
                entry("bad.md"),
                entry("gone.md"),
                entry("huge.md"),
                entry("overlay.md"),
                entry("unreadable.md"),
            ],
            query: "needle",
            overlays: WorkspaceSearchOverlayCollection([
                WorkspaceSearchOverlay(
                    relativePath: "overlay.md",
                    text: "12345"
                ),
            ]),
            limits: WorkspaceSearchLimits(maximumFileSizeBytes: 4)
        )

        let events = await collectEvents(from: WorkspaceSearchService(reader: reader), request: request)
        let skipped = skippedFiles(in: events)

        XCTAssertEqual(skipped.map(\.relativePath), ["bad.md", "gone.md", "huge.md", "overlay.md", "unreadable.md"])
        XCTAssertEqual(skipped.map(\.reason), [
            .invalidUTF8,
            .disappeared,
            .oversized(byteCount: 5),
            .oversized(byteCount: 5),
            .unreadable,
        ])
        let summary = try XCTUnwrap(completedSummary(in: events))
        XCTAssertEqual(summary.skippedFileCount, 5)
        XCTAssertEqual(summary.searchedFileCount, 0)
        XCTAssertEqual(summary.readInstrumentation.diskReadCount, 4)
        XCTAssertFalse(events.contains { event in
            if case .failed = event { return true }
            return false
        })
    }

    func testPerFileAndGlobalLimitsReportExactTruncation() async throws {
        let root = try makeTemporaryDirectory()
        let reader = ScriptedReader(responses: [
            root.appendingPathComponent("many.md").path: .data("needle needle needle needle"),
            root.appendingPathComponent("second.md").path: .data("needle needle"),
        ])
        let request = makeRequest(
            root: root,
            entries: [entry("many.md"), entry("second.md")],
            query: "needle",
            limits: WorkspaceSearchLimits(
                maximumFileSizeBytes: 100,
                maximumMatchesPerFile: 2,
                maximumMatchesPerQuery: 3,
                maximumConcurrentReads: 2
            )
        )

        let events = await collectEvents(from: WorkspaceSearchService(reader: reader), request: request)
        let results = fileResults(in: events)
        let summary = try XCTUnwrap(completedSummary(in: events))

        XCTAssertEqual(results.map(\.relativePath), ["many.md", "second.md"])
        XCTAssertEqual(results.map(\.matches.count), [2, 1])
        XCTAssertTrue(results.allSatisfy(\.isTruncated))
        XCTAssertEqual(summary.totalEmittedMatchCount, 3)
        XCTAssertEqual(summary.truncatedFilePaths, ["many.md"])
        XCTAssertTrue(summary.isGloballyTruncated)
    }

    func testInvertedReadOrderStillPublishesResultsInPathOrderAndBoundsConcurrency() async throws {
        let root = try makeTemporaryDirectory()
        let reader = ScriptedReader(responses: [
            root.appendingPathComponent("a.md").path: .delayed("needle a", nanoseconds: 100_000_000),
            root.appendingPathComponent("b.md").path: .delayed("needle b", nanoseconds: 1_000_000),
            root.appendingPathComponent("c.md").path: .delayed("needle c", nanoseconds: 1_000_000),
        ])
        let request = makeRequest(
            root: root,
            entries: [entry("c.md"), entry("a.md"), entry("b.md")],
            query: "needle",
            limits: WorkspaceSearchLimits(maximumConcurrentReads: 2)
        )

        let events = await collectEvents(from: WorkspaceSearchService(reader: reader), request: request)
        let summary = try XCTUnwrap(completedSummary(in: events))

        XCTAssertEqual(fileResults(in: events).map(\.relativePath), ["a.md", "b.md", "c.md"])
        XCTAssertLessThanOrEqual(summary.readInstrumentation.maximumConcurrentReads, 2)
        let readerMaximumConcurrency = await reader.maximumConcurrentReads()
        XCTAssertLessThanOrEqual(readerMaximumConcurrency, 2)
        XCTAssertEqual(summary.readInstrumentation.maximumConcurrentReads, 2)
    }

    func testInvalidQueriesAreExplicitAndDoNotEmitCompletedSummary() async throws {
        let root = try makeTemporaryDirectory()
        let request = makeRequest(root: root, entries: [entry("post.md")], query: "")
        let service = WorkspaceSearchService(reader: ScriptedReader(responses: [:]))

        let emptyEvents = await collectEvents(from: service, request: request)
        XCTAssertEqual(validationErrors(in: emptyEvents), [.emptyQuery])
        XCTAssertNil(completedSummary(in: emptyEvents))

        let overlong = makeRequest(
            root: root,
            entries: [entry("post.md")],
            query: String(repeating: "a", count: TextSearchEngine.maximumPatternUTF16Length + 1)
        )
        let overlongEvents = await collectEvents(from: service, request: overlong)
        XCTAssertEqual(
            validationErrors(in: overlongEvents),
            [.overlongQuery(maximumUTF16Length: TextSearchEngine.maximumPatternUTF16Length)]
        )
        XCTAssertNil(completedSummary(in: overlongEvents))
    }

    func testCancellingConsumerStopsProducerWithoutCompletedSummary() async throws {
        let root = try makeTemporaryDirectory()
        let reader = ScriptedReader(responses: [
            root.appendingPathComponent("slow.md").path: .delayed("needle", nanoseconds: 5_000_000_000),
        ])
        let request = makeRequest(root: root, entries: [entry("slow.md")], query: "needle")
        let service = WorkspaceSearchService(reader: reader)

        let consumer = Task { () -> [WorkspaceSearchEvent] in
            await collectEvents(from: service, request: request)
        }
        await reader.waitUntilFirstRead()
        consumer.cancel()
        let events = await consumer.value

        XCTAssertNil(completedSummary(in: events))
        try await Task.sleep(nanoseconds: 20_000_000)
        let activeReadCount = await reader.activeReadCount()
        XCTAssertEqual(activeReadCount, 0)
    }

    private func makeRequest(
        root: URL,
        entries: [WorkspaceFileSnapshot.Entry],
        query: String,
        overlays: WorkspaceSearchOverlayCollection = .empty,
        limits: WorkspaceSearchLimits = .init()
    ) -> WorkspaceSearchRequest {
        WorkspaceSearchRequest(
            rootURL: root,
            rootIdentity: "workspace-test-root",
            snapshot: WorkspaceFileSnapshot(entries: entries),
            workspaceGeneration: 7,
            queryGeneration: 11,
            query: TextSearchQuery(pattern: query),
            dirtyOverlays: overlays,
            limits: limits
        )
    }

    private func entry(
        _ path: String,
        kind: WorkspaceFileKind = .markdown
    ) -> WorkspaceFileSnapshot.Entry {
        WorkspaceFileSnapshot.Entry(
            relativePath: path,
            kind: kind,
            identity: path,
            contentModificationDate: nil
        )
    }

    private func collectEvents(
        from service: WorkspaceSearchService,
        request: WorkspaceSearchRequest
    ) async -> [WorkspaceSearchEvent] {
        var events: [WorkspaceSearchEvent] = []
        for await event in service.events(for: request) {
            events.append(event)
        }
        return events
    }

    private func fileResults(in events: [WorkspaceSearchEvent]) -> [WorkspaceSearchFileResult] {
        events.compactMap { event in
            guard case let .fileResult(_, result) = event else { return nil }
            return result
        }
    }

    private func skippedFiles(in events: [WorkspaceSearchEvent]) -> [WorkspaceSearchSkippedFile] {
        events.compactMap { event in
            guard case let .skippedFile(_, skippedFile) = event else { return nil }
            return skippedFile
        }
    }

    private func completedSummary(in events: [WorkspaceSearchEvent]) -> WorkspaceSearchSummary? {
        events.compactMap { event in
            guard case let .completed(_, summary) = event else { return nil }
            return summary
        }.last
    }

    private func validationErrors(in events: [WorkspaceSearchEvent]) -> [WorkspaceSearchValidationError] {
        events.compactMap { event in
            guard case let .validationFailure(_, error) = event else { return nil }
            return error
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSearchServiceTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension WorkspaceSearchServiceTests {
    func testEventProductionLimitsHaveFiniteSafeDefaultsAndClampUnsafeInputs() {
        let defaults = WorkspaceSearchLimits()
        let clamped = WorkspaceSearchLimits(
            maximumConcurrentReads: 0,
            maximumReportedSkippedFiles: -1,
            maximumProgressEvents: 0
        )

        XCTAssertGreaterThan(defaults.maximumReportedSkippedFiles, 0)
        XCTAssertLessThan(defaults.maximumReportedSkippedFiles, Int.max)
        XCTAssertGreaterThan(defaults.maximumProgressEvents, 0)
        XCTAssertLessThan(defaults.maximumProgressEvents, Int.max)
        XCTAssertEqual(clamped.maximumReportedSkippedFiles, 0)
        XCTAssertEqual(clamped.maximumProgressEvents, 1)
        XCTAssertEqual(clamped.maximumConcurrentReads, 1)
    }
}

private actor ScriptedReader: SyntheticWorkspaceSearchFileReading {
    enum Response {
        case bytes([UInt8])
        case data(String)
        case delayed(String, nanoseconds: UInt64)
        case failure(WorkspaceSearchFileReadError)
    }

    private let responses: [String: Response]
    private var activeReads = 0
    private var maximumReads = 0
    private var readsByPath: [String: Int] = [:]
    private var firstReadWaiters: [CheckedContinuation<Void, Never>] = []

    init(responses: [String: Response]) {
        self.responses = responses
    }

    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data {
        activeReads += 1
        maximumReads = max(maximumReads, activeReads)
        readsByPath[url.path, default: 0] += 1
        let waiters = firstReadWaiters
        firstReadWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        defer { activeReads -= 1 }

        switch responses[url.path] ?? .failure(.disappeared) {
        case let .bytes(bytes):
            return Data(bytes.prefix(maximumByteCount))
        case let .data(text):
            return Data(text.utf8.prefix(maximumByteCount))
        case let .delayed(text, nanoseconds):
            try await Task.sleep(nanoseconds: nanoseconds)
            return Data(text.utf8.prefix(maximumByteCount))
        case let .failure(error):
            throw error
        }
    }

    func maximumConcurrentReads() -> Int {
        maximumReads
    }

    func activeReadCount() -> Int {
        activeReads
    }

    func readCount(for path: String) -> Int {
        readsByPath[path, default: 0]
    }

    func waitUntilFirstRead() async {
        if activeReads > 0 { return }
        await withCheckedContinuation { continuation in
            firstReadWaiters.append(continuation)
        }
    }
}
