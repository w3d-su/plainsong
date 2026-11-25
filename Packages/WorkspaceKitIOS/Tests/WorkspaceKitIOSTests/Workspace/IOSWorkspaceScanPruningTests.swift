import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSWorkspaceScanPruningTests: XCTestCase {
    func testDefaultScanSkipsHiddenDirectoriesAndKeepsVisibleGeneratedOnes() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory("/tmp/plainsong-review/Pruned")
        scriptProject(harness, grant: grant)
        let snapshot = try await harness.service.refresh(grant)
        XCTAssertEqual(
            Set(harness.files.listedPaths()),
            Set(["", "posts", "node_modules", "Build"].map { path(grant.rootURL, $0) })
        )
        let paths = Self.paths(snapshot.entries)
        XCTAssertTrue(paths.contains("posts/page.md"))
        XCTAssertTrue(paths.contains("Build/notes.md"))
        XCTAssertTrue(paths.contains("node_modules/pkg.md"))
        XCTAssertFalse(paths.contains { $0.hasPrefix(".git") || $0.hasPrefix(".drafts") })
    }

    func testHiddenEntriesSettingListsHiddenDirectories() async throws {
        let harness = AccessHarness()
        harness.service.includesHiddenEntries = true
        let grant = try await harness.openDirectory("/tmp/plainsong-review/Hidden")
        scriptProject(harness, grant: grant)
        _ = try await harness.service.refresh(grant)
        XCTAssertEqual(
            Set(harness.files.listedPaths()),
            Set(["", "posts", "node_modules", "Build", ".git", ".drafts"].map { path(grant.rootURL, $0) })
        )
    }

    private func scriptProject(_ harness: AccessHarness, grant: IOSWorkspaceGrant) {
        let root = grant.rootURL
        harness.files.nestedListing = { url, _ in
            switch url.path(percentEncoded: false) {
            case root.path(percentEncoded: false):
                ["posts", "node_modules", "Build", ".git", ".drafts"].map { item(root, $0, directory: true) }
            case path(root, "posts"):
                [item(root, "posts/page.md", directory: false)]
            case path(root, "node_modules"):
                [item(root, "node_modules/pkg.md", directory: false)]
            case path(root, "Build"):
                [item(root, "Build/notes.md", directory: false)]
            default:
                []
            }
        }
    }

    private static func paths(_ entries: [IOSWorkspaceEntry]) -> [String] {
        entries.flatMap { [$0.location.relativePath] + paths($0.children) }
    }
}

private func path(_ root: URL, _ relativePath: String) -> String {
    relativePath.isEmpty
        ? root.path(percentEncoded: false)
        : IOSWorkspacePathAuthority.joined(root: root, relativePath: relativePath)
}

private func item(_ root: URL, _ relativePath: String, directory: Bool) -> IOSWorkspaceFileItem {
    IOSWorkspaceFileItem(
        relativePath: relativePath,
        url: IOSWorkspacePathAuthority.fileURL(path: path(root, relativePath)),
        isDirectory: directory,
        isSymlink: false,
        fileSize: directory ? nil : 4,
        availability: .available(canWrite: true),
        providerIdentity: nil,
        bytes: nil
    )
}
