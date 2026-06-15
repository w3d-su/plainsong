import MarkdownCore
@testable import Plainsong
import XCTest

@MainActor
final class AppStateTests: XCTestCase {
    func testEmptyStateCannotSaveAndUsesDefaultTitle() {
        let appState = AppState()

        XCTAssertFalse(appState.hasOpenDocument)
        XCTAssertFalse(appState.canSave)
        XCTAssertEqual(appState.windowTitle, "Plainsong")
    }

    func testReplaceDocumentTextDoesNotRegisterAppLevelTypingUndo() {
        let appState = AppState()

        appState.replaceDocumentText("Typed text")

        XCTAssertEqual(appState.currentDocument.text, "Typed text")
    }

    func testSavingOpenDocumentDoesNotRewriteLastOpenedBookmark() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("post.md")
        try "Original".write(to: url, atomically: true, encoding: .utf8)
        let lastOpenedFileStore = SpyLastOpenedFileStore()
        let appState = AppState(lastOpenedFileStore: lastOpenedFileStore)

        appState.openExternalFile(url)
        appState.replaceDocumentText("Changed")
        appState.save()

        XCTAssertEqual(lastOpenedFileStore.savedURLs, [url])
    }

    func testPreviewCheckboxWritebackUpdatesOnlyRequestedTaskLine() {
        let appState = AppState(
            currentDocument: DocumentSession(
                text: """
                - [ ] first
                plain text
                - [x] third
                """,
                fileKind: .markdown
            )
        )

        appState.setTaskCheckbox(line: 3, checked: false, version: appState.currentDocument.version)

        XCTAssertEqual(
            appState.currentDocument.text,
            """
            - [ ] first
            plain text
            - [ ] third
            """
        )
    }

    func testPreviewCheckboxWritebackIgnoresStaleRenderVersion() {
        let appState = AppState(
            currentDocument: DocumentSession(
                text: """
                - [ ] first
                - [ ] second
                """,
                fileKind: .markdown
            )
        )

        let staleVersion = appState.currentDocument.version
        appState.replaceDocumentText(
            """
            inserted
            - [ ] first
            - [ ] second
            """
        )

        appState.setTaskCheckbox(line: 1, checked: true, version: staleVersion)

        XCTAssertEqual(
            appState.currentDocument.text,
            """
            inserted
            - [ ] first
            - [ ] second
            """
        )
    }

    func testPreviewVisibilityPersistsThroughUserDefaults() throws {
        let suiteName = "PlainsongTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let first = AppState(userDefaults: defaults)
        XCTAssertFalse(first.isPreviewVisible)

        first.togglePreview()

        let second = AppState(userDefaults: defaults)
        XCTAssertTrue(second.isPreviewVisible)
    }

    func testOpeningFolderBuildsWorkspaceTreeAndSelectsFirstMarkdownFile() async throws {
        let root = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("content"),
            withIntermediateDirectories: true
        )
        let post = root.appendingPathComponent("content/post.md")
        try "# Workspace".write(to: post, atomically: true, encoding: .utf8)
        try "notes".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let appState = AppState(shouldRestoreLastOpenedFile: false)

        appState.openExternalFile(root)

        try await waitUntil("workspace tree loaded") {
            appState.workspaceRootURL == root.standardizedFileURL &&
                appState.workspaceTree?.selectedNode?.relativePath == "content/post.md" &&
                appState.currentDocument.fileURL?.standardizedFileURL == post.standardizedFileURL
        }
    }

    func testOpeningFolderPublishesCompletionWorkspace() async throws {
        let root = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("content"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("assets"),
            withIntermediateDirectories: true
        )
        let post = root.appendingPathComponent("content/post.md")
        try "# Workspace\n\n## Details".write(to: post, atomically: true, encoding: .utf8)
        try """
        ---
        layout: post
        custom_key: yes
        ---
        Body
        """.write(to: root.appendingPathComponent("content/sibling.md"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: root.appendingPathComponent("assets/hero.png"))
        let appState = AppState(shouldRestoreLastOpenedFile: false)

        appState.openExternalFile(root)

        try await waitUntil("completion workspace loaded") {
            appState.completionWorkspace.currentFilePath == "content/post.md" &&
                appState.completionWorkspace.markdownFilePaths.contains("content/sibling.md") &&
                appState.completionWorkspace.imageFilePaths == ["assets/hero.png"] &&
                appState.completionWorkspace.currentFileHeadingAnchors == ["#workspace", "#details"] &&
                appState.completionWorkspace.frontmatterKeys.contains("custom_key")
        }
    }

    func testCleanOpenFileReloadsExternalChangesSilently() async throws {
        let root = try makeTemporaryDirectory()
        let post = root.appendingPathComponent("post.md")
        try "Original".write(to: post, atomically: true, encoding: .utf8)
        let appState = AppState(shouldRestoreLastOpenedFile: false)

        appState.openExternalFile(root)
        try await waitUntil("post selected") {
            appState.currentDocument.fileURL?.standardizedFileURL == post.standardizedFileURL
        }

        try "Changed elsewhere".write(to: post, atomically: true, encoding: .utf8)
        appState.refreshWorkspaceAfterFileSystemChange()

        try await waitUntil("clean file reloaded") {
            appState.currentDocument.text == "Changed elsewhere" &&
                appState.externalChangePrompt == nil
        }
    }

    func testDirtyOpenFileShowsExternalChangePrompt() async throws {
        let root = try makeTemporaryDirectory()
        let post = root.appendingPathComponent("post.md")
        try "Original".write(to: post, atomically: true, encoding: .utf8)
        let appState = AppState(shouldRestoreLastOpenedFile: false)

        appState.openExternalFile(root)
        try await waitUntil("post selected") {
            appState.currentDocument.fileURL?.standardizedFileURL == post.standardizedFileURL
        }

        appState.replaceDocumentText("My edits")
        try "Changed elsewhere".write(to: post, atomically: true, encoding: .utf8)
        appState.refreshWorkspaceAfterFileSystemChange()

        try await waitUntil("dirty conflict prompted") {
            appState.currentDocument.text == "My edits" &&
                appState.externalChangePrompt?.fileURL.standardizedFileURL == post.standardizedFileURL
        }
    }

    func testWarmCleanSessionReloadsDiskChangeOnCacheHit() async throws {
        let root = try makeTemporaryDirectory()
        let firstPost = root.appendingPathComponent("a.md")
        let secondPost = root.appendingPathComponent("b.md")
        try writeText("A original", to: firstPost)
        try writeText("B original", to: secondPost)
        let appState = AppState(shouldRestoreLastOpenedFile: false)

        appState.openExternalFile(root)
        try await waitUntil("first post selected") {
            appState.currentDocument.fileURL?.standardizedFileURL == firstPost.standardizedFileURL
        }

        appState.openWorkspaceFile(secondPost)
        try await waitUntil("second post selected") {
            appState.currentDocument.fileURL?.standardizedFileURL == secondPost.standardizedFileURL
        }

        try writeText("A changed on disk", to: firstPost, touchOffset: 5)
        appState.openWorkspaceFile(firstPost)

        try await waitUntil("warm session reloaded from disk") {
            appState.currentDocument.fileURL?.standardizedFileURL == firstPost.standardizedFileURL &&
                appState.currentDocument.text == "A changed on disk" &&
                appState.externalChangePrompt == nil
        }
    }

    func testWarmDirtySessionShowsPromptOnCacheHitAndDoesNotAutosaveOverDisk() async throws {
        let root = try makeTemporaryDirectory()
        let firstPost = root.appendingPathComponent("a.md")
        let secondPost = root.appendingPathComponent("b.md")
        try writeText("A original", to: firstPost)
        try writeText("B original", to: secondPost)
        let appState = AppState(shouldRestoreLastOpenedFile: false)

        appState.openExternalFile(root)
        try await waitUntil("first post selected") {
            appState.currentDocument.fileURL?.standardizedFileURL == firstPost.standardizedFileURL
        }

        appState.replaceDocumentText("A unsaved edits")
        appState.openWorkspaceFile(secondPost)
        try await waitUntil("second post selected") {
            appState.currentDocument.fileURL?.standardizedFileURL == secondPost.standardizedFileURL
        }

        try writeText("A changed on disk", to: firstPost, touchOffset: 5)
        appState.openWorkspaceFile(firstPost)

        try await waitUntil("dirty warm session prompted") {
            appState.currentDocument.fileURL?.standardizedFileURL == firstPost.standardizedFileURL &&
                appState.currentDocument.text == "A unsaved edits" &&
                appState.externalChangePrompt?.fileURL.standardizedFileURL == firstPost.standardizedFileURL
        }

        try await Task.sleep(nanoseconds: 1_250_000_000)
        XCTAssertEqual(try String(contentsOf: firstPost, encoding: .utf8), "A changed on disk")
    }

    func testDeletedCurrentFileDetachesAndSuppressesAutosave() async throws {
        let directory = try makeTemporaryDirectory()
        let post = directory.appendingPathComponent("post.md")
        try writeText("Original", to: post)
        let appState = AppState(shouldRestoreLastOpenedFile: false)

        appState.openExternalFile(post)
        appState.replaceDocumentText("Unsaved after delete")
        try FileManager.default.removeItem(at: post)
        appState.refreshWorkspaceAfterFileSystemChange()

        XCTAssertEqual(appState.missingFilePrompt?.fileURL.standardizedFileURL, post.standardizedFileURL)
        XCTAssertFalse(appState.canSave)

        try await Task.sleep(nanoseconds: 1_250_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: post.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlainsongAppStateTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeText(_ text: String, to url: URL, touchOffset: TimeInterval = 0) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        if touchOffset != 0 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(touchOffset)],
                ofItemAtPath: url.path
            )
        }
    }

    func testUntitledFileNameDeduplicatesAgainstExistingFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateNewFileTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(AppState.untitledFileName(in: directory), "Untitled.md")

        try Data().write(to: directory.appendingPathComponent("Untitled.md"))
        XCTAssertEqual(AppState.untitledFileName(in: directory), "Untitled 2.md")

        try Data().write(to: directory.appendingPathComponent("Untitled 2.md"))
        XCTAssertEqual(AppState.untitledFileName(in: directory), "Untitled 3.md")
    }

    private func waitUntil(
        _ description: String,
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }
}

private final class SpyLastOpenedFileStore: LastOpenedFilePersisting {
    private(set) var savedURLs: [URL] = []
    var restoredURL: URL?

    func save(_ url: URL) throws {
        savedURLs.append(url)
    }

    func restore() throws -> URL? {
        restoredURL
    }
}
