import Foundation
@testable import Plainsong
import XCTest

/// The preview sends a link's rendered `href`, which remark percent-encodes. Opening it as a
/// literal path looked for a file named `%E6%96%87%E7%AB%A0.md` and failed with "Could Not
/// Open File" for every link to a name with a space or a non-ASCII character.
@MainActor
final class PreviewLinkOpeningTests: XCTestCase {
    func testRelativePathIsDecodedAndStripsQueryAndFragment() {
        XCTAssertEqual(AppState.previewLinkRelativePath("%E6%96%87%E7%AB%A0.md"), "文章.md")
        XCTAssertEqual(AppState.previewLinkRelativePath("my%20post.md"), "my post.md")
        XCTAssertEqual(AppState.previewLinkRelativePath("../other.md#part"), "../other.md")
        XCTAssertEqual(AppState.previewLinkRelativePath("other.md?version=2#part"), "other.md")
        XCTAssertEqual(AppState.previewLinkRelativePath("C%23%3F.md"), "C#?.md")
        XCTAssertEqual(AppState.previewLinkRelativePath("文章.md"), "文章.md", "unencoded MDX attribute")
        XCTAssertEqual(AppState.previewLinkRelativePath("./a:b.md"), "./a:b.md")
        XCTAssertEqual(AppState.previewLinkRelativePath("posts/%E4%B8%AD.mdx"), "posts/中.mdx")
    }

    func testAnythingButARelativePathIsRefused() {
        let refused = [
            "", "#heading", "?query", "/etc/hosts.md", "//host/share/x.md", "\\\\server\\x.md",
            "file:///tmp/x.md", "mailto:someone@example.com", "x-plainsong:open.md", "a:b.md",
            "%2Fetc%2Fhosts.md", "%zz.md", "%E6%96.md", "%00.md",
        ]
        for href in refused {
            XCTAssertNil(AppState.previewLinkRelativePath(href), href.debugDescription)
        }
    }

    func testClickingAnEncodedLinkOpensTheNamedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewLinkOpeningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let post = directory.appendingPathComponent("post.md")
        let target = directory.appendingPathComponent("中文 文章.md")
        try "[中文 文章](%E4%B8%AD%E6%96%87%20%E6%96%87%E7%AB%A0.md)".write(to: post, atomically: true, encoding: .utf8)
        try "# Target".write(to: target, atomically: true, encoding: .utf8)
        let appState = AppState(
            lastOpenedFileStore: MemoryLastOpenedFileStore(),
            recentItemStore: MemoryRecentItemStore(),
            shouldRestoreLastOpenedFile: false
        )
        appState.openExternalFile(post)
        XCTAssertEqual(appState.shownSession.fileURL?.standardizedFileURL, post.standardizedFileURL)

        appState.openPreviewLink("%E4%B8%AD%E6%96%87%20%E6%96%87%E7%AB%A0.md#intro")

