import Foundation
import MarkdownCore
@testable import Plainsong
import XCTest

/// New File's save panel and preview links outside the root follow the Open rule without
/// losing the refusals that run before a file is emptied or a window appears.
extension WindowOpenRoutingAppTests {
    func testNewFileInAnEmptyWindowCreatesTheFileThere() throws {
        try primary.open(url: write("A.md", "alpha"), rememberAsLastOpened: false, preserveWorkspace: false)
        let empty = try openNewWindow()
        let chosen = try write("B.md", "old")

        empty.createNewFile(at: chosen)

        XCTAssertEqual(sceneRequests, 1, "only the New Window above asked for a scene")
        XCTAssertNil(empty.presentedError)
        XCTAssertEqual(empty.shownSession.fileURL?.lastPathComponent, "B.md")
        XCTAssertEqual(try contents(of: chosen), "")
        XCTAssertEqual(primary.shownSession.text, "alpha")
    }

    func testNewFileFromANonEmptyWindowEmptiesTheFileOnlyInTheNewWindow() throws {
        try primary.open(url: write("A.md", "alpha"), rememberAsLastOpened: false, preserveWorkspace: false)
        let chosen = try write("B.md", "keep me")
        attachesScenesImmediately = false

        primary.createNewFile(at: chosen)

        XCTAssertEqual(sceneRequests, 1)
        XCTAssertEqual(try contents(of: chosen), "keep me", "no window has opened the file yet")
        let opened = attachNextScene()
        XCTAssertEqual(try contents(of: chosen), "")
        XCTAssertEqual(opened.shownSession.fileURL?.lastPathComponent, "B.md")
        XCTAssertNil(opened.presentedError)
        XCTAssertEqual(primary.shownSession.text, "alpha")
        XCTAssertNil(primary.presentedError)
    }

    func testNewFileWhoseWindowNeverOpensLeavesTheChosenFileAlone() throws {
        try primary.open(url: write("A.md", "alpha"), rememberAsLastOpened: false, preserveWorkspace: false)
        let chosen = try write("B.md", "keep me")
        attachesScenesImmediately = false

        primary.createNewFile(at: chosen)
        WorkspaceWindowRequests.shared.expireAllForTesting()

        XCTAssertEqual(primary.presentedError?.title, "Could Not Create File")
        XCTAssertTrue(attachNextScene().isEmptyWorkspaceWindow, "the expired request does not run later")
        XCTAssertEqual(try contents(of: chosen), "keep me")
    }

    func testNewFileRefusedInTheNewWindowLeavesTheChosenFileAlone() throws {
        try primary.open(url: write("A.md", "alpha"), rememberAsLastOpened: false, preserveWorkspace: false)
        let chosen = try write("B.md", "keep me")
        attachesScenesImmediately = false
        primary.createNewFile(at: chosen)

        primary.registry.workspaceMutationNamespaceDepth = 1
        let opened = attachNextScene()
        primary.registry.workspaceMutationNamespaceDepth = 0

        XCTAssertEqual(try contents(of: chosen), "keep me")
        XCTAssertFalse(KeyWindowRouter.shared.hasAttachedWindow(opened), "the blank window closed")
        XCTAssertEqual(primary.presentedError?.title, "Could Not Create File")
        XCTAssertEqual(primary.shownSession.text, "alpha")
    }

    func testAPreviewLinkToAnUnreadableFileRequestsNoWindow() throws {
        let post = try write("post.md", "[out](out.md) [gone](gone.md)")
        let unreadable = try write("out.md", "secret")
        try setPermissions(0o000, of: unreadable)
        defer { try? setPermissions(0o600, of: unreadable) }
        try primary.open(url: post, rememberAsLastOpened: false, preserveWorkspace: false)

        for href in ["out.md", "gone.md"] {
            primary.presentedError = nil
            primary.openPreviewLink(href)
            XCTAssertEqual(primary.presentedError?.title, "Could Not Open File", href)
        }

        XCTAssertEqual(sceneRequests, 0, "no window appears for a file that cannot be read")
        XCTAssertEqual(primary.shownSession.fileURL?.lastPathComponent, "post.md")
    }

    /// WD1 comes before the readability check: the window that shows the file has its text.
    func testAPreviewLinkToAnUnreadableFileAnotherWindowShowsFocusesThatWindow() throws {
        let shown = try write("out.md", "shown")
        try primary.open(url: shown, rememberAsLastOpened: false, preserveWorkspace: false)
        let other = try openNewWindow()
        try other.open(url: write("post.md", "[out](out.md)"), rememberAsLastOpened: false, preserveWorkspace: false)
        try setPermissions(0o000, of: shown)
        defer { try? setPermissions(0o600, of: shown) }

        other.openPreviewLink("out.md")

        XCTAssertTrue(KeyWindowRouter.shared.focusedWindowState === primary.windowState)
        XCTAssertNil(other.presentedError)
        XCTAssertEqual(sceneRequests, 1)
    }

    /// An empty window replaces nothing, so a document no window shows comes back from memory
    /// with its unsaved text even when its disk copy cannot be read.
    func testAnEmptyWindowShowsAWarmDirtyDocumentWhoseDiskCopyIsUnreadable() throws {
        let file = try write("A.md", "alpha")
        try primary.open(url: file, rememberAsLastOpened: false, preserveWorkspace: false)
        let alpha = primary.shownSession
        primary.replaceDocumentText("alpha unsaved", in: alpha)
        try primary.open(url: write("B.md", "beta"), rememberAsLastOpened: false, preserveWorkspace: true)
        primary.cancelAutosave(for: alpha)
        let empty = try openNewWindow()
        try Data([0xFF, 0xFE]).write(to: file)

        empty.routeOpen(file)

        XCTAssertNil(empty.presentedError)
        XCTAssertTrue(empty.shownSession === alpha)
        XCTAssertEqual(alpha.text, "alpha unsaved")
        XCTAssertEqual(primary.shownSession.text, "beta")
    }

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func setPermissions(_ mode: Int, of url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}
