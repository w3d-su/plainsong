import AppKit
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// File › Save As… (`AppState+SaveAs.swift`): the shown session moves to the chosen file and
/// the original keeps its on-disk bytes. The write itself is Save Copy's, which
/// `AppStateTests` and `ExportDestinationOwnershipAppTests` cover in depth; these cases pin
/// what differs for a source file that still exists.
@MainActor
final class AppStateSaveAsTests: XCTestCase {
    func testSaveAsInsideWorkspaceWritesUnsavedTextAndRehomesTheSession() throws {
        let fixture = try makeWorkspaceFixture()
        let destination = fixture.root.appendingPathComponent("copy.md")

        XCTAssertTrue(fixture.appState.canSaveAs)
        try fixture.appState.saveCurrentDocumentAs(to: destination)

        XCTAssertEqual(try text(at: destination), "unsaved A")
        XCTAssertEqual(try text(at: fixture.originalURL), "disk A")
        let session = fixture.session
        XCTAssertTrue(fixture.appState.shownSession === session)
        XCTAssertEqual(session.fileURL?.lastPathComponent, "copy.md")
        XCTAssertFalse(session.isDirty)
        let stateURL = try XCTUnwrap(fixture.appState.sessionStateURL(for: session))
        XCTAssertEqual(stateURL.lastPathComponent, "copy.md")
        XCTAssertTrue(fixture.appState.registry.sessionCache[stateURL] === session)
        XCTAssertNil(fixture.appState.registry.sessionCache[fixture.originalURL])
        XCTAssertNil(fixture.appState.lastKnownDiskHashes[fixture.originalURL])
        XCTAssertNotNil(fixture.appState.lastKnownDiskHashes[stateURL])
        XCTAssertEqual(
            fixture.appState.anchoredSessionFileBinding(for: session)?.location.relativePath,
            "copy.md"
        )
        XCTAssertEqual(fixture.recents.savedURLs.map(\.lastPathComponent), ["copy.md"])
        XCTAssertTrue(fixture.appState.canSave)

        // The session now owns the new file: a later Save writes there, not to the original.
        fixture.appState.replaceDocumentText("second edit")
        try fixture.appState.saveCurrentDocument()
        XCTAssertEqual(try text(at: destination), "second edit")
        XCTAssertEqual(try text(at: fixture.originalURL), "disk A")
    }

    func testSaveAsOutsideWorkspaceKeepsTheWorkspaceOpen() throws {
        let fixture = try makeWorkspaceFixture()
        let outside = try makeTemporaryDirectory()
        let destination = outside.appendingPathComponent("external.md")

        try fixture.appState.saveCurrentDocumentAs(to: destination)

        XCTAssertEqual(try text(at: destination), "unsaved A")
        XCTAssertEqual(try text(at: fixture.originalURL), "disk A")
        XCTAssertEqual(fixture.appState.workspaceRootURL, fixture.root)
        XCTAssertEqual(fixture.session.fileURL?.lastPathComponent, "external.md")
        XCTAssertFalse(fixture.session.isDirty)
        XCTAssertNil(fixture.appState.registry.sessionCache[fixture.originalURL])
    }

    func testSaveAsOverTheCurrentFileIsAPlainSave() throws {
        let fixture = try makeWorkspaceFixture()

        try fixture.appState.saveCurrentDocumentAs(to: fixture.originalURL)

        XCTAssertEqual(try text(at: fixture.originalURL), "unsaved A")
        XCTAssertEqual(fixture.session.fileURL, fixture.originalURL)
        XCTAssertFalse(fixture.session.isDirty)
        XCTAssertTrue(fixture.appState.registry.sessionCache[fixture.originalURL] === fixture.session)
        XCTAssertEqual(fixture.recents.savedURLs, [])
    }

