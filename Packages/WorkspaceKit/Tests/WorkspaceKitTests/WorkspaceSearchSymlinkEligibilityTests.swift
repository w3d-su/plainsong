import MarkdownCore
@testable import WorkspaceKit
import XCTest

final class WorkspaceSearchSymlinkEligibilityTests: XCTestCase {
    func testDirtyOverlayRaceRejectsPhysicalTextTargetBeforeOverlaySelection() async throws {
        let root = try makeTemporaryDirectory()
        let candidate = root.appendingPathComponent("post.md")
        let textTarget = root.appendingPathComponent("target.txt")
        try "disk needle".write(to: candidate, atomically: true, encoding: .utf8)
        try "text target".write(to: textTarget, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let race = try await runDirtyOverlayRace(root: root) {
            try FileManager.default.removeItem(at: candidate)
            try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: textTarget)
        }

        assertRejectedOverlayRace(
            race,
            reason: .symlinkEscape
        )
    }

    func testDirtyOverlayRaceRejectsSymlinkEscapeBeforeOverlaySelection() async throws {
        let parent = try makeTemporaryDirectory()
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let outside = parent.appendingPathComponent("outside.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let candidate = root.appendingPathComponent("post.md")
        try "disk needle".write(to: candidate, atomically: true, encoding: .utf8)
        try "outside needle".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: parent) }

