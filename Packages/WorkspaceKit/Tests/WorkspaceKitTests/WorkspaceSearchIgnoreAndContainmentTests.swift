import MarkdownCore
@testable import WorkspaceKit
import XCTest

final class WorkspaceSearchIgnoreAndContainmentTests: XCTestCase {
    func testIgnoreSubsetSupportsRootNestedGlobDirectoryAndNegationRules() async throws {
        let root = try makeTemporaryDirectory()
        let paths = [
            "notes.scratch.md",
            "file1.md",
            "root.md",
            "nested/root.md",
            "build/generated.md",
            "docs/deep/draft1.md",
            "docs/keep.md",
            "docs/skip.md",
            "last.md",
            "keep-root.md",
        ]
        let reader = IgnoreReader(responses: [
            root.appendingPathComponent(".gitignore").path: """
            # comment and blank lines are ignored

            *.scratch.md
            file?.md
            /root.md
            build/
            docs/**/draft?.md
            last.md
            """,
            root.appendingPathComponent(".ignore").path: "!last.md\n!keep-root.md\n",
            root.appendingPathComponent("docs/.ignore").path: "*.md\n!keep.md\n",
        ].mapValues { .data($0) })
        for path in paths {
            await reader.set(.data("needle \(path)"), at: root.appendingPathComponent(path).path)
        }

        let events = await collectEvents(
            WorkspaceSearchService(reader: reader),
            request: request(root: root, paths: paths)
        )
        let results = fileResults(in: events)
        let summary = try XCTUnwrap(completedSummary(in: events))

        XCTAssertEqual(results.map(\.relativePath), [
            "docs/keep.md",
            "keep-root.md",
            "last.md",
            "nested/root.md",
        ])
        XCTAssertEqual(summary.ignoredFileCount, 6)
        XCTAssertEqual(summary.searchedFileCount, 4)
    }

    func testHiddenGeneratedAndPackageDescendantsAreAlwaysIgnored() async throws {
        let root = try makeTemporaryDirectory()
        let paths = [
            ".hidden.md",
            ".git/config.md",
            "node_modules/dependency.md",
            ".build/cache.md",
            ".next/page.md",
            ".astro/page.md",
            "DerivedData/log.md",
            "dist/output.md",
            "build/output.md",
            "Editor.app/Contents/post.md",
            "visible.md",
        ]
        let reader = IgnoreReader(responses: [
            root.appendingPathComponent(".gitignore").path: .data("!**/*.md\n"),
            root.appendingPathComponent("visible.md").path: .data("needle"),
        ])

        let events = await collectEvents(
            WorkspaceSearchService(reader: reader),
            request: request(root: root, paths: paths)
        )
        let summary = try XCTUnwrap(completedSummary(in: events))

        XCTAssertEqual(fileResults(in: events).map(\.relativePath), ["visible.md"])
        XCTAssertEqual(summary.ignoredFileCount, paths.count - 1)
        let visibleReadCount = await reader.readCount(for: root.appendingPathComponent("visible.md").path)
        XCTAssertEqual(visibleReadCount, 1)
    }

    func testIgnoreRuleReadsHonorNamedResourceLimit() async throws {
        let root = try makeTemporaryDirectory()
        let nestedIgnorePath = root.appendingPathComponent("nested/.gitignore").path
        let reader = IgnoreReader(responses: [
            root.appendingPathComponent(".gitignore").path: .data("# first and only read\n"),
            nestedIgnorePath: .data("*.md\n"),
            root.appendingPathComponent("nested/post.md").path: .data("needle"),
        ])
        let request = WorkspaceSearchRequest(
            rootURL: root,
            snapshot: WorkspaceFileSnapshot(entries: [entry("nested/post.md")]),
            workspaceGeneration: 1,
            queryGeneration: 1,
            query: TextSearchQuery(pattern: "needle"),
            limits: WorkspaceSearchLimits(maximumIgnoreFiles: 1)
        )

        let events = await collectEvents(WorkspaceSearchService(reader: reader), request: request)
        let nestedIgnoreReadCount = await reader.readCount(for: nestedIgnorePath)

        XCTAssertEqual(fileResults(in: events).map(\.relativePath), ["nested/post.md"])
        XCTAssertEqual(nestedIgnoreReadCount, 0)
    }

