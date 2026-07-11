import MarkdownCore
@testable import WorkspaceKit
import XCTest

final class WorkspaceSearchSymlinkEligibilityTests: XCTestCase {
    func testRevalidatesPhysicalMarkdownKindImmediatelyBeforeDiskRead() async throws {
        let root = try makeTemporaryDirectory()
        let candidate = root.appendingPathComponent("post.md")
        let textTarget = root.appendingPathComponent("target.txt")
        try "needle".write(to: candidate, atomically: true, encoding: .utf8)
        try "needle in text".write(to: textTarget, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = PhysicalKindSwapReader()
        let request = WorkspaceSearchRequest(
            rootURL: root,
            snapshot: WorkspaceFileSnapshot(entries: [entry("post.md")]),
            workspaceGeneration: 1,
            queryGeneration: 1,
            query: TextSearchQuery(pattern: "needle")
        )
        let consumer = Task {
            await collectEvents(WorkspaceSearchService(reader: reader), request: request)
        }

        await reader.waitUntilIgnoreRead()
        try FileManager.default.removeItem(at: candidate)
        try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: textTarget)
        await reader.releaseIgnoreRead()
        let events = await consumer.value

        XCTAssertEqual(skippedFiles(in: events), [
            WorkspaceSearchSkippedFile(
                relativePath: "post.md",
                reason: .unsupportedPhysicalFileKind
            ),
        ])
        XCTAssertTrue(fileResults(in: events).isEmpty)
        let candidateReadCount = await reader.candidateReadCount()
        XCTAssertEqual(candidateReadCount, 0)
    }

    // swiftlint:disable:next function_body_length
    func testRealScannerRevalidatesPhysicalMarkdownKindAfterSymlinkResolution() async throws {
        let parent = try makeTemporaryDirectory()
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let outside = parent.appendingPathComponent("outside.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let markdownTarget = root.appendingPathComponent("target.md")
        let textTarget = root.appendingPathComponent("target.txt")
        try "one physical needle".write(to: markdownTarget, atomically: true, encoding: .utf8)
        try "must not publish needle".write(to: textTarget, atomically: true, encoding: .utf8)
        try "outside needle".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("alias-target.md"),
            withDestinationURL: markdownTarget
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("alias-text.md"),
            withDestinationURL: textTarget
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.md"),
            withDestinationURL: outside
        )

        let snapshot = try await WorkspaceDirectoryScanner().snapshot(root: root)
        let request = WorkspaceSearchRequest(
            rootURL: root,
            rootIdentity: "real-symlink-root",
            snapshot: snapshot,
            workspaceGeneration: 4,
            queryGeneration: 5,
            query: TextSearchQuery(pattern: "needle")
        )
        let events = await collectEvents(WorkspaceSearchService(), request: request)
        let summary = try XCTUnwrap(completedSummary(in: events))
        let finalProgress = events.compactMap { event -> WorkspaceSearchProgress? in
            guard case let .progress(_, progress) = event else { return nil }
            return progress
        }.last

        XCTAssertEqual(fileResults(in: events).map(\.relativePath), ["target.md"])
        XCTAssertEqual(skippedFiles(in: events), [
            WorkspaceSearchSkippedFile(
                relativePath: "alias-text.md",
                reason: .unsupportedPhysicalFileKind
            ),
            WorkspaceSearchSkippedFile(relativePath: "escape.md", reason: .symlinkEscape),
        ])
        XCTAssertEqual(summary.candidateFileCount, 3)
        XCTAssertEqual(summary.searchedFileCount, 1)
        XCTAssertEqual(summary.skippedFileCount, 2)
        XCTAssertEqual(summary.ignoredFileCount, 0)
        XCTAssertEqual(summary.totalEmittedMatchCount, 1)
        XCTAssertEqual(
            finalProgress,
            WorkspaceSearchProgress(completedFileCount: 3, candidateFileCount: 3)
        )
    }

    private func entry(_ path: String) -> WorkspaceFileSnapshot.Entry {
        WorkspaceFileSnapshot.Entry(
            relativePath: path,
            kind: .markdown,
            identity: path,
            contentModificationDate: nil
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
        events.compactMap {
            guard case let .fileResult(_, result) = $0 else { return nil }
            return result
        }
    }

    private func skippedFiles(in events: [WorkspaceSearchEvent]) -> [WorkspaceSearchSkippedFile] {
        events.compactMap {
            guard case let .skippedFile(_, skippedFile) = $0 else { return nil }
            return skippedFile
        }
    }

    private func completedSummary(in events: [WorkspaceSearchEvent]) -> WorkspaceSearchSummary? {
        events.compactMap {
            guard case let .completed(_, summary) = $0 else { return nil }
            return summary
        }.last
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSearchSymlinkEligibilityTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor PhysicalKindSwapReader: WorkspaceSearchFileReading {
    private var ignoreReadStarted = false
    private var ignoreReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var ignoreReadContinuation: CheckedContinuation<Void, Never>?
    private var candidateReads = 0

    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data {
        if url.lastPathComponent == ".gitignore" {
            ignoreReadStarted = true
            let waiters = ignoreReadWaiters
            ignoreReadWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                ignoreReadContinuation = continuation
            }
            throw WorkspaceSearchFileReadError.disappeared
        }
        if url.lastPathComponent == ".ignore" {
            throw WorkspaceSearchFileReadError.disappeared
        }

        candidateReads += 1
        return Data("needle".utf8.prefix(maximumByteCount))
    }

    func waitUntilIgnoreRead() async {
        if ignoreReadStarted { return }
        await withCheckedContinuation { continuation in
            ignoreReadWaiters.append(continuation)
        }
    }

    func releaseIgnoreRead() {
        ignoreReadContinuation?.resume()
        ignoreReadContinuation = nil
    }

    func candidateReadCount() -> Int {
        candidateReads
    }
}
