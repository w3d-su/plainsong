import Foundation
import MarkdownCore
@testable import WorkspaceKit
import XCTest

/// Direct gate that the production disk reader and MarkdownCore matcher run off the main actor.
///
/// Creating the stream on the main actor matches the AppState consumer. Observations are taken
/// from the live `readChunk` diagnostic and the pipeline `.beforeMatching` checkpoint, not from
/// the service's declared task priority.
final class WorkspaceSearchOffMainActorTests: XCTestCase {
    func testProductionDiskReadAndMatchingExecuteOffTheMainActor() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let needle = "PLAINSONG_OFF_MAIN_NEEDLE"
        try "prefix \(needle) suffix\n".write(
            to: root.appendingPathComponent("post.md"),
            atomically: true,
            encoding: .utf8
        )

        let readThreads = ThreadObservationRecorder()
        let matchThreads = ThreadObservationRecorder()
        let service = makeInstrumentedService(
            readThreads: readThreads,
            matchThreads: matchThreads
        )
        let events = try await collectEvents(
            from: service,
            request: makePostRequest(root: root, needle: needle)
        )
        let results = fileResults(in: events)
        XCTAssertEqual(results.map(\.relativePath), ["post.md"])
        XCTAssertEqual(results.first?.matches.count, 1)
        XCTAssertEqual(results.first?.matches.first?.preview.contains(needle), true)
        assertAllOffMain(readThreads, label: "WorkspaceSearchDiskFileReader.readChunk")
        assertAllOffMain(matchThreads, label: "TextSearchEngine.matches")
        XCTAssertEqual(readThreads.mainThreadObservations.count, 1)
        XCTAssertEqual(matchThreads.mainThreadObservations.count, 1)
    }

    private func makeInstrumentedService(
        readThreads: ThreadObservationRecorder,
        matchThreads: ThreadObservationRecorder
    ) -> WorkspaceSearchService {
        let reader = WorkspaceSearchDiskFileReader { event in
            if case .readChunk = event {
                readThreads.recordCurrentThread()
            }
        }
        return WorkspaceSearchService(reader: reader) { checkpoint in
            if case .beforeMatching = checkpoint {
                matchThreads.recordCurrentThread()
            }
        }
    }

    private func makePostRequest(root: URL, needle: String) throws -> WorkspaceSearchRequest {
        try WorkspaceSearchRequest(
            rootAuthority: WorkspaceFileSystemRootAuthority(rootURL: root),
            snapshot: WorkspaceFileSnapshot(entries: [
                WorkspaceFileSnapshot.Entry(
                    relativePath: "post.md",
                    kind: .markdown,
                    identity: "post.md",
                    contentModificationDate: nil
                ),
            ]),
            workspaceGeneration: 1,
            queryGeneration: 1,
            query: TextSearchQuery(pattern: needle)
        )
    }

    private func collectEvents(
        from service: WorkspaceSearchService,
        request: WorkspaceSearchRequest
    ) async -> [WorkspaceSearchEvent] {
        let stream = await MainActor.run {
            service.events(for: request)
        }
        var events: [WorkspaceSearchEvent] = []
        for await event in stream {
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

    private func assertAllOffMain(_ recorder: ThreadObservationRecorder, label: String) {
        XCTAssertFalse(recorder.mainThreadObservations.isEmpty, "\(label) produced no observations")
        XCTAssertTrue(
            recorder.mainThreadObservations.allSatisfy { !$0 },
            "\(label) ran on the main actor"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSearchOffMainActorTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try WorkspaceFileSystemRootAuthority(rootURL: url).canonicalRootURL
    }
}

private final class ThreadObservationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    var mainThreadObservations: [Bool] {
        lock.withLock { storage }
    }

    func recordCurrentThread() {
        lock.withLock { storage.append(Thread.isMainThread) }
    }
}
