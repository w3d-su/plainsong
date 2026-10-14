import AppKit
@testable import Plainsong
import XCTest

@MainActor
extension EditorFindHostedGateTests {
    /// A workspace opened through a symlinked root must still resolve jump bar folder
    /// menus, the current-file checkmark, and the inspector location: `openWorkspace`
    /// keeps the root's literal spelling while session URLs are canonicalized.
    func testSymlinkedWorkspaceRootKeepsJumpBarAndInspectorRelativePaths() async throws {
        let fixture = try makeWorkspaceFixture(files: [
            "real/sub/a.md": "a",
            "real/top.md": "top",
            "real/Caf\u{E9}/b.md": "b",
        ])
        let state = fixture.appState
        let real = fixture.root.appendingPathComponent("real", isDirectory: true)
        let link = fixture.root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        addTeardownBlock { @MainActor in
            state.closeWorkspace()
            fixture.cleanUp()
        }

        state.setLayoutMode(.sourceOnly)
        // `open`/`openExternalFile` does not follow the symlink for its directory check;
        // `openWorkspace` is the entry point that keeps the root's literal spelling.
        try state.openWorkspace(url: link, rememberAsLastOpened: false)
        NSLog(
            "SYMLINK-EVIDENCE presentedError=\(String(describing: state.presentedError)) root=\(String(describing: state.workspaceRootURL))"
        )
        try await waitUntil("symlinked workspace opens") {
            state.workspaceRootURL != nil && state.hasOpenDocument
        }
        try await waitUntil("the open reload installed its capture") {
            state.workspaceInstalledCaptureGeneration == state.workspaceGeneration
        }
        let root = try XCTUnwrap(state.workspaceRootURL)
        XCTAssertEqual(root, link)

        let aNode = try XCTUnwrap(
            try state.firstNode(in: XCTUnwrap(state.workspaceTree).root, relativePath: "sub/a.md")
        )
        state.selectWorkspaceNode(id: aNode.id)
        try await waitUntil("a.md opens through the symlinked root") {
            state.currentDocument.fileURL?.lastPathComponent == "a.md"
        }
        let fileURL = try XCTUnwrap(state.currentDocument.fileURL)
        NSLog(
            "SYMLINK-EVIDENCE fileURL=\(fileURL.path(percentEncoded: false)) root=\(root.path(percentEncoded: false))"
        )

        XCTAssertEqual(JumpBarMenus.relativePath(of: fileURL, under: root), "sub/a.md")
        XCTAssertEqual(
            JumpBarMenus.relativePath(of: fileURL.deletingLastPathComponent(), under: root),
            "sub"
        )

        let aMenu = try XCTUnwrap(JumpBarMenus.folderMenu(
            path: ["sub"],
            tree: state.workspaceTree,
            currentRelativePath: JumpBarMenus.relativePath(of: fileURL, under: root)
        ) { _ in })
        aMenu.delegate?.menuNeedsUpdate?(aMenu)
        let aItem = try XCTUnwrap(aMenu.items.first { $0.title == "a.md" })
        XCTAssertEqual(aItem.state, .on, "the current document's menu item must be checked")

        let tree = try XCTUnwrap(state.workspaceTree)
        let cafeFolder = try XCTUnwrap(
            tree.root.children.first { $0.isDirectory && $0.name == "Caf\u{E9}" }
        )
        let bNode = try XCTUnwrap(cafeFolder.children.first { $0.name == "b.md" })
        state.selectWorkspaceNode(id: bNode.id)
        try await waitUntil("b.md opens through the symlinked root") {
            state.currentDocument.fileURL?.lastPathComponent == "b.md"
        }
        let bURL = try XCTUnwrap(state.currentDocument.fileURL)
        XCTAssertEqual(JumpBarMenus.relativePath(of: bURL, under: root), bNode.relativePath)

        let bMenu = try XCTUnwrap(JumpBarMenus.folderMenu(
            path: [cafeFolder.name],
            tree: state.workspaceTree,
            currentRelativePath: JumpBarMenus.relativePath(of: bURL, under: root)
        ) { _ in })
        bMenu.delegate?.menuNeedsUpdate?(bMenu)
        let bItem = try XCTUnwrap(bMenu.items.first { $0.title == "b.md" })
        XCTAssertEqual(bItem.state, .on, "the current document's menu item must be checked")

        XCTAssertEqual(
            WorkspaceInspector.location(of: fileURL, rootURL: root),
            "link › sub"
        )
    }
}