        let race = try await runDirtyOverlayRace(root: root) {
            try FileManager.default.removeItem(at: candidate)
            try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: outside)
        }

        assertRejectedOverlayRace(race, reason: .symlinkEscape)
    }

    func testDirtyOverlayRaceRejectsDisappearedTargetBeforeOverlaySelection() async throws {
        let root = try makeTemporaryDirectory()
        let candidate = root.appendingPathComponent("post.md")
        try "disk needle".write(to: candidate, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let race = try await runDirtyOverlayRace(root: root) {
            try FileManager.default.removeItem(at: candidate)
        }

        assertRejectedOverlayRace(race, reason: .disappeared)
    }

    func testValidPhysicalMarkdownUsesDirtyOverlayWithoutCandidateContentRead() async throws {
        let root = try makeTemporaryDirectory()
        let candidate = root.appendingPathComponent("post.md")
        try "disk without match".write(to: candidate, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let race = try await runDirtyOverlayRace(root: root) {}
        let result = try XCTUnwrap(fileResults(in: race.events).first)
        let summary = try XCTUnwrap(completedSummary(in: race.events))

        XCTAssertEqual(result.relativePath, "post.md")
        XCTAssertEqual(result.contentFingerprint, WorkspaceSearchContentFingerprint(text: "overlay needle"))
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertTrue(skippedFiles(in: race.events).isEmpty)
        XCTAssertEqual(summary.candidateFileCount, 1)
        XCTAssertEqual(summary.searchedFileCount, 1)
        XCTAssertEqual(summary.skippedFileCount, 0)
        XCTAssertEqual(summary.readInstrumentation.diskReadCount, 0)
        XCTAssertEqual(race.candidateReadCount, 0)
        XCTAssertEqual(finalProgress(in: race.events), WorkspaceSearchProgress(
            completedFileCount: 1,
            candidateFileCount: 1
        ))
    }

    func testRevalidatesPhysicalMarkdownKindImmediatelyBeforeDiskRead() async throws {
        let root = try makeTemporaryDirectory()
        let candidate = root.appendingPathComponent("post.md")
        let textTarget = root.appendingPathComponent("target.txt")
        try "needle".write(to: candidate, atomically: true, encoding: .utf8)
        try "needle in text".write(to: textTarget, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = PhysicalKindSwapReader()
        let request = try WorkspaceSearchRequest(
            rootAuthority: WorkspaceFileSystemRootAuthority(rootURL: root),
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
                reason: .symlinkEscape
            ),
        ])
        XCTAssertTrue(fileResults(in: events).isEmpty)
        let candidateReadCount = await reader.candidateReadCount()
        XCTAssertEqual(candidateReadCount, 0)
    }

    // swiftlint:disable:next function_body_length
    func testRealScannerCanonicalizesInitialInRootAliasesBeforeAnchoredReads() async throws {
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
        let request = try WorkspaceSearchRequest(
            rootAuthority: WorkspaceFileSystemRootAuthority(rootURL: root),
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
}

private extension WorkspaceSearchSymlinkEligibilityTests {
    func entry(_ path: String) -> WorkspaceFileSnapshot.Entry {
        WorkspaceFileSnapshot.Entry(
            relativePath: path,
            kind: .markdown,
            identity: path,
            contentModificationDate: nil
        )
    }

    func collectEvents(
        _ service: WorkspaceSearchService,
        request: WorkspaceSearchRequest
    ) async -> [WorkspaceSearchEvent] {
        var events: [WorkspaceSearchEvent] = []
        for await event in service.events(for: request) {
            events.append(event)
        }
        return events
    }

    func fileResults(in events: [WorkspaceSearchEvent]) -> [WorkspaceSearchFileResult] {
        events.compactMap {
            guard case let .fileResult(_, result) = $0 else { return nil }
            return result
        }
    }

    func skippedFiles(in events: [WorkspaceSearchEvent]) -> [WorkspaceSearchSkippedFile] {
        events.compactMap {
            guard case let .skippedFile(_, skippedFile) = $0 else { return nil }
            return skippedFile
        }
    }

    func completedSummary(in events: [WorkspaceSearchEvent]) -> WorkspaceSearchSummary? {
        events.compactMap {
            guard case let .completed(_, summary) = $0 else { return nil }
            return summary
        }.last
    }

    func finalProgress(in events: [WorkspaceSearchEvent]) -> WorkspaceSearchProgress? {
        events.compactMap { event in
            guard case let .progress(_, progress) = event else { return nil }
            return progress
        }.last
    }

    struct DirtyOverlayRaceResult {
        let events: [WorkspaceSearchEvent]
        let candidateReadCount: Int
    }

    func runDirtyOverlayRace(
        root: URL,
        mutate: () throws -> Void
    ) async throws -> DirtyOverlayRaceResult {
        let reader = PhysicalKindSwapReader()
        let request = try WorkspaceSearchRequest(
            rootAuthority: WorkspaceFileSystemRootAuthority(rootURL: root),
            snapshot: WorkspaceFileSnapshot(entries: [entry("post.md")]),
            workspaceGeneration: 1,
            queryGeneration: 1,
            query: TextSearchQuery(pattern: "needle"),
            dirtyOverlays: WorkspaceSearchOverlayCollection([
                WorkspaceSearchOverlay(relativePath: "post.md", text: "overlay needle"),
            ])
        )
        let consumer = Task {
            await collectEvents(WorkspaceSearchService(reader: reader), request: request)
        }

        await reader.waitUntilIgnoreRead()
        try mutate()
        await reader.releaseIgnoreRead()
        return await DirtyOverlayRaceResult(
            events: consumer.value,
            candidateReadCount: reader.candidateReadCount()
        )
    }

    func assertRejectedOverlayRace(
        _ race: DirtyOverlayRaceResult,
        reason: WorkspaceSearchSkipReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(fileResults(in: race.events).isEmpty, file: file, line: line)
        XCTAssertEqual(
            skippedFiles(in: race.events),
            [WorkspaceSearchSkippedFile(relativePath: "post.md", reason: reason)],
            file: file,
            line: line
        )
        let summary = completedSummary(in: race.events)
        XCTAssertEqual(summary?.candidateFileCount, 1, file: file, line: line)
        XCTAssertEqual(summary?.searchedFileCount, 0, file: file, line: line)
        XCTAssertEqual(summary?.skippedFileCount, 1, file: file, line: line)
        XCTAssertEqual(summary?.readInstrumentation.diskReadCount, 0, file: file, line: line)
        XCTAssertEqual(race.candidateReadCount, 0, file: file, line: line)
        XCTAssertEqual(
            finalProgress(in: race.events),
            WorkspaceSearchProgress(completedFileCount: 1, candidateFileCount: 1),
            file: file,
            line: line
        )
    }

    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSearchSymlinkEligibilityTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try WorkspaceFileSystemRootAuthority(rootURL: url).canonicalRootURL
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

    func validateFile(at location: WorkspaceFileSystemLocation) async throws {
        try await WorkspaceSearchDiskFileReader().validateFile(at: location)
    }

    func readFile(
        at location: WorkspaceFileSystemLocation,
        maximumByteCount: Int
    ) async throws -> Data {
        if location.fileURL.lastPathComponent.hasPrefix(".") {
            return try await readFile(
                at: location.fileURL,
                maximumByteCount: maximumByteCount
            )
        }
        let data = try await WorkspaceSearchDiskFileReader().readFile(
            at: location,
            maximumByteCount: maximumByteCount
        )
        candidateReads += 1
        return data
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
