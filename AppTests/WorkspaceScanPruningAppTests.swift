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
        XCTAssertNil(node("node_modules/other/README.md", in: appState), "only the open file's chain is scanned")
        XCTAssertNil(node("dist/index.md", in: appState), "unrelated ignored trees stay pruned")
    }

    func testSwitchingWorkspacesDoesNotCarryTheOldDocumentsPathIntoTheNewScan() async throws {
        let (appState, rootA) = try makeWorkspace()
        let rootB = try makeWorkspaceRoot()
        appState.workspaceRootURL = nil
        appState.showAllFiles = true
        try appState.openWorkspace(url: rootA, rememberAsLastOpened: false)
        try await waitUntil("workspace A installs with every file") {
            node("node_modules/pkg/README.md", in: appState) != nil
                && appState.workspaceInstalledCaptureGeneration == appState.workspaceGeneration
        }
        let readme = try XCTUnwrap(node("node_modules/pkg/README.md", in: appState))
        XCTAssertTrue(appState.selectWorkspaceNode(id: readme.id))

        // Markdown-only again, then open workspace B, which has the same relative path. A's
        // README is still the current document while B's first scan runs.
        appState.showAllFiles = false
        try appState.openWorkspace(url: rootB, rememberAsLastOpened: false)
        try await waitUntil("workspace B installs") {
            appState.workspaceRootURL == rootB
                && node("content/post.md", in: appState) != nil
                && appState.workspaceInstalledCaptureGeneration == appState.workspaceGeneration
        }

        XCTAssertNil(node("node_modules/pkg/README.md", in: appState), "A's open document kept B's node_modules")
        XCTAssertNil(node("node_modules", in: appState))
        appState.closeWorkspace()
    }

    private func makeWorkspace() throws -> (AppState, URL) {
        let root = try makeWorkspaceRoot()
        let suiteName = "WorkspaceScanPruningAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(shouldRestoreLastOpenedFile: false, userDefaults: defaults)
        appState.workspaceRootURL = root
        return (appState, root)
    }

    private func makeWorkspaceRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceScanPruningAppTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (path, text) in [
            "content/post.md": "# Post",
            "node_modules/pkg/README.md": "# Package",
            "node_modules/other/README.md": "# Other package",
            "dist/index.md": "# Built",
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

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for \(description)")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
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
