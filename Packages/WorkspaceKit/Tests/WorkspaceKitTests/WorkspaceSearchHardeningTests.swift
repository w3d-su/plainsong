import Foundation
import MarkdownCore
@testable import WorkspaceKit
import XCTest

final class WorkspaceSearchHardeningTests: XCTestCase {
    func testGlobalOverflowContinuesExactAccountingWithoutFurtherMatchingOrResults() async throws {
        let root = try makeTemporaryDirectory()
        let fixture = GlobalOverflowFixture()
        let reader = GlobalTruncationAccountingReader()
        let request = makeRequest(
            root: root,
            paths: fixture.paths.reversed(),
            limits: fixture.limits
        )
        let service = WorkspaceSearchService(
            reader: reader,
            failurePoint: .beforeMatching("600-valid.md")
        )

        let events = await collectEvents(service, request: request)
        let summary = try XCTUnwrap(completedSummaries(in: events).only)
        assertGlobalOverflowEvents(events, fixture: fixture)
        assertGlobalOverflowSummary(summary, skipped: skippedFileEvents(in: events), fixture: fixture)
        await assertGlobalOverflowReads(summary, reader: reader, fixture: fixture)
    }

    func testReaderCancellationErrorWithoutTaskCancellationEmitsExactlyOneFailure() async throws {
        let root = try makeTemporaryDirectory()
        let request = makeRequest(root: root, paths: ["post.md"])

        let events = await collectEvents(
            WorkspaceSearchService(reader: UnexpectedCancellationErrorReader()),
            request: request
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(failures(in: events), [.unexpectedProducerFailure])
        XCTAssertTrue(completedSummaries(in: events).isEmpty)
        XCTAssertEqual(terminalEventCount(in: events), 1)
        guard let lastEvent = events.last,
              case .failed(_, .unexpectedProducerFailure) = lastEvent
        else {
            return XCTFail("Unexpected reader cancellation must be the sole terminal failure")
        }
    }

    func testExplicitConsumerTaskCancellationEmitsNoTerminalAndCancelsEveryChildRead() async throws {
        let root = try makeTemporaryDirectory()
        let paths = (0 ..< 8).map { String(format: "%04d.md", $0) }
        let reader = BlockingCancellationReader()
        let request = makeRequest(
            root: root,
            paths: paths,
            limits: WorkspaceSearchLimits(maximumConcurrentReads: 4)
        )
        let consumer = Task {
            await collectEvents(WorkspaceSearchService(reader: reader), request: request)
        }

        await reader.waitUntilCandidateStartCount(4)
        consumer.cancel()
        let events = await consumer.value
        await reader.waitUntilNoActiveReads()

        let candidateStartCount = await reader.candidateStartCount()
        let cancellationCount = await reader.cancellationCount()
        let activeReadCount = await reader.activeReadCount()
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(completedSummaries(in: events).count, 0)
        XCTAssertEqual(failures(in: events).count, 0)
        XCTAssertEqual(terminalEventCount(in: events), 0)
        XCTAssertEqual(candidateStartCount, 4)
        XCTAssertEqual(cancellationCount, candidateStartCount)
        XCTAssertEqual(activeReadCount, 0)
    }
}

extension WorkspaceSearchHardeningTests {
    private func assertGlobalOverflowEvents(
        _ events: [WorkspaceSearchEvent],
        fixture: GlobalOverflowFixture
    ) {
        let results = fileResults(in: events)
        XCTAssertEqual(results.map(\.relativePath), ["000-overflow.md"])
        XCTAssertEqual(results.flatMap(\.matches).count, fixture.globalMatchLimit)
        XCTAssertEqual(results.first?.isTruncated, true)
        XCTAssertEqual(skippedFileEvents(in: events), fixture.reportedSkippedFiles)
        XCTAssertEqual(progressEvents(in: events), [
            WorkspaceSearchProgress(completedFileCount: 3, candidateFileCount: 9),
            WorkspaceSearchProgress(completedFileCount: 6, candidateFileCount: 9),
            WorkspaceSearchProgress(completedFileCount: 9, candidateFileCount: 9),
        ])
        XCTAssertLessThanOrEqual(events.count, fixture.documentedEventBound)
        XCTAssertTrue(failures(in: events).isEmpty)
        XCTAssertEqual(terminalEventCount(in: events), 1)
        guard let lastEvent = events.last, case .completed = lastEvent else {
            return XCTFail("Completion must follow final accounting progress")
        }
    }

