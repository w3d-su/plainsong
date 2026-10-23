@testable import WorkspaceKit
import XCTest

final class WorkspaceScanPruningTests: XCTestCase {
    func testIgnoredDirectoriesAreSkippedWithoutVisitingTheirContents() async throws {
        let root = try makeWebProject()
        let visited = VisitedURLs()
        let scanner = WorkspaceDirectoryScanner { visited.append($0) }

        let capture = try await scanner.snapshotCapture(
            root: root,
            pruning: .ignoredDirectories(retaining: [])
        )
        let paths = Set(capture.snapshot.entries.map(\.relativePath))

        XCTAssertEqual(paths, [
            "content", "content/post.md", "src", "src/components", "src/components/Card.md",
        ])
        XCTAssertFalse(
            visited.paths.contains { $0.contains("/node_modules/pkg") || $0.contains("/Dist/index") },
            "pruned trees must not be enumerated: \(visited.paths)"
        )
    }

    func testNoPruningKeepsEveryEntry() async throws {
        let root = try makeWebProject()

        let capture = try await WorkspaceDirectoryScanner().snapshotCapture(root: root, pruning: .none)
        let paths = Set(capture.snapshot.entries.map(\.relativePath))

        XCTAssertTrue(paths.contains("node_modules/pkg/README.md"))
        XCTAssertTrue(paths.contains("Dist/index.md"))
        XCTAssertTrue(paths.contains(".next/cache/page.md") == false, "hidden entries stay skipped")
        let unpruned = try await WorkspaceDirectoryScanner().snapshotCapture(root: root)
        XCTAssertEqual(Set(unpruned.snapshot.entries.map(\.relativePath)), paths)
    }

    func testOnlyTheChainToARetainedPathIsScannedInsideAnIgnoredDirectory() async throws {
        let root = try makeWebProject()
        let visited = VisitedURLs()
        let scanner = WorkspaceDirectoryScanner { visited.append($0) }

        let capture = try await scanner.snapshotCapture(
            root: root,
            pruning: .ignoredDirectories(retaining: ["node_modules/pkg/README.md"])
        )
        let paths = Set(capture.snapshot.entries.map(\.relativePath))

        XCTAssertTrue(paths.isSuperset(of: ["node_modules", "node_modules/pkg", "node_modules/pkg/README.md"]))
        // One open README must not bring back the rest of `node_modules`.
        XCTAssertFalse(paths.contains("node_modules/pkg/index.js"))
        XCTAssertFalse(paths.contains("node_modules/other"))
        XCTAssertFalse(paths.contains("Dist/index.md"))
        XCTAssertFalse(
            visited.paths.contains { $0.contains("/node_modules/other/README") },
            "siblings off the retained chain must not be enumerated: \(visited.paths)"
        )
    }

    func testOnlyDirectoriesArePrunedAndNamesMatchCaseInsensitively() {
        let pruning = WorkspaceScanPruning.ignoredDirectories(retaining: [])

        XCTAssertTrue(pruning.skipsEntry(named: "Node_Modules", relativePath: "Node_Modules", isDirectory: true))
        XCTAssertTrue(pruning.skipsEntry(named: "dist", relativePath: "site/dist", isDirectory: true))
        XCTAssertFalse(pruning.skipsEntry(named: "build", relativePath: "build", isDirectory: false))
        XCTAssertFalse(pruning.skipsEntry(named: "content", relativePath: "content", isDirectory: true))
        XCTAssertFalse(
            WorkspaceScanPruning.none.skipsEntry(named: "node_modules", relativePath: "node_modules", isDirectory: true)
        )
    }

    func testRetainedPathsKeepTheirChainAndNothingElseUnderAnIgnoredDirectory() {
        let pruning = WorkspaceScanPruning.ignoredDirectories(retaining: ["build/docs/keep.md", "content/post.md"])

        XCTAssertFalse(pruning.skipsEntry(named: "build", relativePath: "build", isDirectory: true))
        XCTAssertFalse(pruning.skipsEntry(named: "docs", relativePath: "build/docs", isDirectory: true))
        XCTAssertFalse(pruning.skipsEntry(named: "keep.md", relativePath: "build/docs/keep.md", isDirectory: false))
        XCTAssertTrue(pruning.skipsEntry(named: "other.md", relativePath: "build/docs/other.md", isDirectory: false))
        XCTAssertTrue(pruning.skipsEntry(named: "assets", relativePath: "build/assets", isDirectory: true))
        // Outside ignored directories nothing changes.
        XCTAssertFalse(pruning.skipsEntry(named: "draft.md", relativePath: "content/draft.md", isDirectory: false))
        XCTAssertFalse(pruning.skipsEntry(named: "img", relativePath: "content/img", isDirectory: true))
    }

    /// An Astro-style tree: content, a component folder, `node_modules` with Markdown inside,
    /// a differently cased `Dist`, and a hidden `.next`.
    private func makeWebProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceScanPruningTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (path, text) in [
            "content/post.md": "# Post",
            "src/components/Card.md": "# Card",
            "node_modules/pkg/README.md": "# Package",
            "node_modules/pkg/index.js": "export {}",
            "node_modules/other/README.md": "# Other",
            "Dist/index.md": "# Built",
            ".next/cache/page.md": "# Cache",
        ] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: false, encoding: .utf8)
        }
        return root
    }
}

private final class VisitedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var paths: [String] {
        lock.withLock { storage }
    }

    func append(_ url: URL) {
        lock.withLock { storage.append(url.path(percentEncoded: false)) }
    }
}
