import Foundation
import MarkdownCore
@testable import WorkspaceKit
import XCTest

final class WorkspaceSearchFileAuthorityTests: XCTestCase {
    func testDiskPostflightReplacementCannotPublishDetachedResult() async throws {
        let root = try makeTemporaryDirectory()
        let candidate = root.appendingPathComponent("post.md")
        let replacement = root.appendingPathComponent("replacement.md")
        try "old needle".write(to: candidate, atomically: true, encoding: .utf8)
        try "replacement text".write(to: replacement, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let mutation = FileAuthorityRaceMutation {
            try FileManager.default.removeItem(at: candidate)
            try FileManager.default.moveItem(at: replacement, to: candidate)
        }
        let reader = WorkspaceSearchDiskFileReader { event in
            if event == .postflight(0, "post.md") {
                mutation.run()
            }
        }
        let request = try request(root: root, overlay: nil)

        let events = await collectEvents(WorkspaceSearchService(reader: reader), request: request)
        try mutation.rethrowIfFailed()

        XCTAssertEqual(try String(contentsOf: candidate, encoding: .utf8), "replacement text")
        XCTAssertTrue(fileResults(in: events).isEmpty)
        XCTAssertEqual(completedSummary(in: events)?.skippedFiles, [
            WorkspaceSearchSkippedFile(relativePath: "post.md", reason: .unreadable),
        ])
        XCTAssertEqual(completedSummary(in: events)?.readInstrumentation.diskReadCount, 1)
    }

    func testOverlayPostflightReplacementCannotPublishDetachedResult() async throws {
        let root = try makeTemporaryDirectory()
        let candidate = root.appendingPathComponent("post.md")
        let replacement = root.appendingPathComponent("replacement.md")
        try "disk text".write(to: candidate, atomically: true, encoding: .utf8)
        try "replacement text".write(to: replacement, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let mutation = FileAuthorityRaceMutation {
            try FileManager.default.removeItem(at: candidate)
            try FileManager.default.moveItem(at: replacement, to: candidate)
        }
        let reader = WorkspaceSearchDiskFileReader { event in
            if event == .postflight(0, "post.md") {
                mutation.run()
            }
        }
        let overlay = try WorkspaceSearchOverlay(relativePath: "post.md", text: "overlay needle")
        let request = try request(root: root, overlay: overlay)

        let events = await collectEvents(WorkspaceSearchService(reader: reader), request: request)
        try mutation.rethrowIfFailed()

        XCTAssertEqual(try String(contentsOf: candidate, encoding: .utf8), "replacement text")
        XCTAssertTrue(fileResults(in: events).isEmpty)
        XCTAssertEqual(completedSummary(in: events)?.skippedFiles, [
            WorkspaceSearchSkippedFile(relativePath: "post.md", reason: .unreadable),
        ])
        XCTAssertEqual(completedSummary(in: events)?.readInstrumentation.diskReadCount, 0)
    }

    func testDiskResultCarriesIdentityFromExactReadDescriptor() async throws {
        let root = try makeTemporaryDirectory()
        let candidate = root.appendingPathComponent("post.md")
        try "disk needle".write(to: candidate, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalIdentity = try regularIdentity(at: candidate)
        let request = try request(root: root, overlay: nil)

        let events = await collectEvents(WorkspaceSearchService(), request: request)
        let result = try XCTUnwrap(fileResults(in: events).first)
        let authority = try XCTUnwrap(result.fileAuthority)

        XCTAssertEqual(result.contentFingerprint, WorkspaceSearchContentFingerprint(text: "disk needle"))
        XCTAssertEqual(authority.identity, originalIdentity)
        XCTAssertEqual(authority.location, try request.rootAuthority.location(relativePath: "post.md"))
        try assertExpectedIdentityLoadSucceeds(authority, expectedText: "disk needle")
    }

    func testOverlayResultCarriesIdentityFromExactValidationDescriptor() async throws {
        let root = try makeTemporaryDirectory()
        let candidate = root.appendingPathComponent("post.md")
        try "disk text".write(to: candidate, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalIdentity = try regularIdentity(at: candidate)
        let overlay = try WorkspaceSearchOverlay(relativePath: "post.md", text: "overlay needle")
        let request = try request(root: root, overlay: overlay)

        let events = await collectEvents(WorkspaceSearchService(), request: request)
        let result = try XCTUnwrap(fileResults(in: events).first)
        let authority = try XCTUnwrap(result.fileAuthority)

        XCTAssertEqual(result.contentFingerprint, WorkspaceSearchContentFingerprint(text: overlay.text))
        XCTAssertEqual(authority.identity, originalIdentity)
        XCTAssertEqual(authority.location, try request.rootAuthority.location(relativePath: "post.md"))
        XCTAssertEqual(completedSummary(in: events)?.readInstrumentation.diskReadCount, 0)
        try assertExpectedIdentityLoadSucceeds(authority, expectedText: "disk text")
    }

    func testRequestRetainsCallerRootAuthorityAfterRootPathReplacement() async throws {
        let root = try makeTemporaryDirectory()
        let movedRoot = root.deletingLastPathComponent()
            .appendingPathComponent("moved-\(UUID().uuidString)", isDirectory: true)
        let outsideRoot = try makeTemporaryDirectory()
        try "trusted needle".write(
            to: root.appendingPathComponent("post.md"),
            atomically: true,
            encoding: .utf8
        )
        try "untrusted needle".write(
            to: outsideRoot.appendingPathComponent("post.md"),
            atomically: true,
            encoding: .utf8
        )
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        try FileManager.default.moveItem(at: root, to: movedRoot)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outsideRoot)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: movedRoot)
            try? FileManager.default.removeItem(at: outsideRoot)
        }

        let request = try WorkspaceSearchRequest(
            rootURL: root,
            rootAuthority: authority,
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
            query: TextSearchQuery(pattern: "needle")
        )

        let events = await collectEvents(WorkspaceSearchService(), request: request)

        XCTAssertEqual(request.rootAuthority, authority)
        XCTAssertTrue(fileResults(in: events).isEmpty)
        XCTAssertEqual(completedSummary(in: events)?.skippedFileCount, 1)
    }
}

private extension WorkspaceSearchFileAuthorityTests {
    func request(
        root: URL,
        overlay: WorkspaceSearchOverlay?
    ) throws -> WorkspaceSearchRequest {
        let overlays = if let overlay {
            try WorkspaceSearchOverlayCollection([overlay])
        } else {
            WorkspaceSearchOverlayCollection.empty
        }
        return try WorkspaceSearchRequest(
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
            query: TextSearchQuery(pattern: "needle"),
            dirtyOverlays: overlays
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

    func completedSummary(in events: [WorkspaceSearchEvent]) -> WorkspaceSearchSummary? {
        events.compactMap {
            guard case let .completed(_, summary) = $0 else { return nil }
            return summary
        }.last
    }

    func regularIdentity(at url: URL) throws -> WorkspaceFileSystemIdentity {
        let location = try WorkspaceFileSystemLocation(fileURL: url)
        guard case let .regular(identity) = WorkspaceNoFollowFileInspector.status(at: location) else {
            throw CocoaError(.fileReadUnknown)
        }
        return identity
    }

    func assertExpectedIdentityLoadSucceeds(
        _ authority: WorkspaceSearchFileAuthority,
        expectedText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let result = try MarkdownFileStore().load(
            at: authority.location,
            expecting: authority.identity
        )
        XCTAssertEqual(result.file.text, expectedText, file: file, line: line)
        XCTAssertEqual(result.metadata.identity, authority.identity, file: file, line: line)
    }

    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSearchFileAuthorityTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try WorkspaceFileSystemRootAuthority(rootURL: url).canonicalRootURL
    }
}

private final class FileAuthorityRaceMutation: @unchecked Sendable {
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
