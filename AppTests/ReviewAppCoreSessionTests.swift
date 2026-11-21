import AppKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// Regression tests for the App core review fixes.
@MainActor
final class ReviewAppCoreSessionTests: XCTestCase {
    /// A clean session keeps an unresolved conflict when the change arrived during IME
    /// composition. Evicting it left the URL-keyed conflict without an owner, and the
    /// file then could not be opened again.
    func testCleanSessionWithUnresolvedExternalConflictIsProtectedFromLRUEviction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewAppCoreSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let conflictedURL = root.appendingPathComponent("conflicted.md").standardizedFileURL
        let otherURL = root.appendingPathComponent("other.md").standardizedFileURL
        let conflicted = DocumentSession(text: "mine", url: conflictedURL, fileKind: .markdown, isDirty: false)
        let other = DocumentSession(text: "other", url: otherURL, fileKind: .markdown, isDirty: false)
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        appState.registry.sessionCache[conflictedURL] = conflicted
        appState.pendingExternalTexts[conflictedURL] = "theirs"
        appState.sessionPolicy = WorkspaceSessionLRUPolicy(limit: 1)
        _ = appState.sessionPolicy.access(conflictedURL, isDirty: false)
        appState.registry.sessionCache[otherURL] = other

        appState.handleSessionAccess(url: otherURL, isDirty: false)

        XCTAssertTrue(appState.protectedSessionURLs().contains(conflictedURL))
        XCTAssertTrue(appState.registry.sessionCache[conflictedURL] === conflicted)
        XCTAssertEqual(appState.pendingExternalTexts[conflictedURL], "theirs")
    }

    func testResolvingAConflictClearsThePromptInTheWindowShowingTheSession() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        fixture.secondWindow.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: fixture.secondURL)
        XCTAssertTrue(fixture.appState.isSaveBlockedByWindowPrompt(at: fixture.secondURL))

        fixture.appState.clearExternalChangePromptIfOwned(by: fixture.second, canonicalURL: fixture.secondURL)

        XCTAssertNil(fixture.secondWindow.externalChangePrompt)
        XCTAssertFalse(fixture.appState.isSaveBlockedByWindowPrompt(at: fixture.secondURL))
    }

    func testAMissingFileObservedByAnotherFacadeShowsTheBannerInTheWindowShowingTheSession() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)

        fixture.appState.markSessionDetachedFromMissingFile(fixture.second, url: fixture.secondURL)

        XCTAssertEqual(fixture.secondWindow.missingFilePrompt?.fileURL, fixture.secondURL)
        XCTAssertNil(fixture.appState.missingFilePrompt)
    }

    func testSaveRefusesASessionWhosePromptIsShownByAnotherWindow() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        fixture.secondWindow.missingFilePrompt = AppState.MissingFilePrompt(fileURL: fixture.secondURL)

        XCTAssertThrowsError(try fixture.appState.save(session: fixture.second))
        XCTAssertEqual(try String(contentsOf: fixture.secondURL, encoding: .utf8), "second on disk")
    }

    func testNewFileLeavesTheChosenFileAloneWhenTheWorkspaceCannotClose() throws {
        let root = try makeRoot()
        let chosen = root.appendingPathComponent("existing.md")
        try Data("keep me".utf8).write(to: chosen)
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        appState.registry.workspaceMutationNamespaceDepth = 1

        XCTAssertThrowsError(try appState.createEmptyFileAndOpen(at: chosen))
        XCTAssertEqual(try String(contentsOf: chosen, encoding: .utf8), "keep me")

        appState.registry.workspaceMutationNamespaceDepth = 0
        try appState.createEmptyFileAndOpen(at: chosen)

        XCTAssertEqual(try String(contentsOf: chosen, encoding: .utf8), "")
        XCTAssertEqual(appState.shownSession.fileURL?.lastPathComponent, "existing.md")
    }

    func testNewFileRefusesAFileADirtySessionOwns() throws {
        let root = try makeRoot()
        let chosen = root.appendingPathComponent("existing.md")
        try Data("keep me".utf8).write(to: chosen)
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        try appState.open(url: chosen, rememberAsLastOpened: false, preserveWorkspace: false)
        appState.replaceDocumentText("unsaved")

        XCTAssertThrowsError(try appState.createEmptyFileAndOpen(at: chosen))
        XCTAssertEqual(try String(contentsOf: chosen, encoding: .utf8), "keep me")
        XCTAssertEqual(appState.shownSession.text, "unsaved")
    }

    func testClosingAWorkspaceDoesNotCarryARunningImagePlacementFenceToTheNextWorkspace() throws {
        let root = try makeRoot()
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        let generation = appState.workspaceGeneration
        let lease = WorkspaceImageAssetInsertionLease(appState: appState, rootURL: root)
        XCTAssertEqual(appState.workspaceImageAssetInsertionCount, 1)

        try appState.closeWorkspaceForReplacement()

        XCTAssertEqual(appState.workspaceImageAssetInsertionCount, 0)
        XCTAssertGreaterThan(appState.workspaceGeneration, generation)
        lease.release()
        XCTAssertEqual(appState.workspaceImageAssetInsertionCount, 0)
    }

    func testExportIsOfferedForADotMarkdownFile() throws {
        let root = try makeRoot()
        let url = root.appendingPathComponent("post.markdown")
        let appState = AppState(
            shownSession: DocumentSession(text: "# Post", url: url, fileKind: .markdown),
            shouldRestoreLastOpenedFile: false
        )
        let window = NSWindow()
        appState.exportHTMLOperations.panelWindowProvider = { window }

        XCTAssertTrue(appState.canExportCurrentDocumentAsHTML)
    }

    func testReplaceAuthorityDropsObserversOfReleasedOwners() throws {
        let authority = AppState(shouldRestoreLastOpenedFile: false).registry.replaceAuthority
        let baseline = authority.advanceObserverCount
        var advances = 0
        var released: NSObject? = NSObject()
        try authority.observeAdvances(from: XCTUnwrap(released)) { _, _ in advances += 1 }
        released = nil
        authority.advance()
        let survivor = NSObject()
        authority.observeAdvances(from: survivor) { _, _ in advances += 10 }
        authority.advance()

        XCTAssertEqual(advances, 10)
        XCTAssertLessThanOrEqual(authority.advanceObserverCount, baseline + 1)
    }

    func testAPreviewLinkToAnUnreadableFileOutsideTheWorkspaceKeepsTheWorkspaceOpen() throws {
        let parent = try makeRoot()
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = parent.appendingPathComponent("outside.md")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: outside.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: outside.path) }
        let post = root.appendingPathComponent("post.md")
        try Data("[out](../outside.md)".utf8).write(to: post)
        let appState = AppState(
            shownSession: DocumentSession(text: "[out](../outside.md)", url: post, fileKind: .markdown),
            shouldRestoreLastOpenedFile: false
        )
        appState.workspaceRootURL = root

        appState.openPreviewLink("../outside.md")

        XCTAssertEqual(appState.workspaceRootURL, root)
        XCTAssertNotNil(appState.presentedError)
        XCTAssertEqual(appState.shownSession.fileURL, post)
    }

    private func makeRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewAppCoreSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try WorkspaceFileSystemRootAuthority(rootURL: directory).canonicalRootURL
    }
}