    func testContainmentRejectsEmptyAbsoluteTraversalSiblingAndSymlinkEscape() async throws {
        let parent = try makeTemporaryDirectory()
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let sibling = parent.appendingPathComponent("workspace-other", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let outside = sibling.appendingPathComponent("outside.md")
        try "needle".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.md"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try WorkspaceRootContainment.containedURL(rootURL: root, relativePath: ""))
        XCTAssertThrowsError(try WorkspaceRootContainment.containedURL(rootURL: root, relativePath: "/outside.md"))
        XCTAssertThrowsError(try WorkspaceRootContainment.containedURL(
            rootURL: root,
            relativePath: "../workspace-other/outside.md"
        ))
        XCTAssertThrowsError(try WorkspaceRootContainment.relativePath(for: outside, rootURL: root))
        XCTAssertThrowsError(try WorkspaceRootContainment.containedURL(rootURL: root, relativePath: "escape.md"))

        let reader = IgnoreReader(responses: [:])
        let snapshot = WorkspaceFileSnapshot(entries: [
            entry("", kind: .markdown),
            entry("/outside.md", kind: .markdown),
            entry("../workspace-other/outside.md", kind: .markdown),
            entry("escape.md", kind: .markdown),
        ])
        let events = await collectEvents(
            WorkspaceSearchService(reader: reader),
            request: WorkspaceSearchRequest(
                rootURL: root,
                snapshot: snapshot,
                workspaceGeneration: 1,
                queryGeneration: 1,
                query: TextSearchQuery(pattern: "needle")
            )
        )

        XCTAssertEqual(skippedFiles(in: events).map(\.reason), [
            .emptyPath,
            .pathTraversal,
            .absolutePath,
            .symlinkEscape,
        ])
    }

    func testFilesystemRootIsAValidContainmentRoot() throws {
        let filesystemRoot = URL(fileURLWithPath: "/", isDirectory: true)
        let temporaryDirectory = FileManager.default.temporaryDirectory

        let relativePath = try WorkspaceRootContainment.relativePath(
            for: temporaryDirectory,
            rootURL: filesystemRoot
        )
        let containedURL = try WorkspaceRootContainment.containedURL(
            rootURL: filesystemRoot,
            relativePath: relativePath
        )

        XCTAssertFalse(relativePath.isEmpty)
        XCTAssertTrue(WorkspaceRootContainment.isContained(containedURL, in: filesystemRoot))
    }

    func testRevalidatesContainmentImmediatelyBeforeDiskRead() async throws {
        let parent = try makeTemporaryDirectory()
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let outside = parent.appendingPathComponent("outside.md")
        let candidate = root.appendingPathComponent("post.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "needle".write(to: candidate, atomically: true, encoding: .utf8)
        try "needle outside".write(to: outside, atomically: true, encoding: .utf8)

        let reader = ContainmentSwapReader()
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
        try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: outside)
        await reader.releaseIgnoreRead()
        let events = await consumer.value

        XCTAssertEqual(skippedFiles(in: events), [
            WorkspaceSearchSkippedFile(relativePath: "post.md", reason: .symlinkEscape),
        ])
        let candidateReadCount = await reader.candidateReadCount()
        XCTAssertEqual(candidateReadCount, 0)
    }

    private func request(root: URL, paths: [String]) -> WorkspaceSearchRequest {
        WorkspaceSearchRequest(
            rootURL: root,
            rootIdentity: "ignore-root",
            snapshot: WorkspaceFileSnapshot(entries: paths.map { entry($0) }),
            workspaceGeneration: 2,
            queryGeneration: 3,
            query: TextSearchQuery(pattern: "needle")
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
            .appendingPathComponent("WorkspaceSearchIgnoreAndContainmentTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor IgnoreReader: WorkspaceSearchFileReading {
    enum Response {
        case data(String)
    }

    private var responses: [String: Response]
    private var reads: [String: Int] = [:]

    init(responses: [String: Response]) {
        self.responses = responses
    }

    func set(_ response: Response, at path: String) {
        responses[path] = response
    }

    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data {
        reads[url.path, default: 0] += 1
        guard let response = responses[url.path] else {
            throw WorkspaceSearchFileReadError.disappeared
        }
        switch response {
        case let .data(text):
            return Data(text.utf8.prefix(maximumByteCount))
        }
    }

    func readCount(for path: String) -> Int {
        reads[path, default: 0]
    }
}

private actor ContainmentSwapReader: WorkspaceSearchFileReading {
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