    private func assertGlobalOverflowSummary(
        _ summary: WorkspaceSearchSummary,
        skipped: [WorkspaceSearchSkippedFile],
        fixture: GlobalOverflowFixture
    ) {
        XCTAssertEqual(summary.candidateFileCount, fixture.paths.count)
        XCTAssertEqual(summary.searchedFileCount, 2)
        XCTAssertEqual(summary.skippedFileCount, 6)
        XCTAssertEqual(summary.ignoredFileCount, 1)
        XCTAssertEqual(summary.totalEmittedMatchCount, fixture.globalMatchLimit)
        XCTAssertEqual(summary.truncatedFilePaths, [])
        XCTAssertTrue(summary.isGloballyTruncated)
        XCTAssertEqual(summary.skippedFiles, skipped)
        XCTAssertEqual(summary.omittedSkippedFileCount, 2)
        XCTAssertTrue(summary.areSkippedFileDetailsTruncated)
    }

    private func assertGlobalOverflowReads(
        _ summary: WorkspaceSearchSummary,
        reader: GlobalTruncationAccountingReader,
        fixture: GlobalOverflowFixture
    ) async {
        XCTAssertEqual(summary.readInstrumentation.diskReadCount, 8)
        XCTAssertEqual(summary.readInstrumentation.diskReadByteCount, fixture.expectedReadBytes)
        XCTAssertLessThanOrEqual(summary.readInstrumentation.maximumConcurrentReads, fixture.readWindowLimit)
        XCTAssertLessThanOrEqual(summary.readInstrumentation.maximumBufferedReadCount, fixture.readWindowLimit)
        XCTAssertLessThanOrEqual(summary.readInstrumentation.maximumOutstandingReadCount, fixture.readWindowLimit)
        XCTAssertEqual(summary.readInstrumentation.maximumOutstandingReadCount, fixture.readWindowLimit)
        let candidateStartCount = await reader.candidateStartCount()
        let validReadCount = await reader.readCount(for: "600-valid.md")
        let ignoredReadCount = await reader.readCount(for: "ignored.md")
        let readerMaximumActiveReads = await reader.maximumActiveReadCount()
        XCTAssertEqual(candidateStartCount, 8)
        XCTAssertEqual(validReadCount, 1)
        XCTAssertEqual(ignoredReadCount, 0)
        XCTAssertLessThanOrEqual(readerMaximumActiveReads, fixture.readWindowLimit)
    }

    private func makeRequest(
        root: URL,
        paths: some Sequence<String>,
        limits: WorkspaceSearchLimits = .init()
    ) -> WorkspaceSearchRequest {
        WorkspaceSearchRequest(
            rootURL: root,
            rootIdentity: "hardening-root",
            snapshot: WorkspaceFileSnapshot(entries: paths.map { path in
                WorkspaceFileSnapshot.Entry(
                    relativePath: path,
                    kind: .markdown,
                    identity: path,
                    contentModificationDate: nil
                )
            }),
            workspaceGeneration: 29,
            queryGeneration: 31,
            query: TextSearchQuery(pattern: "needle"),
            limits: limits
        )
    }

    private func collectEvents(
        _ service: WorkspaceSearchService,
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

    private func skippedFileEvents(in events: [WorkspaceSearchEvent]) -> [WorkspaceSearchSkippedFile] {
        events.compactMap { event in
            guard case let .skippedFile(_, skippedFile) = event else { return nil }
            return skippedFile
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

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSearchHardeningTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct GlobalOverflowFixture {
    let paths = [
        "000-overflow.md",
        "100-disappeared.md",
        "200-unreadable.md",
        "300-invalid.md",
        "400-oversized.md",
        "410-disappeared-omitted.md",
        "420-unreadable-omitted.md",
        "500/node_modules/ignored.md",
        "600-valid.md",
    ]
    let skippedDetailLimit = 4
    let progressLimit = 3
    let globalMatchLimit = 2
    let readWindowLimit = 2
    let fileSizeLimit = 32

    var limits: WorkspaceSearchLimits {
        WorkspaceSearchLimits(
            maximumFileSizeBytes: fileSizeLimit,
            maximumMatchesPerFile: 10,
            maximumMatchesPerQuery: globalMatchLimit,
            maximumConcurrentReads: readWindowLimit,
            maximumReportedSkippedFiles: skippedDetailLimit,
            maximumProgressEvents: progressLimit
        )
    }

    var reportedSkippedFiles: [WorkspaceSearchSkippedFile] {
        [
            WorkspaceSearchSkippedFile(relativePath: "100-disappeared.md", reason: .disappeared),
            WorkspaceSearchSkippedFile(relativePath: "200-unreadable.md", reason: .unreadable),
            WorkspaceSearchSkippedFile(relativePath: "300-invalid.md", reason: .invalidUTF8),
            WorkspaceSearchSkippedFile(relativePath: "400-oversized.md", reason: .oversized(byteCount: 33)),
        ]
    }

    var documentedEventBound: Int {
        min(paths.count, globalMatchLimit)
            + min(paths.count, skippedDetailLimit)
            + min(max(paths.count, 1), progressLimit)
            + 1
    }

    var expectedReadBytes: Int {
        GlobalTruncationAccountingReader.overflowText.utf8.count
            + 1
            + (fileSizeLimit + 1)
            + GlobalTruncationAccountingReader.validText.utf8.count
    }
}
