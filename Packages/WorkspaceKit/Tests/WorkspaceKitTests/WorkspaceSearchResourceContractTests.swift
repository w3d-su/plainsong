import Foundation
import MarkdownCore
@testable import WorkspaceKit
import XCTest

final class WorkspaceSearchResourceContractTests: XCTestCase {
    func testEmptySuccessEmitsFinalProgressAndExactlyOneCompletedTerminal() async throws {
        let root = try makeTemporaryDirectory()
        let request = try makeRequest(root: root, paths: [])

        let events = await collectEvents(
            WorkspaceSearchService(reader: MissingContractReader()),
            request: request
        )

        XCTAssertEqual(progressEvents(in: events), [
            WorkspaceSearchProgress(completedFileCount: 0, candidateFileCount: 0),
        ])
        XCTAssertEqual(completedSummaries(in: events).count, 1)
        XCTAssertTrue(failures(in: events).isEmpty)
        XCTAssertEqual(terminalEventCount(in: events), 1)
        guard let lastEvent = events.last, case .completed = lastEvent else {
            return XCTFail("Completion must be the final event")
        }
    }

    func testInjectedUnexpectedFailureEmitsOneFailureAndCancelsEveryChildRead() async throws {
        let root = try makeTemporaryDirectory()
        let paths = ["0000.md", "0001.md", "0002.md"]
        let reader = BulkReadWindowReader(
            firstPath: "0000.md",
            firstDelayNanoseconds: 60_000_000_000
        )
        let request = try makeRequest(
            root: root,
            paths: paths,
            limits: WorkspaceSearchLimits(
                maximumConcurrentReads: 3,
                maximumProgressEvents: 1
            )
        )
        let service = WorkspaceSearchService(
            reader: reader,
            failurePoint: .afterReadOutcome(1)
        )

        let events = await collectEvents(service, request: request)
        let activeReadCount = await reader.activeReadCount()

        XCTAssertEqual(failures(in: events), [.unexpectedProducerFailure])
        XCTAssertTrue(completedSummaries(in: events).isEmpty)
        XCTAssertEqual(terminalEventCount(in: events), 1)
        XCTAssertEqual(activeReadCount, 0)
        guard let lastEvent = events.last,
              case .failed(_, .unexpectedProducerFailure) = lastEvent
        else {
            return XCTFail("Failure must be the final event")
        }
    }

    func testSlowFirstOfTwoThousandFilesBoundsReadWindowAndPreservesOrder() async throws {
        let root = try makeTemporaryDirectory()
        let expectedPaths = (0 ..< 2000).map { String(format: "%04d.md", $0) }
        let reader = BulkReadWindowReader(
            firstPath: expectedPaths[0],
            firstDelayNanoseconds: 200_000_000
        )
        let request = try makeRequest(
            root: root,
            paths: expectedPaths.reversed(),
            limits: WorkspaceSearchLimits(
                maximumConcurrentReads: 4,
                maximumProgressEvents: 5
            )
        )

        let events = await collectEvents(WorkspaceSearchService(reader: reader), request: request)
        let summary = try XCTUnwrap(completedSummaries(in: events).only)
        let maximumActiveReadCount = await reader.maximumActiveReadCount()

        XCTAssertEqual(fileResults(in: events).map(\.relativePath), expectedPaths)
        XCTAssertEqual(summary.readInstrumentation.diskReadCount, expectedPaths.count)
        XCTAssertLessThanOrEqual(summary.readInstrumentation.maximumConcurrentReads, 4)
        XCTAssertLessThanOrEqual(summary.readInstrumentation.maximumBufferedReadCount, 4)
        XCTAssertLessThanOrEqual(summary.readInstrumentation.maximumOutstandingReadCount, 4)
        XCTAssertEqual(summary.readInstrumentation.maximumOutstandingReadCount, 4)
        XCTAssertLessThanOrEqual(maximumActiveReadCount, 4)
    }

    func testCancellationReleasesSlowAndBufferedReadWindowWithoutTerminalEvent() async throws {
        let root = try makeTemporaryDirectory()
        let paths = (0 ..< 2000).map { String(format: "%04d.md", $0) }
        let reader = BulkReadWindowReader(
            firstPath: paths[0],
            firstDelayNanoseconds: 60_000_000_000
        )
        let request = try makeRequest(
            root: root,
            paths: paths,
            limits: WorkspaceSearchLimits(
                maximumConcurrentReads: 4,
                maximumProgressEvents: 5
            )
        )
        let consumer = Task {
            await collectEvents(WorkspaceSearchService(reader: reader), request: request)
        }

        await reader.waitUntilCandidateStartCount(4)
        await reader.waitUntilFastCompletionCount(3)
        consumer.cancel()
        let events = await consumer.value
        await reader.waitUntilNoActiveReads()
        let activeReadCount = await reader.activeReadCount()
        let candidateStartCount = await reader.candidateStartCount()

        XCTAssertTrue(completedSummaries(in: events).isEmpty)
        XCTAssertTrue(failures(in: events).isEmpty)
        XCTAssertEqual(terminalEventCount(in: events), 0)
        XCTAssertEqual(activeReadCount, 0)
        XCTAssertLessThanOrEqual(candidateStartCount, 4)
    }

