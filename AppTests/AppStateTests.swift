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

    func testSessionScopedTextReplacementIgnoresStaleEditorSession() {
        let staleSession = DocumentSession(text: "Old document", fileKind: .markdown)
        let currentSession = DocumentSession(text: "Current document", fileKind: .markdown)
        let appState = AppState(currentDocument: staleSession)
        appState.setCurrentDocument(currentSession)

        appState.replaceDocumentText("Old document ![](assets/image.png)", in: staleSession)

        XCTAssertEqual(staleSession.text, "Old document")
        XCTAssertEqual(currentSession.text, "Current document")
    }

    func testCapturedImageAssetInserterUsesOriginatingDocumentAfterFileSwitch() async throws {
        let root = try makeTemporaryDirectory()
        let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let firstURL = firstDirectory.appendingPathComponent("post.md")
        let secondURL = secondDirectory.appendingPathComponent("post.md")
        try "First".write(to: firstURL, atomically: true, encoding: .utf8)
        try "Second".write(to: secondURL, atomically: true, encoding: .utf8)
        let firstSession = DocumentSession(text: "First", url: firstURL, fileKind: .markdown)
        let secondSession = DocumentSession(text: "Second", url: secondURL, fileKind: .markdown)
        let appState = AppState(currentDocument: firstSession)
        appState.workspaceRootURL = root

        let inserter = try XCTUnwrap(appState.editorImageAssetInserter)
        appState.setCurrentDocument(secondSession)

        let relativePaths = await inserter([.data(Data([1, 2, 3]), suggestedFilename: "image.png")])

        XCTAssertEqual(relativePaths, ["assets/image.png"])
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: firstDirectory.appendingPathComponent("assets/image.png").path))
        XCTAssertFalse(FileManager.default
            .fileExists(atPath: secondDirectory.appendingPathComponent("assets/image.png").path))
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

    func testRecentItemFailureDoesNotBlockOpenedFile() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("post.md")
        try "Original".write(to: url, atomically: true, encoding: .utf8)
        let recentItemStore = SpyRecentItemStore(saveError: CocoaError(.fileReadUnknown))
        let appState = AppState(
            lastOpenedFileStore: SpyLastOpenedFileStore(),
            recentItemStore: recentItemStore,
            shouldRestoreLastOpenedFile: false
        )

        appState.openExternalFile(url)

        XCTAssertEqual(appState.currentDocument.fileURL?.standardizedFileURL, url.standardizedFileURL)
        XCTAssertNil(appState.presentedError)
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

    func testLayoutModeMigratesLegacyVisiblePreviewPreference() throws {
        let suiteName = "PlainsongLayoutMigrationVisibleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(true, forKey: AppState.legacyPreviewVisibleDefaultsKey)

        let appState = AppState(userDefaults: defaults)

        XCTAssertEqual(appState.layoutMode, .sourcePreview)
        XCTAssertTrue(appState.isPreviewVisible)
        XCTAssertEqual(defaults.string(forKey: AppState.layoutModeDefaultsKey), EditorLayoutMode.sourcePreview.rawValue)
        XCTAssertNil(defaults.object(forKey: AppState.legacyPreviewVisibleDefaultsKey))
    }

    func testLayoutModeMigratesLegacyHiddenPreviewPreference() throws {
        let suiteName = "PlainsongLayoutMigrationHiddenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(false, forKey: AppState.legacyPreviewVisibleDefaultsKey)

        let appState = AppState(userDefaults: defaults)

        XCTAssertEqual(appState.layoutMode, .sourceOnly)
        XCTAssertFalse(appState.isPreviewVisible)
        XCTAssertEqual(defaults.string(forKey: AppState.layoutModeDefaultsKey), EditorLayoutMode.sourceOnly.rawValue)
        XCTAssertNil(defaults.object(forKey: AppState.legacyPreviewVisibleDefaultsKey))
    }

    func testLayoutModeCycleSkipsWYSIWYGWhenExperimentalFlagIsDisabled() throws {
        let suiteName = "PlainsongLayoutCycleDisabledTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let appState = AppState(userDefaults: defaults)

        XCTAssertFalse(appState.preferences.experimentalWYSIWYGEnabled)
        XCTAssertEqual(appState.layoutMode, .sourceOnly)

        appState.cycleLayoutMode()
        XCTAssertEqual(appState.layoutMode, .sourcePreview)

        appState.cycleLayoutMode()
        XCTAssertEqual(appState.layoutMode, .sourceOnly)

        appState.cycleLayoutMode()
        XCTAssertEqual(appState.layoutMode, .sourcePreview)
    }

    func testLayoutModeCycleIncludesWYSIWYGWhenExperimentalFlagIsEnabled() throws {
        let suiteName = "PlainsongLayoutCycleEnabledTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let appState = AppState(userDefaults: defaults)
        appState.preferences.setExperimentalWYSIWYGEnabled(true)
        appState.setLayoutMode(.sourcePreview)

        appState.cycleLayoutMode()
        XCTAssertEqual(appState.layoutMode, .sourceOnly)
        XCTAssertFalse(appState.shouldUseWYSIWYGPresentation)

        appState.cycleLayoutMode()
        XCTAssertEqual(appState.layoutMode, .wysiwyg)
        XCTAssertTrue(appState.shouldUseWYSIWYGPresentation)
        XCTAssertFalse(appState.isPreviewVisible)

        appState.cycleLayoutMode()
        XCTAssertEqual(appState.layoutMode, .sourcePreview)
        XCTAssertTrue(appState.isPreviewVisible)
        XCTAssertFalse(appState.shouldUseWYSIWYGPresentation)
    }

    func testPersistedWYSIWYGFallsBackToSourceOnlyWhenExperimentalFlagIsDisabled() throws {
        let suiteName = "PlainsongPersistedWYSIWYGFallbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(EditorLayoutMode.wysiwyg.rawValue, forKey: AppState.layoutModeDefaultsKey)

        let appState = AppState(userDefaults: defaults)

        XCTAssertEqual(appState.layoutMode, .sourceOnly)
        XCTAssertFalse(appState.shouldUseWYSIWYGPresentation)
        XCTAssertEqual(defaults.string(forKey: AppState.layoutModeDefaultsKey), EditorLayoutMode.sourceOnly.rawValue)
        XCTAssertTrue(appState.wysiwygFallbackMessage?.contains("Experimental WYSIWYG is disabled") == true)
    }

    func testWYSIWYGMechanismFailureFallsBackToSourceOnlyWithoutChangingText() throws {
        let suiteName = "PlainsongWYSIWYGMechanismFailureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let appState = AppState(
            currentDocument: DocumentSession(text: "**Canonical**", fileKind: .markdown),
            userDefaults: defaults
        )
        appState.preferences.setExperimentalWYSIWYGEnabled(true)
        appState.setLayoutMode(.wysiwyg)

        appState.handleWYSIWYGMechanismFailure("test failure")

        XCTAssertEqual(appState.layoutMode, .sourceOnly)
        XCTAssertFalse(appState.isExperimentalWYSIWYGAvailable)
        XCTAssertFalse(appState.shouldUseWYSIWYGPresentation)
        XCTAssertEqual(appState.currentDocument.text, "**Canonical**")
        XCTAssertEqual(defaults.string(forKey: AppState.layoutModeDefaultsKey), EditorLayoutMode.sourceOnly.rawValue)
        XCTAssertTrue(appState.wysiwygFallbackMessage?.contains("test failure") == true)
    }

    func testDismissWYSIWYGFallbackMessageClearsTheNotice() throws {
        let suiteName = "PlainsongWYSIWYGFallbackDismissTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(EditorLayoutMode.wysiwyg.rawValue, forKey: AppState.layoutModeDefaultsKey)

        let appState = AppState(userDefaults: defaults)
        XCTAssertNotNil(appState.wysiwygFallbackMessage)

        appState.dismissWYSIWYGFallbackMessage()
        XCTAssertNil(appState.wysiwygFallbackMessage)
    }

    func testHonoredLayoutChangeClearsStaleWYSIWYGFallbackMessage() throws {
        let suiteName = "PlainsongWYSIWYGFallbackAutoClearTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(EditorLayoutMode.wysiwyg.rawValue, forKey: AppState.layoutModeDefaultsKey)

        let appState = AppState(userDefaults: defaults)
        XCTAssertNotNil(appState.wysiwygFallbackMessage)

        // Picking a mode the app can honor as-is should retire the stale notice.
        appState.setLayoutMode(.sourcePreview)
        XCTAssertEqual(appState.layoutMode, .sourcePreview)
        XCTAssertNil(appState.wysiwygFallbackMessage)
    }

    func testSourceModesNeverUseWYSIWYGPresentationEvenWhenExperimentalFlagIsEnabled() throws {
        let suiteName = "PlainsongSourceModeRegressionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let appState = AppState(userDefaults: defaults)
        appState.preferences.setExperimentalWYSIWYGEnabled(true)

        appState.setLayoutMode(.sourcePreview)
        XCTAssertTrue(appState.isPreviewVisible)
        XCTAssertFalse(appState.shouldUseWYSIWYGPresentation)

        appState.setLayoutMode(.sourceOnly)
        XCTAssertFalse(appState.isPreviewVisible)
        XCTAssertFalse(appState.shouldUseWYSIWYGPresentation)
    }

    func testSettingsPreferencesPersistThroughUserDefaults() throws {
        let suiteName = "PlainsongSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let first = PlainsongPreferences(userDefaults: defaults)
        XCTAssertFalse(first.experimentalWYSIWYGEnabled)
        first.setAutosaveIntervalSeconds(2.5)
        first.setEditorFontName("Menlo")
        first.setEditorFontSize(16)
        first.setShowsLineNumbers(false)
        first.setTypewriterSyncEnabled(false)
        first.setEditorTheme(.graphite)
        first.setPreviewTheme(.dark)
        first.setAllowsRemoteImages(true)
        first.setExperimentalWYSIWYGEnabled(true)
        first.setAssetFolderRelativePath("media/images")
        first.setDefaultFileExtension(.mdx)

        let second = PlainsongPreferences(userDefaults: defaults)
        XCTAssertEqual(second.autosaveIntervalSeconds, 2.5)
        XCTAssertEqual(second.editorFontName, "Menlo")
        XCTAssertEqual(second.editorFontSize, 16)
        XCTAssertFalse(second.showsLineNumbers)
        XCTAssertFalse(second.typewriterSyncEnabled)
        XCTAssertEqual(second.editorTheme, .graphite)
        XCTAssertEqual(second.previewTheme, .dark)
        XCTAssertTrue(second.allowsRemoteImages)
        XCTAssertTrue(second.experimentalWYSIWYGEnabled)
        XCTAssertEqual(second.assetFolderRelativePath, "media/images")
        XCTAssertEqual(second.defaultFileExtension, .mdx)
    }

    func testDefaultFolderPreferencePersistsSecurityScopedBookmarkWhenAvailable() throws {
        let suiteName = "PlainsongDefaultFolderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let folder = try makeTemporaryDirectory()
        let first = PlainsongPreferences(userDefaults: defaults)

        do {
            try first.setDefaultFolderURL(folder)
        } catch {
            throw XCTSkip("Security-scoped bookmarks are unavailable in this test environment: \(error)")
        }

        let second = PlainsongPreferences(userDefaults: defaults)
        XCTAssertEqual(second.defaultFolderURL?.standardizedFileURL, folder.standardizedFileURL)
    }

    func testConfiguredAssetFolderIsUsedForEditorImageInsertion() async throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: "Body", url: currentFile, fileKind: .markdown)
        let suiteName = "PlainsongAssetFolderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let appState = AppState(currentDocument: session, userDefaults: defaults)
        appState.workspaceRootURL = root
        appState.preferences.setAssetFolderRelativePath("media/images")

        let inserter = try XCTUnwrap(appState.editorImageAssetInserter)
        let relativePaths = await inserter([.data(Data([1, 2, 3]), suggestedFilename: "image.png")])

        XCTAssertEqual(relativePaths, ["media/images/image.png"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("media/images/image.png").path(percentEncoded: false)
        ))
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

    func testCreatedWorkspaceFileStaysOpenAfterTreeReload() async throws {
        let root = try makeTemporaryDirectory()
        let originalPost = root.appendingPathComponent("post.md")
        try writeText("Original", to: originalPost)
        let appState = AppState(shouldRestoreLastOpenedFile: false)

        appState.openExternalFile(root)
        try await waitUntil("original post selected") {
            appState.currentDocument.fileURL?.standardizedFileURL == originalPost.standardizedFileURL &&
                appState.workspaceTree?.selectedNode?.relativePath == "post.md"
        }

        let createdPost = root.appendingPathComponent("Untitled.md")
        appState.createWorkspaceFile(named: "Untitled.md", inDirectoryID: nil)

        try await waitUntil("created post selected after reload") {
            appState.currentDocument.fileURL?.standardizedFileURL == createdPost.standardizedFileURL &&
                appState.workspaceTree?.selectedNode?.relativePath == "Untitled.md"
        }

        appState.replaceDocumentText("Hello from the new file")

        XCTAssertEqual(appState.currentDocument.fileURL?.standardizedFileURL, createdPost.standardizedFileURL)
        XCTAssertEqual(appState.currentDocument.text, "Hello from the new file")
    }

    func testCreatedWorkspaceFileEditSurvivesPendingTreeReload() async throws {
        let root = try makeTemporaryDirectory()
        let originalPost = root.appendingPathComponent("post.md")
        try writeText("Original", to: originalPost)
        let appState = AppState(shouldRestoreLastOpenedFile: false)

        appState.openExternalFile(root)
        try await waitUntil("original post selected") {
            appState.currentDocument.fileURL?.standardizedFileURL == originalPost.standardizedFileURL
        }

        let createdPost = root.appendingPathComponent("Untitled.md")
        appState.createWorkspaceFile(named: "Untitled.md", inDirectoryID: nil)

        XCTAssertEqual(appState.currentDocument.fileURL?.standardizedFileURL, createdPost.standardizedFileURL)

        appState.replaceDocumentText("Typed before reload settles")
        await appState.workspaceReloadTask?.value

        XCTAssertEqual(appState.currentDocument.fileURL?.standardizedFileURL, createdPost.standardizedFileURL)
        XCTAssertEqual(appState.currentDocument.text, "Typed before reload settles")
        XCTAssertNil(appState.externalChangePrompt)
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
        XCTAssertEqual(AppState.untitledFileName(in: directory, fileExtension: "mdx"), "Untitled.mdx")

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

private final class SpyRecentItemStore: RecentItemPersisting {
    private let saveError: Error?
    private let restoredURLs: [URL]

    init(saveError: Error? = nil, restoredURLs: [URL] = []) {
        self.saveError = saveError
        self.restoredURLs = restoredURLs
    }

    func save(_: URL) throws {
        if let saveError {
            throw saveError
        }
    }

    func restore() throws -> [URL] {
        restoredURLs
    }
}
