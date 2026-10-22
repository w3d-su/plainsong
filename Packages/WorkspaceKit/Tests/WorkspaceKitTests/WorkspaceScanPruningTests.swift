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

    func testAnIgnoredDirectoryOnTheWayToARetainedPathIsStillScanned() async throws {
        let root = try makeWebProject()

        let capture = try await WorkspaceDirectoryScanner().snapshotCapture(
            root: root,
            pruning: .ignoredDirectories(retaining: ["node_modules/pkg/README.md"])
        )
        let paths = Set(capture.snapshot.entries.map(\.relativePath))

        XCTAssertTrue(paths.contains("node_modules/pkg/README.md"))
        XCTAssertFalse(paths.contains("Dist/index.md"))
    }

    func testOnlyDirectoriesArePrunedAndNamesMatchCaseInsensitively() {
        let pruning = WorkspaceScanPruning.ignoredDirectories(retaining: ["build/keep.md"])

        XCTAssertTrue(pruning.skipsDirectory(named: "Node_Modules", relativePath: "Node_Modules"))
        XCTAssertTrue(pruning.skipsDirectory(named: "dist", relativePath: "site/dist"))
        XCTAssertFalse(pruning.skipsDirectory(named: "build", relativePath: "build"))
        XCTAssertFalse(pruning.skipsDirectory(named: "content", relativePath: "content"))
        XCTAssertFalse(WorkspaceScanPruning.none.skipsDirectory(named: "node_modules", relativePath: "node_modules"))
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