    func testSlowConsumerReceivesBoundedLosslessResultsDetailsProgressAndTerminal() async throws {
        let root = try makeTemporaryDirectory()
        let matchingPaths = (0 ..< 400).map { String(format: "match-%04d.md", $0) }
        let skippedPaths = (0 ..< 600).map { String(format: "skip-%04d.md", $0) }
        let allPaths = matchingPaths + skippedPaths
        let skippedDetailLimit = 7
        let progressLimit = 5
        let request = try makeRequest(
            root: root,
            paths: allPaths.reversed(),
            limits: WorkspaceSearchLimits(
                maximumMatchesPerFile: 1,
                maximumMatchesPerQuery: matchingPaths.count,
                maximumConcurrentReads: 4,
                maximumReportedSkippedFiles: skippedDetailLimit,
                maximumProgressEvents: progressLimit
            )
        )

        let events = await collectEvents(
            WorkspaceSearchService(reader: MixedContractReader()),
            request: request,
            consumerDelayNanoseconds: 100_000
        )
        let results = fileResults(in: events)
        let skipped = skippedFileEvents(in: events)
        let progress = progressEvents(in: events)
        let summary = try XCTUnwrap(completedSummaries(in: events).only)
        let eventBound = results.count
            + min(summary.skippedFileCount, skippedDetailLimit)
            + progressLimit
            + 1

        XCTAssertEqual(results.map(\.relativePath), matchingPaths)
        XCTAssertEqual(results.flatMap(\.matches).count, matchingPaths.count)
        XCTAssertEqual(skipped.map(\.relativePath), Array(skippedPaths.prefix(skippedDetailLimit)))
        assertCoalescedProgress(progress)
        XCTAssertEqual(summary.candidateFileCount, allPaths.count)
        XCTAssertEqual(summary.searchedFileCount, matchingPaths.count)
        XCTAssertEqual(summary.skippedFileCount, skippedPaths.count)
        XCTAssertEqual(summary.ignoredFileCount, 0)
        XCTAssertEqual(summary.totalEmittedMatchCount, matchingPaths.count)
        XCTAssertEqual(summary.skippedFiles, skipped)
        XCTAssertEqual(summary.omittedSkippedFileCount, skippedPaths.count - skippedDetailLimit)
        XCTAssertTrue(summary.areSkippedFileDetailsTruncated)
        XCTAssertLessThanOrEqual(events.count, eventBound)
        XCTAssertEqual(events.count, matchingPaths.count + skippedDetailLimit + progressLimit + 1)
        XCTAssertEqual(completedSummaries(in: events).count, 1)
        XCTAssertTrue(failures(in: events).isEmpty)
        XCTAssertEqual(terminalEventCount(in: events), 1)
        guard let lastEvent = events.last, case .completed = lastEvent else {
            return XCTFail("Completion must be lossless and final")
        }
    }
}

extension WorkspaceSearchResourceContractTests {
    private func makeRequest(
        root: URL,
        paths: some Sequence<String>,
        limits: WorkspaceSearchLimits = .init()
    ) throws -> WorkspaceSearchRequest {
        try WorkspaceSearchRequest(
            rootAuthority: WorkspaceFileSystemRootAuthority(rootURL: root),
            rootIdentity: "resource-contract-root",
            snapshot: WorkspaceFileSnapshot(entries: paths.map { path in
                WorkspaceFileSnapshot.Entry(
                    relativePath: path,
                    kind: .markdown,
                    identity: path,
                    contentModificationDate: nil
                )
            }),
            workspaceGeneration: 17,
            queryGeneration: 23,
            query: TextSearchQuery(pattern: "needle"),
            limits: limits
        )
    }

    private func collectEvents(
        _ service: WorkspaceSearchService,
        request: WorkspaceSearchRequest,
        consumerDelayNanoseconds: UInt64 = 0
    ) async -> [WorkspaceSearchEvent] {
        var events: [WorkspaceSearchEvent] = []
        for await event in service.events(for: request) {
            events.append(event)
            if consumerDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: consumerDelayNanoseconds)
            }
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

    private func assertCoalescedProgress(_ progress: [WorkspaceSearchProgress]) {
        XCTAssertEqual(progress, [
            WorkspaceSearchProgress(completedFileCount: 200, candidateFileCount: 1000),
            WorkspaceSearchProgress(completedFileCount: 400, candidateFileCount: 1000),
            WorkspaceSearchProgress(completedFileCount: 600, candidateFileCount: 1000),
            WorkspaceSearchProgress(completedFileCount: 800, candidateFileCount: 1000),
            WorkspaceSearchProgress(completedFileCount: 1000, candidateFileCount: 1000),
        ])
        XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy { pair in
            pair.0.completedFileCount < pair.1.completedFileCount
        })
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
            .appendingPathComponent("WorkspaceSearchResourceContractTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try WorkspaceFileSystemRootAuthority(rootURL: url).canonicalRootURL
    }
}
