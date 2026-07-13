import Foundation
import MarkdownCore
@testable import WorkspaceKit
import XCTest

final class WorkspaceSearchAnchoredRaceTests: XCTestCase {
    func testProductionDiskReadRejectsLeafReplacementInsideAndOutsideRoot() async throws {
        for targetIsInsideRoot in [true, false] {
            let parent = try makeTemporaryDirectory()
            let root = parent.appendingPathComponent("workspace", isDirectory: true)
            let candidate = root.appendingPathComponent("post.md")
            let target = targetIsInsideRoot
                ? root.appendingPathComponent("target.md")
                : parent.appendingPathComponent("outside.md")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "disk needle".write(to: candidate, atomically: true, encoding: .utf8)
            try "target sentinel needle".write(to: target, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: parent) }

            let mutation = AnchoredSearchRaceMutation {
                try FileManager.default.removeItem(at: candidate)
                try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: target)
            }
            let reader = WorkspaceSearchDiskFileReader { event in
                if event == .parentAnchored(0, "post.md") {
                    mutation.run()
                }
            }
            let request = request(root: root, relativePath: "post.md", pattern: "needle")

            let events = await collectEvents(WorkspaceSearchService(reader: reader), request: request)
            try mutation.rethrowIfFailed()

            XCTAssertTrue(fileResults(in: events).isEmpty)
            XCTAssertEqual(skippedFiles(in: events), [
                WorkspaceSearchSkippedFile(relativePath: "post.md", reason: .symlinkEscape),
            ])
            XCTAssertEqual(
                try String(contentsOf: target, encoding: .utf8),
                "target sentinel needle"
            )
        }
    }

    func testProductionDiskReadRejectsIntermediateSubstitutionInsideAndOutsideRoot() async throws {
        for targetIsInsideRoot in [true, false] {
            let parent = try makeTemporaryDirectory()
            let root = parent.appendingPathComponent("workspace", isDirectory: true)
            let nested = root.appendingPathComponent("nested", isDirectory: true)
            let target = targetIsInsideRoot
                ? root.appendingPathComponent("target", isDirectory: true)
                : parent.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try "disk needle".write(
                to: nested.appendingPathComponent("post.md"),
                atomically: true,
                encoding: .utf8
            )
            let targetFile = target.appendingPathComponent("post.md")
            try "target sentinel needle".write(to: targetFile, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: parent) }

            let mutation = AnchoredSearchRaceMutation {
                try FileManager.default.removeItem(at: nested)
                try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: target)
            }
            let reader = WorkspaceSearchDiskFileReader { event in
                if event == .rootAnchored(0, "nested/post.md") {
                    mutation.run()
                }
            }
            let request = request(root: root, relativePath: "nested/post.md", pattern: "needle")

            let events = await collectEvents(WorkspaceSearchService(reader: reader), request: request)
            try mutation.rethrowIfFailed()

            XCTAssertTrue(fileResults(in: events).isEmpty)
            XCTAssertEqual(skippedFiles(in: events), [
                WorkspaceSearchSkippedFile(relativePath: "nested/post.md", reason: .symlinkEscape),
            ])
            XCTAssertEqual(
                try String(contentsOf: targetFile, encoding: .utf8),
                "target sentinel needle"
            )
        }
    }

    func testProductionOverlayValidationRejectsIntermediateSubstitutionInsideAndOutsideRoot() async throws {
        for targetIsInsideRoot in [true, false] {
            let parent = try makeTemporaryDirectory()
            let root = parent.appendingPathComponent("workspace", isDirectory: true)
            let nested = root.appendingPathComponent("nested", isDirectory: true)
            let target = targetIsInsideRoot
                ? root.appendingPathComponent("target", isDirectory: true)
                : parent.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try "disk".write(
                to: nested.appendingPathComponent("post.md"),
                atomically: true,
                encoding: .utf8
            )
            try "target".write(
                to: target.appendingPathComponent("post.md"),
                atomically: true,
                encoding: .utf8
            )
            defer { try? FileManager.default.removeItem(at: parent) }

            let mutation = AnchoredSearchRaceMutation {
                try FileManager.default.removeItem(at: nested)
                try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: target)
            }
            let reader = WorkspaceSearchDiskFileReader { event in
                if event == .rootAnchored(0, "nested/post.md") {
                    mutation.run()
                }
            }
            let request = try WorkspaceSearchRequest(
                rootURL: root,
                snapshot: WorkspaceFileSnapshot(entries: [entry("nested/post.md")]),
                workspaceGeneration: 1,
                queryGeneration: 1,
                query: TextSearchQuery(pattern: "overlay needle"),
                dirtyOverlays: WorkspaceSearchOverlayCollection([
                    WorkspaceSearchOverlay(
                        relativePath: "nested/post.md",
                        text: "overlay needle"
                    ),
                ])
            )

            let events = await collectEvents(WorkspaceSearchService(reader: reader), request: request)
            try mutation.rethrowIfFailed()

            XCTAssertTrue(fileResults(in: events).isEmpty)
            XCTAssertEqual(skippedFiles(in: events), [
                WorkspaceSearchSkippedFile(relativePath: "nested/post.md", reason: .symlinkEscape),
            ])
            XCTAssertEqual(completedSummary(in: events)?.readInstrumentation.diskReadCount, 0)
        }
    }
}

private extension WorkspaceSearchAnchoredRaceTests {
    func request(
        root: URL,
        relativePath: String,
        pattern: String
    ) -> WorkspaceSearchRequest {
        WorkspaceSearchRequest(
            rootURL: root,
            snapshot: WorkspaceFileSnapshot(entries: [entry(relativePath)]),
            workspaceGeneration: 1,
            queryGeneration: 1,
            query: TextSearchQuery(pattern: pattern)
        )
    }

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

    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSearchAnchoredRaceTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class AnchoredSearchRaceMutation: @unchecked Sendable {
    private let lock = NSLock()
    private let operation: () throws -> Void
    private var didRun = false
    private var failure: Error?

    init(operation: @escaping () throws -> Void) {
        self.operation = operation
    }

    func run() {
        lock.withLock {
            guard !didRun else { return }
            didRun = true
            do {
                try operation()
            } catch {
                failure = error
            }
        }
    }

    func rethrowIfFailed() throws {
        try lock.withLock {
            if let failure {
                throw failure
            }
        }
    }
}
