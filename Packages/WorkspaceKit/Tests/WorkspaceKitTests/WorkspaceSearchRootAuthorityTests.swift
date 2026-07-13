import Foundation
import MarkdownCore
@testable import WorkspaceKit
import XCTest

final class WorkspaceSearchRootAuthorityTests: XCTestCase {
    func testMismatchedRootURLAndAuthorityAreRejectedBeforeRequestExists() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let rootA = parent.appendingPathComponent("A", isDirectory: true)
        let rootB = parent.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: rootA)

        XCTAssertThrowsError(
            try WorkspaceSearchRequest(
                rootURL: rootB,
                rootAuthority: authority,
                snapshot: WorkspaceFileSnapshot(entries: []),
                workspaceGeneration: 1,
                queryGeneration: 1,
                query: TextSearchQuery(pattern: "needle")
            )
        ) { error in
            XCTAssertEqual(error as? WorkspaceSearchRequestError, .rootAuthorityMismatch)
        }
    }

    func testRetargetedRootAndReplacementSnapshotNeverMixAAndB() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let rootA = parent.appendingPathComponent("A", isDirectory: true)
        let rootB = parent.appendingPathComponent("B", isDirectory: true)
        let selected = parent.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        try "needle disk A".write(
            to: rootA.appendingPathComponent("shared.md"),
            atomically: true,
            encoding: .utf8
        )
        try "needle ignored A".write(
            to: rootA.appendingPathComponent("ignored.md"),
            atomically: true,
            encoding: .utf8
        )
        try "ignored.md\n".write(
            to: rootA.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "no match in B".write(
            to: rootB.appendingPathComponent("shared.md"),
            atomically: true,
            encoding: .utf8
        )
        try "needle ignored B".write(
            to: rootB.appendingPathComponent("ignored.md"),
            atomically: true,
            encoding: .utf8
        )
        try "needle only B".write(
            to: rootB.appendingPathComponent("b.md"),
            atomically: true,
            encoding: .utf8
        )
        try "shared.md\n".write(
            to: rootB.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: rootA)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: selected)

        let replacementSnapshot = try await WorkspaceDirectoryScanner().snapshot(root: rootB)
        try FileManager.default.removeItem(at: selected)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: rootB)
        let overlays = try WorkspaceSearchOverlayCollection(validating: [
            "shared.md": WorkspaceSearchOverlay(
                relativePath: "shared.md",
                text: "needle overlay for A"
            ),
            "b.md": WorkspaceSearchOverlay(
                relativePath: "b.md",
                text: "needle overlay from B"
            ),
        ])
        let request = WorkspaceSearchRequest(
            rootAuthority: authority,
            rootIdentity: "generation-token-only",
            snapshot: replacementSnapshot,
            workspaceGeneration: 7,
            queryGeneration: 9,
            query: TextSearchQuery(pattern: "needle"),
            dirtyOverlays: overlays
        )

        let events = await collectEvents(request)
        let results = events.compactMap { event -> WorkspaceSearchFileResult? in
            guard case let .fileResult(_, result) = event else { return nil }
            return result
        }
        let skipped = events.compactMap { event -> WorkspaceSearchSkippedFile? in
            guard case let .skippedFile(_, skipped) = event else { return nil }
            return skipped
        }
        let summary = events.compactMap { event -> WorkspaceSearchSummary? in
            guard case let .completed(_, summary) = event else { return nil }
            return summary
        }.last

        XCTAssertEqual(results.map(\.relativePath), ["shared.md"])
        XCTAssertEqual(
            results.first?.contentFingerprint,
            WorkspaceSearchContentFingerprint(text: "needle overlay for A")
        )
        XCTAssertEqual(results.first?.fileAuthority?.location.rootAuthority, authority)
        XCTAssertEqual(skipped, [
            WorkspaceSearchSkippedFile(relativePath: "b.md", reason: .disappeared),
        ])
        XCTAssertEqual(summary?.ignoredFileCount, 1)
        XCTAssertEqual(summary?.searchedFileCount, 1)
        XCTAssertEqual(summary?.skippedFileCount, 1)
        XCTAssertFalse(results.contains { $0.relativePath == "b.md" })
    }

    func testMainActorRequestConstructionDoesNotReopenOrValidateRoot() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let moved = parent.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recorder = RootCaptureEventRecorder()
        let authority = try WorkspaceFileSystemRootAuthority(
            rootURL: root,
            hooks: .init(eventHandler: { recorder.record($0) })
        )
        let capturedEvents = recorder.events
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let request = await MainActor.run {
            WorkspaceSearchRequest(
                rootAuthority: authority,
                snapshot: WorkspaceFileSnapshot(entries: []),
                workspaceGeneration: 1,
                queryGeneration: 2,
                query: TextSearchQuery(pattern: "needle")
            )
        }

        XCTAssertEqual(request.rootAuthority, authority)
        XCTAssertEqual(recorder.events, capturedEvents)
    }

    func testAuthorityCaptureRunsOutsideMainActor() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let recorder = RootCaptureThreadRecorder()

        let captureTask = Task { @MainActor in
            try await WorkspaceFileSystemRootAuthority.capture(
                rootURL: parent,
                hooks: .init(eventHandler: { _ in recorder.recordCurrentThread() })
            )
        }
        _ = try await captureTask.value

        XCTAssertFalse(recorder.mainThreadObservations.isEmpty)
        XCTAssertTrue(recorder.mainThreadObservations.allSatisfy { !$0 })
    }

    private func collectEvents(_ request: WorkspaceSearchRequest) async -> [WorkspaceSearchEvent] {
        var events: [WorkspaceSearchEvent] = []
        for await event in WorkspaceSearchService().events(for: request) {
            events.append(event)
        }
        return events
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSearchRootAuthorityTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class RootCaptureEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [WorkspaceFileSystemRootAuthority.CaptureEvent] = []

    var events: [WorkspaceFileSystemRootAuthority.CaptureEvent] {
        lock.withLock { storage }
    }

    func record(_ event: WorkspaceFileSystemRootAuthority.CaptureEvent) {
        lock.withLock { storage.append(event) }
    }
}

private final class RootCaptureThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    var mainThreadObservations: [Bool] {
        lock.withLock { storage }
    }

    func recordCurrentThread() {
        lock.withLock { storage.append(Thread.isMainThread) }
    }
}