        XCTAssertNil(appState.presentedError)
        XCTAssertEqual(appState.shownSession.fileURL?.standardizedFileURL, target.standardizedFileURL)
        XCTAssertEqual(appState.shownSession.text, "# Target")
    }

    /// A workspace picked as `/private/tmp/w` (what the Open panel returns) refused every
    /// relative link: `standardizedFileURL` turned the target into `/tmp/w/Target.md`, which
    /// the workspace authority compares literally against `/private/tmp/w`. `/private/etc`
    /// has the same alias and is readable from the sandboxed test host.
    func testWorkspaceFileURLIsReanchoredOnAPrivatePrefixedRoot() {
        let root = URL(fileURLWithPath: "/private/etc", isDirectory: true)
        let linkURL = URL(fileURLWithPath: "hosts", relativeTo: root).standardizedFileURL
        XCTAssertEqual(linkURL.path, "/etc/hosts", "standardizedFileURL drops the /private alias")

        XCTAssertEqual(AppState.workspaceFileURL(for: linkURL, under: root)?.path, "/private/etc/hosts")
        XCTAssertEqual(
            AppState.workspaceFileURL(for: root.appendingPathComponent("hosts"), under: root)?.path,
            "/private/etc/hosts"
        )
        XCTAssertNil(AppState.workspaceFileURL(for: URL(fileURLWithPath: "/usr/bin/true"), under: root))
    }

    func testWorkspaceLinkSelectsAndRevealsTheTargetInTheSidebar() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("index.md")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "[Other](sub/Other.md)".write(to: index, atomically: true, encoding: .utf8)
        try "# Other".write(to: root.appendingPathComponent("sub/Other.md"), atomically: true, encoding: .utf8)
        let appState = try await openWorkspace(root, showing: index)
        let revealRequest = appState.workspaceTreeRevealRequest

        appState.openPreviewLink("sub/Other.md")

        XCTAssertNil(appState.presentedError)
        XCTAssertEqual(appState.shownSession.text, "# Other")
        let tree = try XCTUnwrap(appState.workspaceTree)
        XCTAssertEqual(tree.selectedNode?.relativePath, "sub/Other.md")
        let folder = try XCTUnwrap(appState.firstNode(in: tree.root, relativePath: "sub"))
        XCTAssertTrue(tree.isExpanded(folder.id))
        XCTAssertEqual(appState.workspaceTreeRevealRequest, revealRequest &+ 1)

        // A link to the file already shown still asks the sidebar to reveal it.
        appState.openPreviewLink("Other.md")
        XCTAssertEqual(appState.workspaceTreeRevealRequest, revealRequest &+ 2)
    }

    func testWorkspaceLinkToAHiddenFileClearsTheSidebarSelection() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("index.md")
        try "[Other](Other.md)".write(to: index, atomically: true, encoding: .utf8)
        try "[Draft](.draft.md)".write(to: root.appendingPathComponent("Other.md"), atomically: true, encoding: .utf8)
        try "# Draft".write(to: root.appendingPathComponent(".draft.md"), atomically: true, encoding: .utf8)
        let appState = try await openWorkspace(root, showing: index)
        appState.openPreviewLink("Other.md")
        XCTAssertEqual(appState.workspaceTree?.selectedNode?.relativePath, "Other.md")

        appState.openPreviewLink(".draft.md")

        XCTAssertNil(appState.presentedError)
        XCTAssertEqual(appState.shownSession.text, "# Draft")
        XCTAssertNil(appState.workspaceTree?.selectedNodeID)
    }

    /// The sandbox refuses a file outside the workspace grant. The link used to close the
    /// workspace first and then fail to read the file, leaving "No Folder Open".
    func testUnreadableOutsideLinkKeepsTheWorkspace() async throws {
        let parent = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: parent)
        }
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = root.appendingPathComponent("index.md")
        let outside = parent.appendingPathComponent("outside.md")
        try "[Outside](../outside.md)".write(to: index, atomically: true, encoding: .utf8)
        try "# Outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: outside.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path) }
        let appState = try await openWorkspace(root, showing: index)
        let workspaceRoot = appState.workspaceRootURL

        appState.openPreviewLink("../outside.md")

        XCTAssertNotNil(appState.presentedError)
        XCTAssertEqual(appState.workspaceRootURL, workspaceRoot)
        XCTAssertNotNil(appState.workspaceTree)
        XCTAssertEqual(appState.shownSession.fileURL?.lastPathComponent, "index.md")
    }

    func testUndecodableOutsideLinkKeepsTheWorkspace() async throws {
        let parent = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = root.appendingPathComponent("index.md")
        try "[Outside](../binary.md)".write(to: index, atomically: true, encoding: .utf8)
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: parent.appendingPathComponent("binary.md"))
        let appState = try await openWorkspace(root, showing: index)
        let workspaceRoot = appState.workspaceRootURL

        appState.openPreviewLink("../binary.md")

        XCTAssertNotNil(appState.presentedError)
        XCTAssertEqual(appState.workspaceRootURL, workspaceRoot)
        XCTAssertEqual(appState.shownSession.fileURL?.lastPathComponent, "index.md")
    }

    func testReadableOutsideFileReplacesTheWorkspace() async throws {
        let root = try makeDirectory()
        let outside = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let index = root.appendingPathComponent("index.md")
        try "# Index".write(to: index, atomically: true, encoding: .utf8)
        let note = outside.appendingPathComponent("note.md")
        try "# Note".write(to: note, atomically: true, encoding: .utf8)
        let appState = try await openWorkspace(root, showing: index)

        try appState.open(url: note, rememberAsLastOpened: false, preserveWorkspace: false)

        XCTAssertNil(appState.workspaceRootURL)
        XCTAssertEqual(appState.shownSession.text, "# Note")
    }

    /// WD1: a window does not open the file it already shows again, so its workspace and its
    /// unsaved text stay as they are.
    func testReopeningTheDirtyShownFileKeepsItsSessionAndItsUnsavedText() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileA = root.appendingPathComponent("a.md")
        try "# A".write(to: fileA, atomically: true, encoding: .utf8)
        let appState = try await openWorkspace(root, showing: fileA)
        let sessionA = appState.shownSession
        let workspaceRoot = appState.workspaceRootURL
        appState.replaceDocumentText("# A unsaved", in: sessionA)
        appState.cancelAutosave(for: sessionA)

        try appState.open(url: fileA, rememberAsLastOpened: false, preserveWorkspace: false)

        XCTAssertTrue(appState.shownSession === sessionA)
        XCTAssertEqual(sessionA.text, "# A unsaved")
        XCTAssertTrue(sessionA.isDirty)
        XCTAssertEqual(appState.workspaceRootURL, workspaceRoot)
        appState.replaceDocumentText("# A again", in: sessionA)
        try appState.save(session: sessionA)
        XCTAssertEqual(try String(contentsOf: fileA, encoding: .utf8), "# A again")
    }

    func testReopeningTheShownFileWhenItsDiskCopyIsUnreadableKeepsTheWorkspace() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileA = root.appendingPathComponent("a.md")
        try "# A".write(to: fileA, atomically: true, encoding: .utf8)
        let appState = try await openWorkspace(root, showing: fileA)
        let sessionA = appState.shownSession
        let workspaceRoot = appState.workspaceRootURL

        try Data([0xFF, 0xFE]).write(to: fileA)
        try appState.open(url: fileA, rememberAsLastOpened: false, preserveWorkspace: false)

        XCTAssertEqual(appState.workspaceRootURL, workspaceRoot)
        XCTAssertTrue(appState.shownSession === sessionA)
        XCTAssertEqual(sessionA.text, "# A")
    }

    func testReopeningADirtyWarmFileInstallsTheCopyTheCloseSaved() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileA = root.appendingPathComponent("a.md")
        let fileB = root.appendingPathComponent("b.md")
        try "# A".write(to: fileA, atomically: true, encoding: .utf8)
        try "# B".write(to: fileB, atomically: true, encoding: .utf8)
        let appState = try await openWorkspace(root, showing: fileA)
        let sessionA = appState.shownSession
        appState.replaceDocumentText("# A unsaved", in: sessionA)
        appState.openWorkspaceFile(fileB.standardizedFileURL)
        XCTAssertEqual(appState.shownSession.text, "# B")
        appState.cancelAutosave(for: sessionA)

        try appState.open(url: fileA, rememberAsLastOpened: false, preserveWorkspace: false)

        XCTAssertNil(appState.workspaceRootURL)
        XCTAssertEqual(try String(contentsOf: fileA, encoding: .utf8), "# A unsaved")
        XCTAssertEqual(appState.shownSession.text, "# A unsaved")
        appState.replaceDocumentText("# A again", in: appState.shownSession)
        try appState.save(session: appState.shownSession)
        XCTAssertEqual(try String(contentsOf: fileA, encoding: .utf8), "# A again")
    }

    func testReopeningAWarmFileWhenItsDiskCopyIsUnreadableKeepsTheWorkspace() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileA = root.appendingPathComponent("a.md")
        let fileB = root.appendingPathComponent("b.md")
        try "# A".write(to: fileA, atomically: true, encoding: .utf8)
        try "# B".write(to: fileB, atomically: true, encoding: .utf8)
        let appState = try await openWorkspace(root, showing: fileA)
        appState.openWorkspaceFile(fileB.standardizedFileURL)
        let sessionB = appState.shownSession
        let workspaceRoot = appState.workspaceRootURL

        try Data([0xFF, 0xFE]).write(to: fileA)
        XCTAssertThrowsError(
            try appState.open(url: fileA, rememberAsLastOpened: false, preserveWorkspace: false)
        )

        XCTAssertEqual(appState.workspaceRootURL, workspaceRoot)
        XCTAssertTrue(appState.shownSession === sessionB)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewLinkOpeningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func openWorkspace(_ root: URL, showing file: URL) async throws -> AppState {
        let appState = AppState(
            lastOpenedFileStore: MemoryLastOpenedFileStore(),
            recentItemStore: MemoryRecentItemStore(),
            shouldRestoreLastOpenedFile: false
        )
        addTeardownBlock { @MainActor in appState.closeWorkspace() }
        _ = WorkspaceFixtureEventSettle.settle(root: root)
        appState.openExternalFile(root)
        let deadline = Date().addingTimeInterval(5)
        while appState.workspaceTree == nil
            || appState.workspaceInstalledCaptureGeneration != appState.workspaceGeneration
        {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for the workspace capture")
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        appState.openWorkspaceFile(file.standardizedFileURL)
        XCTAssertEqual(appState.shownSession.fileURL?.lastPathComponent, file.lastPathComponent)
        return appState
    }
}
