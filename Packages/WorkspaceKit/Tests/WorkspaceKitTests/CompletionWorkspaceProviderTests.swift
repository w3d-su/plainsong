@testable import WorkspaceKit
import XCTest

final class CompletionWorkspaceProviderTests: XCTestCase {
    func testBuildsCompletionWorkspaceFromContainedWorkspaceSnapshot() async throws {
        let root = try makeTemporaryDirectory()
        let content = root.appendingPathComponent("content", isDirectory: true)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        let currentFile = content.appendingPathComponent("current.md")
        let siblingFile = content.appendingPathComponent("sibling.md")
        try "# Current\n\n## Deep Dive\n".write(to: currentFile, atomically: true, encoding: .utf8)
        try """
        ---
        title: Sibling
        layout: post
        custom_key: true
        ---
        Body
        """.write(to: siblingFile, atomically: true, encoding: .utf8)
        try "<Component />".write(to: content.appendingPathComponent("page.mdx"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: assets.appendingPathComponent("hero.png"))

        let snapshot = try await WorkspaceDirectoryScanner().snapshot(root: root)
        let workspace = try CompletionWorkspaceProvider().workspace(
            rootURL: root,
            currentFileURL: currentFile,
            currentText: "# Current\n\n## Deep Dive\n",
            snapshot: snapshot
        )

        XCTAssertEqual(workspace.currentFilePath, "content/current.md")
        XCTAssertEqual(workspace.markdownFilePaths, ["content/current.md", "content/page.mdx", "content/sibling.md"])
        XCTAssertEqual(workspace.imageFilePaths, ["assets/hero.png"])
        XCTAssertEqual(workspace.currentFileHeadingAnchors, ["#current", "#deep-dive"])
        XCTAssertTrue(workspace.frontmatterKeys.contains("layout"))
        XCTAssertTrue(workspace.frontmatterKeys.contains("custom_key"))
    }

    func testRejectsCurrentFileOutsideWorkspaceRoot() async throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory().appendingPathComponent("outside.md")
        try "Body".write(to: outside, atomically: true, encoding: .utf8)
        let snapshot = try await WorkspaceDirectoryScanner().snapshot(root: root)

        XCTAssertThrowsError(try CompletionWorkspaceProvider().workspace(
            rootURL: root,
            currentFileURL: outside,
            currentText: "Body",
            snapshot: snapshot
        ))
    }

    func testBuildsMDXComponentNamesFromCurrentText() async throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("page.mdx")
        let currentText = """
        import Card, {Hero as LandingHero, CTA} from "./components"
        import {FeatureGrid} from "./FeatureGrid"

        <Card />
        """
        try currentText.write(to: currentFile, atomically: true, encoding: .utf8)

        let snapshot = try await WorkspaceDirectoryScanner().snapshot(root: root)
        let workspace = try CompletionWorkspaceProvider().workspace(
            rootURL: root,
            currentFileURL: currentFile,
            currentText: currentText,
            snapshot: snapshot
        )

        XCTAssertEqual(workspace.componentNames, ["Card", "LandingHero", "CTA", "FeatureGrid"])
    }

    func testCapsSiblingFrontmatterReads() async throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("current.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)

        for index in 0 ..< 60 {
            let file = root.appendingPathComponent(String(format: "post-%03d.md", index))
            try """
            ---
            key_\(index): value
            ---
            Body
            """.write(to: file, atomically: true, encoding: .utf8)
        }

        let snapshot = try await WorkspaceDirectoryScanner().snapshot(root: root)
        let workspace = try CompletionWorkspaceProvider().workspace(
            rootURL: root,
            currentFileURL: currentFile,
            currentText: "Body",
            snapshot: snapshot
        )

        XCTAssertEqual(workspace.frontmatterKeys.count, 50)
        XCTAssertTrue(workspace.frontmatterKeys.contains("key_0"))
        XCTAssertTrue(workspace.frontmatterKeys.contains("key_49"))
        XCTAssertFalse(workspace.frontmatterKeys.contains("key_50"))
    }

    func testCanonicalEquivalentSiblingUsesByteExactExclusionAndOrderingBeforeReadCap() throws {
        let root = try makeTemporaryDirectory()
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let nfcCurrentPath = "caf\u{00E9}.md"
        let nfdSiblingPath = "cafe\u{0301}.md"
        var entries = [entry(nfcCurrentPath)]

        for index in 0 ..< 49 {
            let relativePath = String(format: "a-%03d.md", index)
            try """
            ---
            key_\(index): value
            ---
            Body
            """.write(to: root.appendingPathComponent(relativePath), atomically: true, encoding: .utf8)
            entries.append(entry(relativePath))
        }
        try """
        ---
        nfd_sibling: value
        ---
        Body
        """.write(to: root.appendingPathComponent(nfdSiblingPath), atomically: true, encoding: .utf8)
        entries.append(entry(nfdSiblingPath))

        let afterCapPath = "z-after-cap.md"
        try """
        ---
        after_cap: value
        ---
        Body
        """.write(to: root.appendingPathComponent(afterCapPath), atomically: true, encoding: .utf8)
        entries.append(entry(afterCapPath))

        let workspace = try CompletionWorkspaceProvider().workspace(
            rootAuthority: authority,
            currentFileLocation: authority.location(relativePath: nfcCurrentPath),
            currentText: "Local current text",
            snapshot: WorkspaceFileSnapshot(entries: entries)
        )

        XCTAssertEqual(
            workspace.markdownFilePaths.map { Array($0.utf8) },
            entries.map(\.relativePath).sorted {
                WorkspacePathByteKey($0) < WorkspacePathByteKey($1)
            }.map { Array($0.utf8) }
        )
        XCTAssertTrue(workspace.frontmatterKeys.contains("nfd_sibling"))
        XCTAssertFalse(workspace.frontmatterKeys.contains("after_cap"))
    }

    func testAnchoredWorkspaceDoesNotReadReplacementRootSibling() async throws {
        let parent = try makeTemporaryDirectory()
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let moved = parent.appendingPathComponent("captured-A", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let currentFile = root.appendingPathComponent("current.md")
        try "Body A".write(to: currentFile, atomically: true, encoding: .utf8)
        try "---\na_key: yes\n---\n".write(
            to: root.appendingPathComponent("sibling.md"),
            atomically: true,
            encoding: .utf8
        )
        let capture = try await WorkspaceDirectoryScanner().snapshotCapture(root: root)
        let currentLocation = try capture.rootAuthority.canonicalizedLocation(
            forFileURL: currentFile
        )

        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "Body B".write(to: root.appendingPathComponent("current.md"), atomically: true, encoding: .utf8)
        try "---\nb_key: yes\n---\n".write(
            to: root.appendingPathComponent("sibling.md"),
            atomically: true,
            encoding: .utf8
        )

        let workspace = try CompletionWorkspaceProvider().workspace(
            rootAuthority: capture.rootAuthority,
            currentFileLocation: currentLocation,
            currentText: "Body A",
            snapshot: capture.snapshot
        )

        XCTAssertFalse(workspace.frontmatterKeys.contains("b_key"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompletionWorkspaceProviderTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entry(_ relativePath: String) -> WorkspaceFileSnapshot.Entry {
        WorkspaceFileSnapshot.Entry(
            relativePath: relativePath,
            kind: .markdown,
            identity: relativePath,
            contentModificationDate: nil
        )
    }
}
