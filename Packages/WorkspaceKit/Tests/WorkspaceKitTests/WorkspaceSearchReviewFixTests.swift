import MarkdownCore
@testable import WorkspaceKit
import XCTest

final class WorkspaceSearchReviewFixTests: XCTestCase {
    func testFileBelowUnreadableDirectoryIsSkippedAsUnreadableNotPathTraversal() async throws {
        let root = try makeTemporaryDirectory()
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try "needle".write(to: locked.appendingPathComponent("post.md"), atomically: true, encoding: .utf8)
        try "needle".write(to: root.appendingPathComponent("open.md"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        }
        try XCTSkipIf(
            FileManager.default.isReadableFile(atPath: locked.appendingPathComponent("post.md").path),
            "Running as a user that bypasses file permissions"
        )

        let events = try await collectEvents(
            WorkspaceSearchService(reader: WorkspaceSearchDiskFileReader()),
            request: request(root: root, paths: ["locked/post.md", "open.md"])
        )

        XCTAssertEqual(fileResults(in: events).map(\.relativePath), ["open.md"])
        XCTAssertEqual(skippedFiles(in: events), [
            WorkspaceSearchSkippedFile(relativePath: "locked/post.md", reason: .unreadable),
        ])
    }

    /// `/` followed by a combining mark is one `Character`, so a `Character` count of the
    /// base-directory prefix does not equal its length inside the candidate path.
    func testNestedIgnoreRuleMatchesNameStartingWithCombiningMark() async throws {
        let root = try makeTemporaryDirectory()
        let ignored = "notes/\u{301}draft.md"
        let reader = MapReader(root: root, files: [
            "notes/.gitignore": "\u{301}draft.md\n",
            ignored: "needle",
            "notes/kept.md": "needle",
        ])

        let events = try await collectEvents(
            WorkspaceSearchService(reader: reader),
            request: request(root: root, paths: [ignored, "notes/kept.md"])
        )

        XCTAssertEqual(fileResults(in: events).map(\.relativePath), ["notes/kept.md"])
        XCTAssertEqual(completedSummary(in: events)?.ignoredFileCount, 1)
    }

    func testMissingIgnoreFilesDoNotConsumeTheIgnoreFileLimit() async throws {
        let root = try makeTemporaryDirectory()
        // 70 sibling directories without ignore files sort before `zz`, whose `.gitignore`
        // is the only one that exists: 142 probes precede it, above the default limit of 128.
        var paths = (0 ..< 70).map { String(format: "dir%02d/post.md", $0) }
        paths.append("zz/secret.md")
        var files = Dictionary(uniqueKeysWithValues: paths.map { ($0, "needle") })
        files["zz/.gitignore"] = "secret.md\n"
        XCTAssertEqual(WorkspaceSearchLimits.defaultMaximumIgnoreFiles, 128)

        let events = try await collectEvents(
            WorkspaceSearchService(reader: MapReader(root: root, files: files)),
            request: request(root: root, paths: paths)
        )

        let results = fileResults(in: events).map(\.relativePath)
        XCTAssertEqual(results.count, 70)
        XCTAssertFalse(results.contains("zz/secret.md"))
        XCTAssertEqual(completedSummary(in: events)?.ignoredFileCount, 1)
    }

    private func request(root: URL, paths: [String]) throws -> WorkspaceSearchRequest {
        try WorkspaceSearchRequest(
            rootAuthority: WorkspaceFileSystemRootAuthority(rootURL: root),
            snapshot: WorkspaceFileSnapshot(entries: paths.map {
                WorkspaceFileSnapshot.Entry(
                    relativePath: $0,
                    kind: .markdown,
                    identity: $0,
                    contentModificationDate: nil
                )
            }),
            workspaceGeneration: 1,
            queryGeneration: 1,
            query: TextSearchQuery(pattern: "needle")
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
            .appendingPathComponent("WorkspaceSearchReviewFixTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try WorkspaceFileSystemRootAuthority(rootURL: url).canonicalRootURL
    }
}

private struct MapReader: SyntheticWorkspaceSearchFileReading {
    let contentsByPath: [String: String]

    init(root: URL, files: [String: String]) {
        contentsByPath = Dictionary(uniqueKeysWithValues: files.map {
            (root.appendingPathComponent($0.key).path(percentEncoded: false), $0.value)
        })
    }

    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data {
        guard let contents = contentsByPath[url.path(percentEncoded: false)] else {
            throw WorkspaceSearchFileReadError.disappeared
        }
        return Data(contents.utf8.prefix(maximumByteCount))
    }
}