    func testSaveAsOverACaseAliasOfTheCurrentFileIsAPlainSave() throws {
        let fixture = try makeWorkspaceFixture()
        let alias = fixture.root.appendingPathComponent("POST.md")
        guard FileManager.default.fileExists(atPath: alias.path(percentEncoded: false)) else {
            // A case-sensitive temporary volume has no alias to test.
            return
        }

        try fixture.appState.saveCurrentDocumentAs(to: alias)

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.root.path(percentEncoded: false)),
            ["post.md"]
        )
        XCTAssertEqual(try text(at: fixture.originalURL), "unsaved A")
        XCTAssertEqual(fixture.session.fileURL, fixture.originalURL)
    }

    func testSaveAsRefusesWhileAnExternalChangeIsUnresolved() throws {
        let fixture = try makeWorkspaceFixture()
        fixture.appState.pendingExternalTexts[fixture.originalURL] = "disk B"
        let destination = fixture.root.appendingPathComponent("copy.md")

        XCTAssertFalse(fixture.appState.canSaveAs)
        XCTAssertThrowsError(try fixture.appState.saveCurrentDocumentAs(to: destination)) { error in
            guard case AppStateError.unresolvedExternalChange = error else {
                return XCTFail("Expected the unresolved external change to fence Save As, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        XCTAssertEqual(fixture.session.fileURL, fixture.originalURL)
        XCTAssertTrue(fixture.session.isDirty)
    }

    func testSaveAsRefusesADestinationOwnedByAnotherSession() throws {
        let fixture = try makeWorkspaceFixture()
        let otherURL = fixture.root.appendingPathComponent("other.md")
        try writeText("disk other", to: otherURL)
        let otherLocation = try fixture.authority.location(relativePath: "other.md")
        let otherRead = try MarkdownFileStore().loadResult(at: otherLocation)
        let otherSession = DocumentSession(text: "disk other", url: otherLocation.fileURL, fileKind: .markdown)
        fixture.appState.registry.sessionCache[otherLocation.fileURL] = otherSession
        fixture.appState.anchoredSessionFileBindings[ObjectIdentifier(otherSession)] =
            AnchoredWorkspaceSessionFileBinding(
                location: otherLocation,
                identity: otherRead.metadata.identity,
                sha256Digest: otherRead.sha256Digest
            )

        XCTAssertThrowsError(try fixture.appState.saveCurrentDocumentAs(to: otherURL)) { error in
            guard case AppStateError.invalidSessionIdentity = error else {
                return XCTFail("Expected the other session's ownership to refuse Save As, got \(error)")
            }
        }
        XCTAssertEqual(try text(at: otherURL), "disk other")
        XCTAssertEqual(fixture.session.fileURL, fixture.originalURL)
        XCTAssertTrue(fixture.session.isDirty)
    }

    func testSaveAsForAMissingFileIsTheBannerSaveCopy() throws {
        let fixture = try makeWorkspaceFixture()
        try FileManager.default.removeItem(at: fixture.originalURL)
        fixture.appState.markSessionDetachedFromMissingFile(fixture.session, url: fixture.originalURL)
        let destination = fixture.root.appendingPathComponent("recovered.md")

        XCTAssertFalse(fixture.appState.canSave)
        XCTAssertTrue(fixture.appState.canSaveAs)
        XCTAssertTrue(MenuBarSnapshot(appState: fixture.appState).canSaveAs)
        try fixture.appState.saveCurrentDocumentAs(to: destination)

        XCTAssertEqual(try text(at: destination), "unsaved A")
        XCTAssertNil(fixture.appState.missingFilePrompt)
        XCTAssertFalse(fixture.appState.detachedSessionURLs.contains(fixture.originalURL))
        XCTAssertEqual(fixture.session.fileURL?.lastPathComponent, "recovered.md")
        XCTAssertFalse(fixture.session.isDirty)
    }

    func testSaveAsIsUnavailableWithoutAFileBackedDocument() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)

        XCTAssertFalse(appState.canSaveAs)
        XCTAssertFalse(MenuBarSnapshot(appState: appState).canSaveAs)
        XCTAssertFalse(MenuBarSnapshot(appState: nil, recentItemURLs: []).canSaveAs)
    }

    func testFileMenuPlacesSaveAsAfterSaveWithShiftCommandS() async throws {
        // The hosted app builds its real SwiftUI command menu on the main run loop.
        for _ in 0 ..< 100 {
            if NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu?
                .items.contains(where: { $0.title == "Save As…" }) == true
            {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let menu = try XCTUnwrap(NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu)
        let items = menu.items
        let saveIndex = try XCTUnwrap(items.firstIndex(where: { $0.title == "Save" }))
        let saveAsIndex = try XCTUnwrap(items.firstIndex(where: { $0.title == "Save As…" }))
        XCTAssertEqual(saveAsIndex, saveIndex + 1)
        XCTAssertEqual(items.filter { $0.title == "Save As…" }.count, 1)
        XCTAssertEqual(items[saveAsIndex].keyEquivalent.lowercased(), "s")
        XCTAssertEqual(
            items[saveAsIndex].keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask),
            [.command, .shift]
        )
    }
}

// MARK: - Fixture

@MainActor
private extension AppStateSaveAsTests {
    struct WorkspaceFixture {
        let root: URL
        let authority: WorkspaceFileSystemRootAuthority
        let appState: AppState
        let originalURL: URL
        let session: DocumentSession
        let recents: SaveAsRecentItemStore
    }

    /// A workspace showing `post.md` ("disk A" on disk) with unsaved text "unsaved A".
    func makeWorkspaceFixture() throws -> WorkspaceFixture {
        let root = try makeTemporaryDirectory()
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: "post.md")
        try writeText("disk A", to: location.fileURL)
        let read = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(
            text: "unsaved A",
            url: location.fileURL,
            fileKind: .markdown,
            isDirty: true
        )
        let recents = SaveAsRecentItemStore()
        let appState = AppState(
            shownSession: session,
            recentItemStore: recents,
            shouldRestoreLastOpenedFile: false
        )
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.registry.sessionCache[location.fileURL] = session
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] =
            AnchoredWorkspaceSessionFileBinding(
                location: location,
                identity: read.metadata.identity,
                sha256Digest: read.sha256Digest
            )
        return WorkspaceFixture(
            root: root,
            authority: authority,
            appState: appState,
            originalURL: location.fileURL,
            session: session,
            recents: recents
        )
    }

    /// Canonical temporary directory: the anchored writer refuses symlinked path components.
    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateSaveAsTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return try WorkspaceFileSystemRootAuthority(rootURL: url).canonicalRootURL
    }

    func writeText(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    func text(at url: URL) throws -> String {
        try XCTUnwrap(String(bytes: Data(contentsOf: url), encoding: .utf8))
    }
}

private final class SaveAsRecentItemStore: RecentItemPersisting {
    private(set) var savedURLs: [URL] = []

    func save(_ url: URL) throws {
        savedURLs.append(url)
    }

    func restore() throws -> [URL] {
        savedURLs
    }
}
