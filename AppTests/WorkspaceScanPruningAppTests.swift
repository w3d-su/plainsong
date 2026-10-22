import Foundation
@testable import Plainsong
import WorkspaceKit
import XCTest

/// "Show all files" off skips generated and vendored directories at scan time
/// (`docs/decisions/2026-10-22-markdown-only-scan-skips-ignored-directories.md`).
@MainActor
final class WorkspaceScanPruningAppTests: XCTestCase {
    func testMarkdownOnlyTreeSkipsIgnoredDirectoriesUntilShowAllFiles() async throws {
        let (appState, root) = try makeWorkspace()

        try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: true)
        XCTAssertNotNil(node("content/post.md", in: appState))
        XCTAssertNil(node("node_modules/pkg/README.md", in: appState))
        XCTAssertNil(node("node_modules", in: appState))

        appState.showAllFiles = true
        try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: false)
        XCTAssertNotNil(node("node_modules/pkg/README.md", in: appState))

        appState.showAllFiles = false
        try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: false)
        XCTAssertNil(node("node_modules/pkg/README.md", in: appState))
    }

    func testAnOpenDocumentInsideAnIgnoredDirectorySurvivesTheMarkdownOnlyRescan() async throws {
        let (appState, root) = try makeWorkspace()
        appState.showAllFiles = true
        try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: true)
        let readme = try XCTUnwrap(node("node_modules/pkg/README.md", in: appState))
        XCTAssertTrue(appState.selectWorkspaceNode(id: readme.id))
        XCTAssertEqual(appState.currentDocument.fileURL?.lastPathComponent, "README.md")

        appState.showAllFiles = false
        try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: false)

        XCTAssertEqual(appState.currentDocument.fileURL?.lastPathComponent, "README.md")
        XCTAssertNil(appState.missingFilePrompt, "the open document must not look missing")
        XCTAssertNotNil(node("node_modules/pkg/README.md", in: appState))
        XCTAssertNil(node("dist/index.md", in: appState), "unrelated ignored trees stay pruned")
    }

    private func makeWorkspace() throws -> (AppState, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceScanPruningAppTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (path, text) in [
            "content/post.md": "# Post",
            "node_modules/pkg/README.md": "# Package",
            "dist/index.md": "# Built",
        ] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: false, encoding: .utf8)
        }
        let suiteName = "WorkspaceScanPruningAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(shouldRestoreLastOpenedFile: false, userDefaults: defaults)
        appState.workspaceRootURL = root
        return (appState, root)
    }

    private func node(_ relativePath: String, in appState: AppState) -> WorkspaceFileNode? {
        func search(_ node: WorkspaceFileNode) -> WorkspaceFileNode? {
            if node.relativePath == relativePath { return node }
            for child in node.children {
                if let match = search(child) { return match }
            }
            return nil
        }
        return appState.workspaceTree.flatMap { search($0.root) }
    }
}
