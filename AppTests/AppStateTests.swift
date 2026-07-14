// The generated project fixes App test source membership; keep the WS3B matrix in this
// existing source without regenerating the out-of-scope project file.
// swiftlint:disable file_length type_body_length
import AppKit
@testable import EditorKit
import MarkdownCore
@testable import Plainsong
import SwiftUI
import WorkspaceKit
import XCTest

@MainActor
final class AppStateTests: XCTestCase {
    func testEditorPresentationPolicyEnablesLinkFoldingOnlyForWYSIWYG() {
        XCTAssertEqual(
            EditorPresentationPolicy.resolve(usesWYSIWYGPresentation: false),
            .source
        )
        XCTAssertEqual(
            EditorPresentationPolicy.resolve(usesWYSIWYGPresentation: true),
            .inlineFoldRevealWithLinkFolding
        )
    }

    func testWorkspaceThumbnailAdapterMapsProviderOutcomesAndRequestExactly() async {
        let modificationDate = Date(timeIntervalSinceReferenceDate: 42)
        let workspaceThumbnail = WorkspaceImageThumbnail(
            pngData: Data([1, 2, 3]),
            pixelWidth: 320,
            pixelHeight: 180,
            resolvedWorkspaceRelativePath: "posts/assets/fixture.png",
            contentModificationDate: modificationDate,
            sourceByteCount: 123,
            decodedByteCost: 456
        )
        let provider = StubWorkspaceImageThumbnailProvider(outcomes: [
            "ready.png": .ready(workspaceThumbnail),
            "remote.png": .stayRaw(.remoteHTTPSource(scheme: "https")),
            "missing.png": .failed(.missingFile),
            "unreadable.png": .failed(.unreadableFile),
            "decode.png": .failed(.decodeFailed),
            "empty.png": .failed(.emptyImage),
        ])
        let adapter = WorkspaceEditorImageThumbnailAdapter(provider: provider)
        let rootURL = URL(fileURLWithPath: "/tmp/PlainsongAdapterTests", isDirectory: true)

        let ready = await adapter.loadThumbnail(
            rootURL: rootURL,
            documentDirectoryRelativePath: "posts",
            source: "ready.png",
            maxPixelSize: 600
        )
        XCTAssertEqual(ready, .ready(EditorImageThumbnail(
            pngData: workspaceThumbnail.pngData,
            pixelWidth: workspaceThumbnail.pixelWidth,
            pixelHeight: workspaceThumbnail.pixelHeight,
            resolvedWorkspaceRelativePath: workspaceThumbnail.resolvedWorkspaceRelativePath,
            contentModificationDate: modificationDate
        )))
        let stayedRaw = await adapter.loadThumbnail(
            rootURL: rootURL,
            documentDirectoryRelativePath: "posts",
            source: "remote.png",
            maxPixelSize: 600
        )
        XCTAssertEqual(
            stayedRaw,
            .stayRaw(.remoteHTTPSource(scheme: "https"))
        )

        let failures: [(String, EditorImageThumbnailFailure)] = [
            ("missing.png", .missingFile),
            ("unreadable.png", .unreadableFile),
            ("decode.png", .decodeFailed),
            ("empty.png", .emptyImage),
        ]
        for (source, expectedFailure) in failures {
            let outcome = await adapter.loadThumbnail(
                rootURL: rootURL,
                documentDirectoryRelativePath: "posts",
                source: source,
                maxPixelSize: 600
            )
            XCTAssertEqual(outcome, .failed(expectedFailure))
        }

        let firstRequest = await provider.recordedRequests().first
        XCTAssertEqual(firstRequest?.rootURL, rootURL)
        XCTAssertEqual(firstRequest?.documentDirectoryRelativePath, "posts")
        XCTAssertEqual(firstRequest?.source, "ready.png")
        XCTAssertEqual(firstRequest?.maxPixelSize, 600)
    }

    func testImageThumbnailConfigurationRequiresGatedFolderWYSIWYG() throws {
        let suiteName = "PlainsongImageThumbnailConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let rootURL = try makeTemporaryDirectory()
        let postsURL = rootURL.appendingPathComponent("posts", isDirectory: true)
        try FileManager.default.createDirectory(at: postsURL, withIntermediateDirectories: true)
        let documentURL = postsURL.appendingPathComponent("post.md")
        let session = DocumentSession(text: "![alt](fixture.png)", url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session, userDefaults: defaults)
        appState.workspaceRootURL = rootURL
        let wysiwygPresentation = MarkdownEditorDevelopmentPresentation.inlineFoldRevealWithLinkFolding

        appState.setLayoutMode(.wysiwyg)
        XCTAssertNil(appState.editorImageThumbnailConfiguration(
            for: session,
            presentation: wysiwygPresentation
        ))

        appState.preferences.setExperimentalWYSIWYGEnabled(true)
        appState.setLayoutMode(.sourceOnly)
        XCTAssertNil(appState.editorImageThumbnailConfiguration(
            for: session,
            presentation: wysiwygPresentation
        ))

        appState.setLayoutMode(.wysiwyg)
        XCTAssertNil(appState.editorImageThumbnailConfiguration(for: session, presentation: .source))
        let configuration = try XCTUnwrap(appState.editorImageThumbnailConfiguration(
            for: session,
            presentation: wysiwygPresentation
        ))
        XCTAssertEqual(configuration.rootURL, rootURL)
        XCTAssertEqual(configuration.documentDirectoryRelativePath, "posts")
        XCTAssertTrue(configuration.loader === appState.editorImageThumbnailAdapter)
        XCTAssertTrue(configuration.refreshProxy === appState.editorImageThumbnailRefreshProxy)

        appState.handleWYSIWYGMechanismFailure("test failure")
        XCTAssertNil(appState.editorImageThumbnailConfiguration(
            for: session,
            presentation: wysiwygPresentation
        ))
    }

    func testSingleFileModeProvablyKeepsImageThumbnailsRawAtAppBoundary() async throws {
        let suiteName = "PlainsongSingleFileImageThumbnailTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let provider = StubWorkspaceImageThumbnailProvider(outcomes: [:])
        let session = DocumentSession(
            text: "![alt](sibling.png)",
            url: URL(fileURLWithPath: "/tmp/SingleFile/post.md"),
            fileKind: .markdown
        )
        let appState = AppState(
            currentDocument: session,
            workspaceImageThumbnailProvider: provider,
            userDefaults: defaults
        )
        appState.preferences.setExperimentalWYSIWYGEnabled(true)
        appState.setLayoutMode(.wysiwyg)

        XCTAssertTrue(appState.shouldUseWYSIWYGPresentation)
        XCTAssertNil(appState.editorImageThumbnailConfiguration(
            for: session,
            presentation: .inlineFoldRevealWithLinkFolding
        ))
        let requests = await provider.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testWorkspaceReloadInvalidatesOnlyChangedAllowlistedRasterPaths() async throws {
        let rootURL = try makeTemporaryDirectory()
        let firstDate = Date(timeIntervalSinceReferenceDate: 1)
        let secondDate = Date(timeIntervalSinceReferenceDate: 2)
        let previous = WorkspaceFileSnapshot(entries: [
            .init(
                relativePath: "assets/unchanged.png",
                kind: .image,
                identity: "unchanged",
                contentModificationDate: firstDate
            ),
            .init(
                relativePath: "assets/changed.png",
                kind: .image,
                identity: "changed",
                contentModificationDate: firstDate
            ),
            .init(
                relativePath: "assets/removed.jpg",
                kind: .image,
                identity: "removed",
                contentModificationDate: firstDate
            ),
            .init(
                relativePath: "assets/vector.svg",
                kind: .image,
                identity: "vector",
                contentModificationDate: firstDate
            ),
        ])
        let current = WorkspaceFileSnapshot(entries: [
            .init(
                relativePath: "assets/unchanged.png",
                kind: .image,
                identity: "unchanged",
                contentModificationDate: firstDate
            ),
            .init(
                relativePath: "assets/changed.png",
                kind: .image,
                identity: "changed",
                contentModificationDate: secondDate
            ),
            .init(
                relativePath: "assets/added.webp",
                kind: .image,
                identity: "added",
                contentModificationDate: secondDate
            ),
            .init(
                relativePath: "assets/vector.svg",
                kind: .image,
                identity: "vector",
                contentModificationDate: secondDate
            ),
        ])
        let appState = AppState(directoryScanner: ImmediateWorkspaceDirectoryScanner(snapshot: current))
        appState.workspaceRootURL = rootURL
        appState.workspaceSnapshot = previous
        var invalidatedPaths: Set<String> = []
        let attachmentID = UUID()
        appState.editorImageThumbnailRefreshProxy.attach(id: attachmentID) { paths in
            invalidatedPaths.formUnion(paths)
        }
        defer { appState.editorImageThumbnailRefreshProxy.detach(id: attachmentID) }

        try await appState.reloadWorkspaceTree(root: rootURL, selectFirstIfNeeded: false)

        XCTAssertEqual(invalidatedPaths, [
            "assets/added.webp",
            "assets/changed.png",
            "assets/removed.jpg",
        ])
    }

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

    func testCompletionWorkspaceCannotReadReplacementRootForSessionBoundToPreviousAuthority() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let movedA = parent.appendingPathComponent("captured-A", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let post = root.appendingPathComponent("post.md").standardizedFileURL
        try writeText("# A", to: post)
        let authorityA = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let locationA = try authorityA.location(relativePath: "post.md")
        let loadedA = try MarkdownFileStore().loadResult(at: locationA)
        let session = DocumentSession(text: "# A", url: post, fileKind: .markdown)

        try FileManager.default.moveItem(at: root, to: movedA)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeText("# B", to: post)
        try writeText("---\nb_key: yes\n---\n", to: root.appendingPathComponent("sibling.md"))
        let authorityB = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        appState.workspaceSnapshot = snapshot(["post.md", "sibling.md"])
        appState.workspaceSearchRootAuthority = authorityB
        appState.workspaceGeneration = 2
        appState.workspaceInstalledCaptureGeneration = 2
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] =
            AnchoredWorkspaceSessionFileBinding(
                location: locationA,
                identity: loadedA.metadata.identity,
                sha256Digest: loadedA.sha256Digest
            )

        appState.scheduleCompletionWorkspaceRefresh()
        await appState.completionWorkspaceTask?.value

        XCTAssertFalse(appState.completionWorkspace.frontmatterKeys.contains("b_key"))
        XCTAssertTrue(appState.completionWorkspace.markdownFilePaths.isEmpty)
    }

    func testCompletionWorkspaceCannotReadReplacementRootForQuarantinedSession() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let movedA = parent.appendingPathComponent("captured-A", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let post = root.appendingPathComponent("post.md").standardizedFileURL
        try writeText("# A", to: post)
        let authorityA = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let locationA = try authorityA.location(relativePath: "post.md")
        let session = DocumentSession(
            text: "# dirty A",
            url: post,
            fileKind: .markdown,
            isDirty: true
        )

        try FileManager.default.moveItem(at: root, to: movedA)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeText("# B", to: post)
        try writeText("---\nb_key: yes\n---\n", to: root.appendingPathComponent("sibling.md"))
        let authorityB = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        appState.workspaceSnapshot = snapshot(["post.md", "sibling.md"])
        appState.workspaceSearchRootAuthority = authorityB
        appState.workspaceGeneration = 2
        appState.workspaceInstalledCaptureGeneration = 2
        appState.indeterminateSessionWrites[ObjectIdentifier(session)] =
            WorkspaceIndeterminateFileWrite(
                reason: .durabilityFailed,
                preparedMetadata: nil,
                recoveryArtifact: .none
            )
        appState.indeterminateSessionWriteContexts[ObjectIdentifier(session)] =
            IndeterminateSessionWriteContext(
                location: locationA,
                preparedSHA256Digest: WorkspaceSearchContentFingerprint(
                    text: session.text
                ).sha256Digest
            )

        appState.scheduleCompletionWorkspaceRefresh()
        await appState.completionWorkspaceTask?.value

        XCTAssertFalse(appState.completionWorkspace.frontmatterKeys.contains("b_key"))
        XCTAssertTrue(appState.completionWorkspace.markdownFilePaths.isEmpty)
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

    func testWorkspaceRefreshUsesLoadedActivationFileAndDoesNotAutosaveOverReplacement() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let post = root.appendingPathComponent("post.md")
        try writeText("captured A", to: post)
        let scanner = ControlledWorkspaceDirectoryScanner()
        let suiteName = "WorkspaceRefreshLeafReplacement.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(0.25, forKey: "Plainsong.settings.autosaveIntervalSeconds")
        let appState = AppState(
            directoryScanner: scanner,
            shouldRestoreLastOpenedFile: false,
            userDefaults: defaults
        )
        appState.workspaceRootURL = root

        let initialReload = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: true)
        }
        await scanner.waitForRequestCount(1)
        await scanner.completeRequest(at: 0, with: snapshot("post.md"))
        try await initialReload.value
        appState.replaceDocumentText("unsaved edits")
        appState.workspaceReloadPostLoadHook = {
            appState.workspaceReloadPostLoadHook = nil
            try self.writeText("replacement B", to: post, touchOffset: 5)
        }

        let refresh = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: false)
        }
        await scanner.waitForRequestCount(2)
        await scanner.completeRequest(at: 1, with: snapshot("post.md"))
        try await refresh.value

        XCTAssertEqual(appState.currentDocument.text, "unsaved edits")
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertNil(appState.pendingExternalTexts[post.standardizedFileURL])
        appState.flushAutosaveIfNeeded()
        XCTAssertEqual(try String(contentsOf: post, encoding: .utf8), "replacement B")
        XCTAssertTrue(appState.currentDocument.isDirty)
    }

    // swiftlint:disable:next function_body_length
    func testWorkspaceRefreshRejectsRootReplacementAfterActivationLoadWithoutReadingOrWritingB() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let moved = parent.appendingPathComponent("captured-A", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let post = root.appendingPathComponent("post.md")
        try writeText("captured A", to: post)
        try writeText("---\na_key: yes\n---\n", to: root.appendingPathComponent("sibling.md"))
        let scanner = ControlledWorkspaceDirectoryScanner()
        let suiteName = "WorkspaceRefreshRootReplacement.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(0.25, forKey: "Plainsong.settings.autosaveIntervalSeconds")
        let appState = AppState(
            directoryScanner: scanner,
            shouldRestoreLastOpenedFile: false,
            userDefaults: defaults
        )
        appState.workspaceRootURL = root
        let capturedSnapshot = snapshot(["post.md", "sibling.md"])

        let initialReload = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: true)
        }
        await scanner.waitForRequestCount(1)
        await scanner.completeRequest(at: 0, with: capturedSnapshot)
        try await initialReload.value
        await appState.completionWorkspaceTask?.value
        XCTAssertTrue(appState.completionWorkspace.frontmatterKeys.contains("a_key"))
        appState.replaceDocumentText("unsaved A edits")
        let installedSnapshot = appState.workspaceSnapshot
        let installedAuthority = appState.workspaceSearchRootAuthority
        let installedGeneration = appState.workspaceInstalledCaptureGeneration
        appState.workspaceReloadPostLoadHook = {
            appState.workspaceReloadPostLoadHook = nil
            try FileManager.default.moveItem(at: root, to: moved)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try self.writeText("replacement B", to: root.appendingPathComponent("post.md"))
            try self.writeText(
                "---\nb_key: yes\n---\n",
                to: root.appendingPathComponent("sibling.md")
            )
        }

        let refresh = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: false)
        }
        await scanner.waitForRequestCount(2)
        await scanner.completeRequest(at: 1, with: capturedSnapshot)
        do {
            try await refresh.value
            XCTFail("Expected post-load root replacement rejection")
        } catch is CancellationError {
            // Capture A cannot be installed under a selected spelling that now names B.
        }

        XCTAssertEqual(appState.workspaceSnapshot, installedSnapshot)
        XCTAssertEqual(appState.workspaceSearchRootAuthority, installedAuthority)
        XCTAssertEqual(appState.workspaceInstalledCaptureGeneration, installedGeneration)
        XCTAssertFalse(appState.completionWorkspace.frontmatterKeys.contains("b_key"))
        appState.flushAutosaveIfNeeded()
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("post.md"), encoding: .utf8),
            "replacement B"
        )
        XCTAssertTrue(appState.currentDocument.isDirty)
    }

    // swiftlint:disable:next function_body_length
    func testWorkspaceReloadRejectsCurrentSessionAcrossReplacementRootAuthority() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let moved = parent.appendingPathComponent("captured-A", isDirectory: true)
        let post = root.appendingPathComponent("post.md").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeText("disk A", to: post)

        let scanner = ControlledWorkspaceDirectoryScanner()
        let appState = AppState(
            directoryScanner: scanner,
            shouldRestoreLastOpenedFile: false
        )
        appState.workspaceRootURL = root

        let initialReload = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: true)
        }
        await scanner.waitForRequestCount(1)
        await scanner.completeRequest(at: 0, with: snapshot("post.md"))
        try await initialReload.value

        let sessionA = appState.currentDocument
        let bindingA = try XCTUnwrap(appState.anchoredSessionFileBinding(for: sessionA))
        appState.replaceDocumentText("dirty A")
        appState.autosaveTask?.cancel()

        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeText("disk B", to: post)

        let reloadB = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: false)
        }
        await scanner.waitForRequestCount(2)
        await scanner.completeRequest(at: 1, with: snapshot("post.md"))
        do {
            try await reloadB.value
            XCTFail("Expected cached A activation to reject authority B")
        } catch AppStateError.invalidSessionIdentity {
            // A URL match cannot authorize reusing a session retained under another root.
        } catch {
            XCTFail("Expected invalidSessionIdentity, got \(error)")
        }

        XCTAssertTrue(appState.currentDocument === sessionA)
        XCTAssertEqual(appState.currentDocument.text, "dirty A")
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: sessionA), bindingA)
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertEqual(try String(contentsOf: post, encoding: .utf8), "disk B")
        appState.flushAutosaveIfNeeded()
        XCTAssertEqual(try String(contentsOf: post, encoding: .utf8), "disk B")
    }

    // swiftlint:disable:next function_body_length
    func testWorkspaceReloadCannotRebindCachedSessionAcrossReplacementRootAuthority() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let moved = parent.appendingPathComponent("captured-A", isDirectory: true)
        let post = root.appendingPathComponent("post.md").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeText("disk A", to: post)

        let scanner = ControlledWorkspaceDirectoryScanner()
        let appState = AppState(
            directoryScanner: scanner,
            shouldRestoreLastOpenedFile: false
        )
        appState.workspaceRootURL = root
        let initialReload = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: true)
        }
        await scanner.waitForRequestCount(1)
        await scanner.completeRequest(at: 0, with: snapshot("post.md"))
        try await initialReload.value

        let sessionA = appState.currentDocument
        let bindingA = try XCTUnwrap(appState.anchoredSessionFileBinding(for: sessionA))
        let unrelatedSession = DocumentSession(
            text: "unrelated",
            url: parent.appendingPathComponent("outside.md"),
            fileKind: .markdown
        )
        appState.setCurrentDocument(unrelatedSession, synchronizingWorkspaceTree: false)
        appState.completionWorkspaceTask?.cancel()
        XCTAssertTrue(appState.sessionCache[post] === sessionA)

        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeText("disk B", to: post)

        let reloadB = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: false)
        }
        await scanner.waitForRequestCount(2)
        await scanner.completeRequest(at: 1, with: snapshot("post.md"))
        do {
            try await reloadB.value
            XCTFail("Expected cached A activation to reject authority B")
        } catch AppStateError.invalidSessionIdentity {
            // Current disposition is unrelated; the cached-source validator is the rejection.
        } catch {
            XCTFail("Expected invalidSessionIdentity, got \(error)")
        }

        XCTAssertTrue(appState.currentDocument === unrelatedSession)
        XCTAssertTrue(appState.sessionCache[post] === sessionA)
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: sessionA), bindingA)
        XCTAssertEqual(try String(contentsOf: post, encoding: .utf8), "disk B")
    }

    // swiftlint:disable:next function_body_length
    func testWorkspaceReloadCannotRebindRetiredSessionAcrossReplacementRootAuthority() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let moved = parent.appendingPathComponent("captured-A", isDirectory: true)
        let post = root.appendingPathComponent("post.md").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeText("disk A", to: post)

        let scanner = ControlledWorkspaceDirectoryScanner()
        let appState = AppState(
            directoryScanner: scanner,
            shouldRestoreLastOpenedFile: false
        )
        appState.workspaceRootURL = root
        let initialReload = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: true)
        }
        await scanner.waitForRequestCount(1)
        await scanner.completeRequest(at: 0, with: snapshot("post.md"))
        try await initialReload.value

        let sessionA = appState.currentDocument
        let bindingA = try XCTUnwrap(appState.anchoredSessionFileBinding(for: sessionA))
        let retiredBindingID = EditorDocumentBindingID()
        appState.sessionCache[post] = nil
        appState.retiredEditorDocumentBindings[retiredBindingID] = RetiredEditorDocumentBinding(
            id: retiredBindingID,
            session: sessionA,
            securityScopedAuthority: nil,
            isAwaitingBindingEnd: false
        )
        let unrelatedSession = DocumentSession(
            text: "unrelated",
            url: parent.appendingPathComponent("outside.md"),
            fileKind: .markdown
        )
        appState.setCurrentDocument(unrelatedSession, synchronizingWorkspaceTree: false)
        appState.completionWorkspaceTask?.cancel()

        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeText("disk B", to: post)

        let reloadB = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: false)
        }
        await scanner.waitForRequestCount(2)
        await scanner.completeRequest(at: 1, with: snapshot("post.md"))
        do {
            try await reloadB.value
            XCTFail("Expected retired A activation to reject authority B")
        } catch AppStateError.invalidSessionIdentity {
            // Current disposition is unrelated; the retired-source validator is the rejection.
        } catch {
            XCTFail("Expected invalidSessionIdentity, got \(error)")
        }

        XCTAssertTrue(appState.currentDocument === unrelatedSession)
        XCTAssertTrue(appState.retiredEditorDocumentBindings[retiredBindingID]?.session === sessionA)
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: sessionA), bindingA)
        XCTAssertEqual(try String(contentsOf: post, encoding: .utf8), "disk B")
    }

    func testWorkspaceRefreshRevalidatesCachedActivationAfterFinalSuspension() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let post = root.appendingPathComponent("post.md").standardizedFileURL
        try writeText("captured A", to: post)
        let scanner = ControlledWorkspaceDirectoryScanner()
        let appState = AppState(
            directoryScanner: scanner,
            shouldRestoreLastOpenedFile: false
        )
        appState.workspaceRootURL = root

        let initialReload = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: true)
        }
        await scanner.waitForRequestCount(1)
        await scanner.completeRequest(at: 0, with: snapshot("post.md"))
        try await initialReload.value
        let evictedSession = appState.currentDocument

        appState.workspaceReloadPostPrepareHook = {
            appState.workspaceReloadPostPrepareHook = nil
            appState.sessionCache[post] = nil
        }
        let refresh = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: false)
        }
        await scanner.waitForRequestCount(2)
        await scanner.completeRequest(at: 1, with: snapshot("post.md"))
        try await refresh.value

        XCTAssertFalse(appState.currentDocument === evictedSession)
        XCTAssertTrue(appState.sessionCache[post] === appState.currentDocument)
        XCTAssertEqual(appState.currentDocument.text, "captured A")
        XCTAssertNotNil(appState.anchoredSessionFileBinding(for: appState.currentDocument))
    }

    func testWorkspaceRefreshDoesNotOverrideDocumentChangedDuringFinalSuspension() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstPost = root.appendingPathComponent("a.md").standardizedFileURL
        let secondPost = root.appendingPathComponent("b.md").standardizedFileURL
        try writeText("captured A", to: firstPost)
        try writeText("captured B", to: secondPost)
        let scanner = ControlledWorkspaceDirectoryScanner()
        let appState = AppState(
            directoryScanner: scanner,
            shouldRestoreLastOpenedFile: false
        )
        appState.workspaceRootURL = root
        let capturedSnapshot = snapshot(["a.md", "b.md"])

        let initialReload = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: true)
        }
        await scanner.waitForRequestCount(1)
        await scanner.completeRequest(at: 0, with: capturedSnapshot)
        try await initialReload.value
        XCTAssertEqual(appState.currentDocument.fileURL?.standardizedFileURL, firstPost)
        appState.openWorkspaceFile(secondPost)
        let secondSession = appState.currentDocument
        appState.openWorkspaceFile(firstPost)
        XCTAssertEqual(appState.currentDocument.fileURL?.standardizedFileURL, firstPost)

        appState.workspaceReloadPostPrepareHook = {
            appState.workspaceReloadPostPrepareHook = nil
            appState.setCurrentDocument(secondSession)
        }
        let refresh = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: false)
        }
        await scanner.waitForRequestCount(2)
        await scanner.completeRequest(at: 1, with: capturedSnapshot)
        do {
            try await refresh.value
            XCTFail("Expected document-change cancellation")
        } catch is CancellationError {
            // A reload suspended on final proof cannot steal a newer document selection.
        }

        XCTAssertEqual(appState.currentDocument.fileURL?.standardizedFileURL, secondPost)
        XCTAssertEqual(appState.currentDocument.text, "captured B")
        XCTAssertTrue(appState.sessionCache[secondPost] === appState.currentDocument)
    }

    func testWorkspaceRefreshCancelsSameSessionSaveDuringFinalSuspension() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let post = root.appendingPathComponent("post.md").standardizedFileURL
        try writeText("disk A", to: post)
        let scanner = ControlledWorkspaceDirectoryScanner()
        let appState = AppState(
            directoryScanner: scanner,
            shouldRestoreLastOpenedFile: false
        )
        appState.workspaceRootURL = root

        let initialReload = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: true)
        }
        await scanner.waitForRequestCount(1)
        await scanner.completeRequest(at: 0, with: snapshot("post.md"))
        try await initialReload.value
        appState.replaceDocumentText("saved B")

        appState.workspaceReloadPostPrepareHook = {
            appState.workspaceReloadPostPrepareHook = nil
            try appState.saveCurrentDocument()
        }
        let refresh = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: false)
        }
        await scanner.waitForRequestCount(2)
        await scanner.completeRequest(at: 1, with: snapshot("post.md"))
        do {
            try await refresh.value
            XCTFail("Expected same-session state-change cancellation")
        } catch is CancellationError {
            // A save that wins the suspension cannot be replaced by the stale activation load.
        }

        XCTAssertEqual(appState.currentDocument.text, "saved B")
        XCTAssertFalse(appState.currentDocument.isDirty)
        XCTAssertEqual(try String(contentsOf: post, encoding: .utf8), "saved B")
        let binding = try XCTUnwrap(appState.anchoredSessionFileBinding(for: appState.currentDocument))
        let disk = try MarkdownFileStore().loadResult(at: binding.location)
        XCTAssertEqual(binding.identity, disk.metadata.identity)
        XCTAssertEqual(binding.sha256Digest, disk.sha256Digest)
    }

    func testWorkspaceRefreshDetachesMissingCurrentFileAndSuppressesAutosave() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let post = root.appendingPathComponent("post.md")
        try writeText("captured A", to: post)
        let scanner = ControlledWorkspaceDirectoryScanner()
        let suiteName = "WorkspaceRefreshMissingCurrent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(0.25, forKey: "Plainsong.settings.autosaveIntervalSeconds")
        let appState = AppState(
            directoryScanner: scanner,
            shouldRestoreLastOpenedFile: false,
            userDefaults: defaults
        )
        appState.workspaceRootURL = root
        let initialReload = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: true)
        }
        await scanner.waitForRequestCount(1)
        await scanner.completeRequest(at: 0, with: snapshot("post.md"))
        try await initialReload.value
        appState.replaceDocumentText("unsaved A edits")
        try FileManager.default.removeItem(at: post)

        let refresh = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: false)
        }
        await scanner.waitForRequestCount(2)
        await scanner.completeRequest(at: 1, with: WorkspaceFileSnapshot(entries: []))
        try await refresh.value

        XCTAssertEqual(appState.missingFilePrompt?.fileURL.standardizedFileURL, post.standardizedFileURL)
        XCTAssertFalse(appState.canSave)
        XCTAssertNil(appState.autosaveTask)
        appState.flushAutosaveIfNeeded()
        XCTAssertFalse(FileManager.default.fileExists(atPath: post.path))
    }

    func testAnchoredWorkspaceSaveUsesExactLoadedByteDigestForUTF8BOMFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let post = root.appendingPathComponent("post.md")
        var originalBytes = Data([0xEF, 0xBB, 0xBF])
        originalBytes.append(Data("original".utf8))
        try originalBytes.write(to: post)
        let scanner = ControlledWorkspaceDirectoryScanner()
        let appState = AppState(
            directoryScanner: scanner,
            shouldRestoreLastOpenedFile: false
        )
        appState.workspaceRootURL = root
        let reload = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: true)
        }
        await scanner.waitForRequestCount(1)
        await scanner.completeRequest(at: 0, with: snapshot("post.md"))
        try await reload.value

        appState.replaceDocumentText("edited")
        try appState.saveCurrentDocument()

        XCTAssertEqual(try Data(contentsOf: post), Data("edited".utf8))
        XCTAssertFalse(appState.currentDocument.isDirty)
    }

    func testClosingWorkspaceRetainsCurrentDocumentAnchoredSaveAuthority() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let moved = parent.appendingPathComponent("captured-A", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let post = root.appendingPathComponent("post.md")
        try writeText("captured A", to: post)
        let scanner = ControlledWorkspaceDirectoryScanner()
        let appState = AppState(
            directoryScanner: scanner,
            shouldRestoreLastOpenedFile: false
        )
        appState.workspaceRootURL = root
        let reload = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: true)
        }
        await scanner.waitForRequestCount(1)
        await scanner.completeRequest(at: 0, with: snapshot("post.md"))
        try await reload.value

        appState.closeWorkspace()
        XCTAssertNil(appState.workspaceRootURL)
        XCTAssertNotNil(appState.anchoredSessionFileBinding(for: appState.currentDocument))
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeText("replacement B", to: root.appendingPathComponent("post.md"))

        appState.replaceDocumentText("edited A")
        appState.flushAutosaveIfNeeded()

        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("post.md"), encoding: .utf8),
            "replacement B"
        )
        XCTAssertTrue(appState.currentDocument.isDirty)
    }

    func testCloseMissingFileClearsExactSessionWithoutFollowingReplacementSymlink() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingURL = root.appendingPathComponent("missing.md").standardizedFileURL
        let otherURL = root.appendingPathComponent("other.md").standardizedFileURL
        try writeText("missing A", to: missingURL)
        try writeText("other B", to: otherURL)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let missingLocation = try authority.location(relativePath: "missing.md")
        let missingRead = try MarkdownFileStore().loadResult(at: missingLocation)
        let missingSession = DocumentSession(
            text: "unsaved A",
            url: missingURL,
            fileKind: .markdown,
            isDirty: true
        )
        let otherSession = DocumentSession(
            text: "dirty B",
            url: otherURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(
            currentDocument: missingSession,
            shouldRestoreLastOpenedFile: false
        )
        appState.sessionCache[missingURL] = missingSession
        appState.sessionCache[otherURL] = otherSession
        appState.anchoredSessionFileBindings[ObjectIdentifier(missingSession)] =
            AnchoredWorkspaceSessionFileBinding(
                location: missingLocation,
                identity: missingRead.metadata.identity,
                sha256Digest: missingRead.sha256Digest
            )
        appState.detachedSessionURLs.insert(missingURL)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: missingURL)
        try FileManager.default.removeItem(at: missingURL)
        try FileManager.default.createSymbolicLink(at: missingURL, withDestinationURL: otherURL)

        appState.closeMissingFile()

        XCTAssertNil(appState.sessionCache[missingURL])
        XCTAssertNil(appState.anchoredSessionFileBindings[ObjectIdentifier(missingSession)])
        XCTAssertTrue(appState.sessionCache[otherURL] === otherSession)
        XCTAssertEqual(otherSession.text, "dirty B")
        XCTAssertNil(appState.currentDocument.fileURL)
    }

    func testCloseQuarantinedMissingFileDoesNotClearReplacementSymlinkTargetState() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingURL = root.appendingPathComponent("missing.md").standardizedFileURL
        let otherURL = root.appendingPathComponent("other.md").standardizedFileURL
        try writeText("other B", to: otherURL)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let missingLocation = try authority.location(relativePath: "missing.md")
        let missingSession = DocumentSession(
            text: "unsaved A",
            url: missingURL,
            fileKind: .markdown,
            isDirty: true
        )
        let otherSession = DocumentSession(
            text: "dirty B",
            url: otherURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(
            currentDocument: missingSession,
            shouldRestoreLastOpenedFile: false
        )
        appState.sessionCache[missingURL] = missingSession
        appState.sessionCache[otherURL] = otherSession
        appState.indeterminateSessionWrites[ObjectIdentifier(missingSession)] =
            WorkspaceIndeterminateFileWrite(
                reason: .durabilityFailed,
                preparedMetadata: nil,
                recoveryArtifact: .none
            )
        appState.indeterminateSessionWriteContexts[ObjectIdentifier(missingSession)] =
            IndeterminateSessionWriteContext(
                location: missingLocation,
                preparedSHA256Digest: WorkspaceSearchContentFingerprint(
                    text: missingSession.text
                ).sha256Digest
            )
        appState.detachedSessionURLs.insert(missingURL)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: missingURL)
        appState.pendingExternalTexts[otherURL] = "pending B"
        appState.lastKnownDiskHashes[otherURL] = 42
        appState.detachedSessionURLs.insert(otherURL)
        try FileManager.default.createSymbolicLink(at: missingURL, withDestinationURL: otherURL)

        appState.closeMissingFile()

        XCTAssertNil(appState.sessionCache[missingURL])
        XCTAssertTrue(appState.sessionCache[otherURL] === otherSession)
        XCTAssertEqual(appState.pendingExternalTexts[otherURL], "pending B")
        XCTAssertEqual(appState.lastKnownDiskHashes[otherURL], 42)
        XCTAssertTrue(appState.detachedSessionURLs.contains(otherURL))
    }

    func testSaveMissingCopyRefusesToOverwriteAnotherCachedWorkspaceSession() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingURL = root.appendingPathComponent("missing.md").standardizedFileURL
        let destinationURL = root.appendingPathComponent("destination.md").standardizedFileURL
        try writeText("missing A", to: missingURL)
        try writeText("destination disk", to: destinationURL)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let missingLocation = try authority.location(relativePath: "missing.md")
        let missingRead = try MarkdownFileStore().loadResult(at: missingLocation)
        let missingSession = DocumentSession(
            text: "unsaved A",
            url: missingURL,
            fileKind: .markdown,
            isDirty: true
        )
        let destinationSession = DocumentSession(
            text: "dirty destination",
            url: destinationURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(
            currentDocument: missingSession,
            shouldRestoreLastOpenedFile: false
        )
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.sessionCache[missingURL] = missingSession
        appState.sessionCache[destinationURL] = destinationSession
        appState.anchoredSessionFileBindings[ObjectIdentifier(missingSession)] =
            AnchoredWorkspaceSessionFileBinding(
                location: missingLocation,
                identity: missingRead.metadata.identity,
                sha256Digest: missingRead.sha256Digest
            )
        appState.detachedSessionURLs.insert(missingURL)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: missingURL)

        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: destinationURL))

        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "destination disk")
        XCTAssertTrue(appState.sessionCache[destinationURL] === destinationSession)
        XCTAssertTrue(appState.currentDocument === missingSession)
        XCTAssertNotNil(appState.anchoredSessionFileBinding(for: missingSession))
    }

    func testSaveMissingCopyRefusesCaseAliasOwnedByAnotherCachedWorkspaceSession() throws {
        let fixture = try makeSaveCopyCaseAliasFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(
            try fixture.appState.saveDetachedCurrentDocument(to: fixture.caseAliasURL)
        )

        XCTAssertEqual(try String(contentsOf: fixture.ownedURL, encoding: .utf8), "owned disk")
        XCTAssertTrue(fixture.appState.sessionCache[fixture.ownedURL] === fixture.ownedSession)
        XCTAssertEqual(fixture.ownedSession.text, "dirty owned session")
        XCTAssertTrue(fixture.appState.currentDocument === fixture.missingSession)
        XCTAssertNotNil(fixture.appState.anchoredSessionFileBinding(for: fixture.missingSession))
    }

    func testSaveMissingCopyRefusesExistingCaseAliasWithoutCachedOwner() throws {
        let fixture = try makeSaveCopyCaseAliasFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.appState.sessionCache[fixture.ownedURL] = nil
        fixture.appState.anchoredSessionFileBindings[ObjectIdentifier(fixture.ownedSession)] = nil

        XCTAssertThrowsError(
            try fixture.appState.saveDetachedCurrentDocument(to: fixture.caseAliasURL)
        )

        XCTAssertEqual(try String(contentsOf: fixture.ownedURL, encoding: .utf8), "owned disk")
        XCTAssertTrue(fixture.appState.currentDocument === fixture.missingSession)
        XCTAssertTrue(fixture.appState.currentDocument.isDirty)
    }

    // swiftlint:disable:next function_body_length
    func testSaveMissingCopyRefusesWriteOnlyCaseAliasOwnedByCachedSession() throws {
        for permissions in [0o200, 0o000] {
            let fixture = try makeSaveCopyCaseAliasFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: fixture.ownedURL.path
            )

            XCTAssertThrowsError(
                try fixture.appState.saveDetachedCurrentDocument(to: fixture.caseAliasURL)
            )

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fixture.ownedURL.path
            )
            XCTAssertEqual(
                try String(contentsOf: fixture.ownedURL, encoding: .utf8),
                "owned disk"
            )
            XCTAssertTrue(
                fixture.appState.sessionCache[fixture.ownedURL] === fixture.ownedSession
            )
            XCTAssertTrue(fixture.appState.currentDocument === fixture.missingSession)
        }
    }

    func testSaveMissingCopyRefusesCaseAliasOwnedByMissingCachedSession() throws {
        let fixture = try makeSaveCopyCaseAliasFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.ownedURL)
        let ownedIdentity = ObjectIdentifier(fixture.ownedSession)
        let ownedLocation = try XCTUnwrap(
            fixture.appState.anchoredSessionFileBindings[ownedIdentity]?.location
        )
        fixture.appState.anchoredSessionFileBindings[ownedIdentity] = nil
        fixture.appState.indeterminateSessionWrites[ownedIdentity] =
            WorkspaceIndeterminateFileWrite(
                reason: .durabilityFailed,
                preparedMetadata: nil,
                recoveryArtifact: .none
            )
        fixture.appState.indeterminateSessionWriteContexts[ownedIdentity] =
            IndeterminateSessionWriteContext(
                location: ownedLocation,
                preparedSHA256Digest: WorkspaceSearchContentFingerprint(
                    text: fixture.ownedSession.text
                ).sha256Digest
            )

        XCTAssertThrowsError(
            try fixture.appState.saveDetachedCurrentDocument(to: fixture.caseAliasURL)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.caseAliasURL.path))
        XCTAssertTrue(fixture.appState.sessionCache[fixture.ownedURL] === fixture.ownedSession)
        XCTAssertTrue(fixture.appState.currentDocument === fixture.missingSession)
        XCTAssertTrue(fixture.appState.currentDocument.isDirty)
    }

    func testSaveMissingCopyRefusesDestinationOwnedOnlyByRetiredEditorSession() throws {
        let fixture = try makeSaveCopyCaseAliasFixture(requiresCaseAlias: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.appState.sessionCache[fixture.ownedURL] = nil
        let retiredBindingID = EditorDocumentBindingID()
        fixture.appState.retiredEditorDocumentBindings[retiredBindingID] =
            RetiredEditorDocumentBinding(
                id: retiredBindingID,
                session: fixture.ownedSession,
                securityScopedAuthority: nil,
                isAwaitingBindingEnd: true
            )

        XCTAssertThrowsError(
            try fixture.appState.saveDetachedCurrentDocument(to: fixture.ownedURL)
        )

        XCTAssertEqual(try String(contentsOf: fixture.ownedURL, encoding: .utf8), "owned disk")
        XCTAssertTrue(
            fixture.appState.retiredEditorDocumentBindings[retiredBindingID]?.session
                === fixture.ownedSession
        )
        XCTAssertTrue(fixture.appState.currentDocument === fixture.missingSession)
    }

    // swiftlint:disable:next function_body_length
    func testSaveMissingCopyAllowsDistinctCaseOnCaseSensitiveVolume() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingURL = root.appendingPathComponent("missing.md").standardizedFileURL
        let ownedURL = root.appendingPathComponent("Owned.md").standardizedFileURL
        let destinationURL = root.appendingPathComponent("owned.md").standardizedFileURL
        try writeText("missing A", to: missingURL)
        try writeText("owned disk", to: ownedURL)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw XCTSkip("Case-insensitive volume cannot represent distinct case spellings")
        }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let missingLocation = try authority.location(relativePath: "missing.md")
        let ownedLocation = try authority.location(relativePath: "Owned.md")
        let missingRead = try MarkdownFileStore().loadResult(at: missingLocation)
        let ownedRead = try MarkdownFileStore().loadResult(at: ownedLocation)
        let missingSession = DocumentSession(
            text: "unsaved A",
            url: missingURL,
            fileKind: .markdown,
            isDirty: true
        )
        let ownedSession = DocumentSession(
            text: "dirty owned session",
            url: ownedURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(
            currentDocument: missingSession,
            shouldRestoreLastOpenedFile: false
        )
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.sessionCache[missingURL] = missingSession
        appState.sessionCache[ownedURL] = ownedSession
        appState.anchoredSessionFileBindings[ObjectIdentifier(missingSession)] =
            AnchoredWorkspaceSessionFileBinding(
                location: missingLocation,
                identity: missingRead.metadata.identity,
                sha256Digest: missingRead.sha256Digest
            )
        appState.anchoredSessionFileBindings[ObjectIdentifier(ownedSession)] =
            AnchoredWorkspaceSessionFileBinding(
                location: ownedLocation,
                identity: ownedRead.metadata.identity,
                sha256Digest: ownedRead.sha256Digest
            )
        appState.detachedSessionURLs.insert(missingURL)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: missingURL)

        try appState.saveDetachedCurrentDocument(to: destinationURL)

        XCTAssertEqual(try String(contentsOf: ownedURL, encoding: .utf8), "owned disk")
        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "unsaved A")
        XCTAssertTrue(appState.sessionCache[ownedURL] === ownedSession)
        XCTAssertTrue(appState.sessionCache[destinationURL] === missingSession)
        XCTAssertFalse(missingSession.isDirty)
    }

    func testSaveMissingCopyRefusesMissingLeafThroughCaseAliasParent() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let actualDirectory = root.appendingPathComponent("Folder", isDirectory: true)
        let aliasDirectory = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: aliasDirectory.path) else {
            throw XCTSkip("Case-sensitive volume has no case-alias directory")
        }
        let missingURL = root.appendingPathComponent("missing.md").standardizedFileURL
        let aliasDestination = aliasDirectory.appendingPathComponent("recovered.md")
            .standardizedFileURL
        try writeText("missing A", to: missingURL)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let missingLocation = try authority.canonicalizedLocation(forFileURL: missingURL)
        let missingRead = try MarkdownFileStore().loadResult(at: missingLocation)
        let session = DocumentSession(
            text: "unsaved A",
            url: missingURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.sessionCache[missingURL] = session
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] =
            AnchoredWorkspaceSessionFileBinding(
                location: missingLocation,
                identity: missingRead.metadata.identity,
                sha256Digest: missingRead.sha256Digest
            )
        appState.detachedSessionURLs.insert(missingURL)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: missingURL)

        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: aliasDestination))

        XCTAssertFalse(FileManager.default.fileExists(atPath: aliasDestination.path))
        XCTAssertTrue(appState.currentDocument === session)
        XCTAssertTrue(session.isDirty)
    }

    private struct SaveCopyCaseAliasFixture {
        let root: URL
        let ownedURL: URL
        let caseAliasURL: URL
        let appState: AppState
        let missingSession: DocumentSession
        let ownedSession: DocumentSession
    }

    private func makeSaveCopyCaseAliasFixture(
        requiresCaseAlias: Bool = true
    ) throws -> SaveCopyCaseAliasFixture {
        let root = try makeTemporaryDirectory()
        let missingURL = root.appendingPathComponent("missing.md").standardizedFileURL
        let ownedURL = root.appendingPathComponent("Owned.md").standardizedFileURL
        let caseAliasURL = root.appendingPathComponent("owned.md").standardizedFileURL
        try writeText("missing A", to: missingURL)
        try writeText("owned disk", to: ownedURL)
        guard !requiresCaseAlias || FileManager.default.fileExists(atPath: caseAliasURL.path) else {
            try? FileManager.default.removeItem(at: root)
            throw XCTSkip("Case-sensitive volume has no case-alias entry")
        }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let missingLocation = try authority.canonicalizedLocation(forFileURL: missingURL)
        let ownedLocation = try authority.canonicalizedLocation(forFileURL: ownedURL)
        let missingRead = try MarkdownFileStore().loadResult(at: missingLocation)
        let ownedRead = try MarkdownFileStore().loadResult(at: ownedLocation)
        let missingSession = DocumentSession(
            text: "unsaved A",
            url: missingURL,
            fileKind: .markdown,
            isDirty: true
        )
        let ownedSession = DocumentSession(
            text: "dirty owned session",
            url: ownedURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(
            currentDocument: missingSession,
            shouldRestoreLastOpenedFile: false
        )
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.sessionCache[missingURL] = missingSession
        appState.sessionCache[ownedURL] = ownedSession
        appState.anchoredSessionFileBindings[ObjectIdentifier(missingSession)] =
            AnchoredWorkspaceSessionFileBinding(
                location: missingLocation,
                identity: missingRead.metadata.identity,
                sha256Digest: missingRead.sha256Digest
            )
        appState.anchoredSessionFileBindings[ObjectIdentifier(ownedSession)] =
            AnchoredWorkspaceSessionFileBinding(
                location: ownedLocation,
                identity: ownedRead.metadata.identity,
                sha256Digest: ownedRead.sha256Digest
            )
        appState.detachedSessionURLs.insert(missingURL)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: missingURL)
        return SaveCopyCaseAliasFixture(
            root: root,
            ownedURL: ownedURL,
            caseAliasURL: caseAliasURL,
            appState: appState,
            missingSession: missingSession,
            ownedSession: ownedSession
        )
    }

    func testSaveMissingCopyInsideWorkspaceInstallsAnchoredDestinationBinding() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingURL = root.appendingPathComponent("missing.md").standardizedFileURL
        let destinationURL = root.appendingPathComponent("recovered.md").standardizedFileURL
        try writeText("missing A", to: missingURL)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let missingLocation = try authority.location(relativePath: "missing.md")
        let missingRead = try MarkdownFileStore().loadResult(at: missingLocation)
        let session = DocumentSession(
            text: "unsaved A",
            url: missingURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.sessionCache[missingURL] = session
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] =
            AnchoredWorkspaceSessionFileBinding(
                location: missingLocation,
                identity: missingRead.metadata.identity,
                sha256Digest: missingRead.sha256Digest
            )
        appState.detachedSessionURLs.insert(missingURL)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: missingURL)
        let editorBinding = appState.editorDocumentBinding(for: session)

        try appState.saveDetachedCurrentDocument(to: destinationURL)

        let binding = try XCTUnwrap(appState.anchoredSessionFileBinding(for: session))
        XCTAssertEqual(binding.location.rootAuthority, authority)
        XCTAssertEqual(binding.location.fileURL, destinationURL)
        XCTAssertTrue(appState.sessionCache[destinationURL] === session)
        XCTAssertNil(appState.sessionCache[missingURL])
        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "unsaved A")
        XCTAssertEqual(appState.editorDocumentBindingIDs[ObjectIdentifier(session)], editorBinding.id)
        XCTAssertTrue(appState.editorDocumentBindingSessions[editorBinding.id] === session)
    }

    // swiftlint:disable:next function_body_length
    func testIndeterminateSaveCopyRehomesReadableDestinationAndBlocksBlindRetry() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingURL = root.appendingPathComponent("missing.md").standardizedFileURL
        let destinationURL = root.appendingPathComponent("recovered.md").standardizedFileURL
        try writeText("missing A", to: missingURL)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let missingLocation = try authority.location(relativePath: "missing.md")
        let missingRead = try MarkdownFileStore().loadResult(at: missingLocation)
        let session = DocumentSession(
            text: "unsaved A",
            url: missingURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.sessionCache[missingURL] = session
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] =
            AnchoredWorkspaceSessionFileBinding(
                location: missingLocation,
                identity: missingRead.metadata.identity,
                sha256Digest: missingRead.sha256Digest
            )
        appState.detachedSessionURLs.insert(missingURL)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: missingURL)

        var saveAttempts = 0
        var indeterminate: WorkspaceIndeterminateFileWrite?
        appState.anchoredFileSaveOverride = { text, location, _ in
            saveAttempts += 1
            let actual = try MarkdownFileStore().save(
                text: text,
                at: location,
                expecting: .missing
            )
            guard case let .committedAndDurable(durable) = actual else {
                XCTFail("Expected deterministic destination commit")
                return actual
            }
            let result = WorkspaceIndeterminateFileWrite(
                reason: .durabilityFailed,
                preparedMetadata: durable.metadata,
                recoveryArtifact: .retained(location)
            )
            indeterminate = result
            return .committedButIndeterminate(result)
        }

        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: destinationURL))

        XCTAssertEqual(saveAttempts, 1)
        XCTAssertEqual(appState.currentDocument.fileURL?.standardizedFileURL, destinationURL)
        XCTAssertEqual(appState.currentDocument.text, "unsaved A")
        XCTAssertTrue(appState.currentDocument.isDirty)
        XCTAssertTrue(appState.sessionCache[destinationURL] === session)
        XCTAssertNil(appState.sessionCache[missingURL])
        XCTAssertEqual(appState.pendingExternalTexts[destinationURL], "unsaved A")
        XCTAssertEqual(appState.externalChangePrompt?.fileURL.standardizedFileURL, destinationURL)
        XCTAssertNil(appState.missingFilePrompt)
        XCTAssertEqual(appState.indeterminateSessionWrites[ObjectIdentifier(session)], indeterminate)
        XCTAssertFalse(appState.canSave)

        XCTAssertThrowsError(try appState.saveCurrentDocument())
        XCTAssertEqual(saveAttempts, 1, "a readable indeterminate destination must not be overwritten")

        appState.keepMineForExternallyChangedFile()
        appState.autosaveTask?.cancel()
        XCTAssertNil(appState.indeterminateSessionWrites[ObjectIdentifier(session)])
        XCTAssertTrue(appState.canSave)
    }

    // swiftlint:disable:next function_body_length
    func testIndeterminateSaveCopyRetriesStillMissingDestinationExclusively() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingURL = root.appendingPathComponent("missing.md").standardizedFileURL
        let destinationURL = root.appendingPathComponent("recovered.md").standardizedFileURL
        try writeText("missing A", to: missingURL)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let missingLocation = try authority.location(relativePath: "missing.md")
        let missingRead = try MarkdownFileStore().loadResult(at: missingLocation)
        let session = DocumentSession(
            text: "unsaved A",
            url: missingURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.sessionCache[missingURL] = session
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] =
            AnchoredWorkspaceSessionFileBinding(
                location: missingLocation,
                identity: missingRead.metadata.identity,
                sha256Digest: missingRead.sha256Digest
            )
        appState.detachedSessionURLs.insert(missingURL)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: missingURL)

        let firstResult = WorkspaceIndeterminateFileWrite(
            reason: .durabilityFailed,
            preparedMetadata: nil,
            recoveryArtifact: .none
        )
        var expectations: [WorkspaceNoFollowFileWriteExpectation] = []
        appState.anchoredFileSaveOverride = { text, location, expectation in
            expectations.append(expectation)
            if expectations.count == 1 {
                return .committedButIndeterminate(firstResult)
            }
            return try MarkdownFileStore().save(
                text: text,
                at: location,
                expecting: expectation
            )
        }

        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: destinationURL))
        XCTAssertEqual(appState.currentDocument.fileURL?.standardizedFileURL, destinationURL)
        XCTAssertEqual(appState.missingFilePrompt?.fileURL.standardizedFileURL, destinationURL)
        XCTAssertEqual(appState.indeterminateSessionWrites[ObjectIdentifier(session)], firstResult)

        try appState.saveDetachedCurrentDocument(to: destinationURL)

        XCTAssertEqual(expectations, [.existingOrMissing, .missing])
        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "unsaved A")
        XCTAssertNil(appState.indeterminateSessionWrites[ObjectIdentifier(session)])
        XCTAssertNil(appState.missingFilePrompt)
        XCTAssertFalse(appState.currentDocument.isDirty)
    }

    // swiftlint:disable:next function_body_length
    func testIndeterminateSaveCopyRetryCannotSwitchToReplacementRootAuthority() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let moved = parent.appendingPathComponent("captured-A", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let missingURL = root.appendingPathComponent("missing.md").standardizedFileURL
        let destinationURL = root.appendingPathComponent("recovered.md").standardizedFileURL
        try writeText("missing A", to: missingURL)
        let authorityA = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let missingLocation = try authorityA.location(relativePath: "missing.md")
        let missingRead = try MarkdownFileStore().loadResult(at: missingLocation)
        let session = DocumentSession(
            text: "unsaved A",
            url: missingURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authorityA
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.sessionCache[missingURL] = session
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] =
            AnchoredWorkspaceSessionFileBinding(
                location: missingLocation,
                identity: missingRead.metadata.identity,
                sha256Digest: missingRead.sha256Digest
            )
        appState.detachedSessionURLs.insert(missingURL)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: missingURL)

        let firstResult = WorkspaceIndeterminateFileWrite(
            reason: .durabilityFailed,
            preparedMetadata: nil,
            recoveryArtifact: .none
        )
        var saveAttempts = 0
        appState.anchoredFileSaveOverride = { text, location, expectation in
            saveAttempts += 1
            if saveAttempts == 1 {
                return .committedButIndeterminate(firstResult)
            }
            return try MarkdownFileStore().save(
                text: text,
                at: location,
                expecting: expectation
            )
        }

        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: destinationURL))
        let contextA = try XCTUnwrap(
            appState.indeterminateSessionWriteContexts[ObjectIdentifier(session)]
        )
        XCTAssertEqual(contextA.location.rootAuthority, authorityA)

        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeText("B guard", to: destinationURL)
        let authorityB = try WorkspaceFileSystemRootAuthority(rootURL: root)
        appState.workspaceSearchRootAuthority = authorityB

        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: destinationURL))

        XCTAssertEqual(saveAttempts, 1)
        XCTAssertEqual(
            appState.indeterminateSessionWriteContexts[ObjectIdentifier(session)],
            contextA
        )
        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "B guard")
        XCTAssertTrue(appState.currentDocument.isDirty)
    }

    func testQuarantinedSaveCopyCaseVariantCannotFallBackToBroadWrite() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let retainedURL = root.appendingPathComponent("Recovered.md").standardizedFileURL
        let caseVariantURL = root.appendingPathComponent("recovered.md").standardizedFileURL
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let retainedLocation = try authority.location(relativePath: "Recovered.md")
        let session = DocumentSession(
            text: "unsaved A",
            url: retainedURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.sessionCache[retainedURL] = session
        appState.detachedSessionURLs.insert(retainedURL)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: retainedURL)
        let indeterminate = WorkspaceIndeterminateFileWrite(
            reason: .durabilityFailed,
            preparedMetadata: nil,
            recoveryArtifact: .none
        )
        appState.indeterminateSessionWrites[ObjectIdentifier(session)] = indeterminate
        appState.indeterminateSessionWriteContexts[ObjectIdentifier(session)] =
            IndeterminateSessionWriteContext(
                location: retainedLocation,
                preparedSHA256Digest: WorkspaceSearchContentFingerprint(
                    text: session.text
                ).sha256Digest
            )
        var saveAttempts = 0
        appState.anchoredFileSaveOverride = { _, _, _ in
            saveAttempts += 1
            return .committedButIndeterminate(indeterminate)
        }

        XCTAssertThrowsError(
            try appState.saveDetachedCurrentDocument(to: caseVariantURL)
        ) { error in
            guard case MarkdownFileStoreError.writeRequiresReconciliation = error else {
                return XCTFail("Expected reconciliation requirement, got \(error)")
            }
        }

        XCTAssertEqual(saveAttempts, 0)
        XCTAssertEqual(
            appState.indeterminateSessionWrites[ObjectIdentifier(session)],
            indeterminate
        )
        XCTAssertTrue(appState.currentDocument === session)
        XCTAssertTrue(appState.currentDocument.isDirty)
    }

    func testQuarantinedSaveCopyOutsideSymlinkCannotReachRetainedDestination() throws {
        let root = try makeTemporaryDirectory()
        let outsideRoot = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideRoot)
        }
        let retainedURL = root.appendingPathComponent("recovered.md").standardizedFileURL
        let outsideAlias = outsideRoot.appendingPathComponent("alias.md").standardizedFileURL
        try writeText("uncertain committed bytes", to: retainedURL)
        try FileManager.default.createSymbolicLink(
            at: outsideAlias,
            withDestinationURL: retainedURL
        )
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let retainedLocation = try authority.location(relativePath: "recovered.md")
        let session = DocumentSession(
            text: "unsaved retry bytes",
            url: retainedURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.sessionCache[retainedURL] = session
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: retainedURL)
        let indeterminate = WorkspaceIndeterminateFileWrite(
            reason: .durabilityFailed,
            preparedMetadata: nil,
            recoveryArtifact: .retained(retainedLocation)
        )
        appState.indeterminateSessionWrites[ObjectIdentifier(session)] = indeterminate
        appState.indeterminateSessionWriteContexts[ObjectIdentifier(session)] =
            IndeterminateSessionWriteContext(
                location: retainedLocation,
                preparedSHA256Digest: WorkspaceSearchContentFingerprint(
                    text: session.text
                ).sha256Digest
            )

        XCTAssertThrowsError(
            try appState.saveDetachedCurrentDocument(to: outsideAlias)
        ) { error in
            guard case MarkdownFileStoreError.writeRequiresReconciliation = error else {
                return XCTFail("Expected reconciliation requirement, got \(error)")
            }
        }

        XCTAssertEqual(
            try String(contentsOf: retainedURL, encoding: .utf8),
            "uncertain committed bytes"
        )
        XCTAssertEqual(
            appState.indeterminateSessionWrites[ObjectIdentifier(session)],
            indeterminate
        )
        XCTAssertTrue(appState.currentDocument === session)
        XCTAssertTrue(appState.currentDocument.isDirty)
    }

    // swiftlint:disable:next function_body_length
    func testAnchoredSaveRetainsDurableCleanupNoticeAfterMarkingSessionClean() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let post = root.appendingPathComponent("post.md").standardizedFileURL
        let recovery = root.appendingPathComponent(".post.recovery").standardizedFileURL
        try writeText("disk A", to: post)
        try writeText("retained old plaintext", to: recovery)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: "post.md")
        let recoveryLocation = try authority.location(relativePath: ".post.recovery")
        let loaded = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(
            text: "edited A",
            url: post,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.sessionCache[post] = session
        let originalBinding = AnchoredWorkspaceSessionFileBinding(
            location: location,
            identity: loaded.metadata.identity,
            sha256Digest: loaded.sha256Digest
        )
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] = originalBinding
        var durableResult: WorkspaceDurableFileWrite?
        appState.anchoredFileSaveOverride = { text, destination, expectation in
            let outcome = try MarkdownFileStore().save(
                text: text,
                at: destination,
                expecting: expectation
            )
            guard case let .committedAndDurable(actual) = outcome else {
                XCTFail("Expected deterministic durable save")
                return outcome
            }
            let durable = WorkspaceDurableFileWrite(
                metadata: actual.metadata,
                cleanupState: .retained(recoveryLocation)
            )
            durableResult = durable
            return .committedAndDurable(durable)
        }

        try appState.save(session: session)

        let durable = try XCTUnwrap(durableResult)
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(try String(contentsOf: post, encoding: .utf8), "edited A")
        XCTAssertEqual(
            appState.anchoredSessionFileBinding(for: session)?.identity,
            durable.metadata.identity
        )
        XCTAssertNil(appState.indeterminateSessionWrites[ObjectIdentifier(session)])
        XCTAssertEqual(
            appState.fileWriteArtifactNotices,
            [
                FileWriteArtifactNotice(
                    destinationURL: post,
                    destinationWasCommitted: true,
                    artifactState: .retained(recoveryLocation)
                ),
            ]
        )
        XCTAssertEqual(appState.presentedError?.title, "File Saved; Cleanup Required")
    }

    // swiftlint:disable:next function_body_length
    func testAnchoredSaveCopyRetainsRemovalIndeterminateNoticeAfterRehome() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingURL = root.appendingPathComponent("missing.md").standardizedFileURL
        let destinationURL = root.appendingPathComponent("recovered.md").standardizedFileURL
        try writeText("disk A", to: missingURL)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let missingLocation = try authority.location(relativePath: "missing.md")
        let destinationLocation = try authority.location(relativePath: "recovered.md")
        let recoveryLocation = try authority.location(relativePath: ".recovered.cleanup")
        let loaded = try MarkdownFileStore().loadResult(at: missingLocation)
        let session = DocumentSession(
            text: "unsaved A",
            url: missingURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.sessionCache[missingURL] = session
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] =
            AnchoredWorkspaceSessionFileBinding(
                location: missingLocation,
                identity: loaded.metadata.identity,
                sha256Digest: loaded.sha256Digest
            )
        appState.detachedSessionURLs.insert(missingURL)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: missingURL)
        appState.anchoredFileSaveOverride = { text, destination, expectation in
            let outcome = try MarkdownFileStore().save(
                text: text,
                at: destination,
                expecting: expectation
            )
            guard case let .committedAndDurable(actual) = outcome else {
                XCTFail("Expected deterministic durable Save Copy")
                return outcome
            }
            return .committedAndDurable(
                WorkspaceDurableFileWrite(
                    metadata: actual.metadata,
                    cleanupState: .removalIndeterminate(recoveryLocation)
                )
            )
        }

        try appState.saveDetachedCurrentDocument(to: destinationURL)

        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.fileURL?.standardizedFileURL, destinationURL)
        XCTAssertTrue(appState.sessionCache[destinationURL] === session)
        XCTAssertNil(appState.sessionCache[missingURL])
        XCTAssertEqual(
            appState.anchoredSessionFileBinding(for: session)?.location,
            destinationLocation
        )
        XCTAssertNil(appState.indeterminateSessionWrites[ObjectIdentifier(session)])
        XCTAssertEqual(
            appState.fileWriteArtifactNotices,
            [
                FileWriteArtifactNotice(
                    destinationURL: destinationURL,
                    destinationWasCommitted: true,
                    artifactState: .removalIndeterminate(recoveryLocation)
                ),
            ]
        )
        XCTAssertEqual(appState.presentedError?.title, "File Saved; Cleanup Required")
    }

    func testAnchoredNotCommittedSaveRetainsPreparedArtifactAndLeavesSessionDirty() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let post = root.appendingPathComponent("post.md").standardizedFileURL
        let recovery = root.appendingPathComponent(".post.prepared").standardizedFileURL
        try writeText("disk A", to: post)
        try writeText("prepared edited A", to: recovery)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: "post.md")
        let recoveryLocation = try authority.location(relativePath: ".post.prepared")
        let loaded = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(
            text: "edited A",
            url: post,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.sessionCache[post] = session
        let binding = AnchoredWorkspaceSessionFileBinding(
            location: location,
            identity: loaded.metadata.identity,
            sha256Digest: loaded.sha256Digest
        )
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] = binding
        let notCommitted = WorkspaceNotCommittedFileWrite(
            reason: .durabilityFailed,
            artifactState: .retained(recoveryLocation)
        )
        appState.anchoredFileSaveOverride = { _, _, _ in .notCommitted(notCommitted) }

        XCTAssertThrowsError(try appState.save(session: session)) { error in
            XCTAssertEqual(
                error as? MarkdownFileStoreError,
                .writeNotCommittedWithCleanupRequired(post, notCommitted)
            )
        }

        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: session), binding)
        XCTAssertNil(appState.indeterminateSessionWrites[ObjectIdentifier(session)])
        XCTAssertEqual(
            appState.fileWriteArtifactNotices,
            [
                FileWriteArtifactNotice(
                    destinationURL: post,
                    destinationWasCommitted: false,
                    artifactState: .retained(recoveryLocation)
                ),
            ]
        )
        XCTAssertEqual(try String(contentsOf: post, encoding: .utf8), "disk A")
    }

    func testLegacySaveTreatsCommittedCleanupErrorAsSuccessWithNotice() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let post = root.appendingPathComponent("post.md").standardizedFileURL
        try writeText("disk A", to: post)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let recoveryLocation = try authority.location(relativePath: ".post.recovery")
        let session = DocumentSession(
            text: "edited A",
            url: post,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.sessionCache[post] = session
        appState.legacyFileSaveOverride = { text, destinationURL in
            let location = try WorkspaceFileSystemLocation(fileURL: destinationURL)
            let outcome = try MarkdownFileStore().save(
                text: text,
                at: location,
                expecting: .existingOrMissing
            )
            guard case let .committedAndDurable(actual) = outcome else {
                return XCTFail("Expected deterministic legacy save")
            }
            throw MarkdownFileStoreError.committedWithCleanupRequired(
                destinationURL,
                WorkspaceDurableFileWrite(
                    metadata: actual.metadata,
                    cleanupState: .retained(recoveryLocation)
                )
            )
        }

        try appState.save(session: session)

        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(try String(contentsOf: post, encoding: .utf8), "edited A")
        XCTAssertNil(appState.indeterminateSessionWrites[ObjectIdentifier(session)])
        XCTAssertEqual(appState.fileWriteArtifactNotices.first?.artifactState, .retained(recoveryLocation))
        XCTAssertEqual(appState.presentedError?.title, "File Saved; Cleanup Required")
    }

    func testLegacySaveCopyTreatsCommittedCleanupErrorAsSuccessfulRehome() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingURL = root.appendingPathComponent("missing.md").standardizedFileURL
        let destinationURL = root.appendingPathComponent("recovered.md").standardizedFileURL
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let recoveryLocation = try authority.location(relativePath: ".recovered.cleanup")
        let session = DocumentSession(
            text: "unsaved A",
            url: missingURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.sessionCache[missingURL] = session
        appState.detachedSessionURLs.insert(missingURL)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: missingURL)
        appState.legacyFileSaveOverride = { text, destinationURL in
            let location = try WorkspaceFileSystemLocation(fileURL: destinationURL)
            let outcome = try MarkdownFileStore().save(
                text: text,
                at: location,
                expecting: .existingOrMissing
            )
            guard case let .committedAndDurable(actual) = outcome else {
                return XCTFail("Expected deterministic legacy Save Copy")
            }
            throw MarkdownFileStoreError.committedWithCleanupRequired(
                destinationURL,
                WorkspaceDurableFileWrite(
                    metadata: actual.metadata,
                    cleanupState: .removalIndeterminate(recoveryLocation)
                )
            )
        }

        try appState.saveDetachedCurrentDocument(to: destinationURL)

        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.fileURL?.standardizedFileURL, destinationURL)
        XCTAssertTrue(appState.sessionCache[destinationURL] === session)
        XCTAssertNil(appState.sessionCache[missingURL])
        XCTAssertNil(appState.indeterminateSessionWrites[ObjectIdentifier(session)])
        XCTAssertEqual(
            appState.fileWriteArtifactNotices.first?.artifactState,
            .removalIndeterminate(recoveryLocation)
        )
        XCTAssertEqual(appState.presentedError?.title, "File Saved; Cleanup Required")
    }

    func testIndeterminateAnchoredSaveBlocksBlindRetryUntilExplicitReconciliation() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let post = root.appendingPathComponent("post.md").standardizedFileURL
        try writeText("disk A", to: post)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: "post.md")
        let loaded = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(
            text: "edited A",
            url: post,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.sessionCache[post] = session
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] =
            AnchoredWorkspaceSessionFileBinding(
                location: location,
                identity: loaded.metadata.identity,
                sha256Digest: loaded.sha256Digest
            )
        let indeterminate = WorkspaceIndeterminateFileWrite(
            reason: .durabilityFailed,
            preparedMetadata: loaded.metadata,
            recoveryArtifact: .retained(location)
        )
        var saveAttempts = 0
        appState.anchoredFileSaveOverride = { _, _, _ in
            saveAttempts += 1
            return .committedButIndeterminate(indeterminate)
        }

        XCTAssertThrowsError(try appState.saveCurrentDocument())
        XCTAssertEqual(saveAttempts, 1)
        XCTAssertEqual(
            appState.indeterminateSessionWrites[ObjectIdentifier(session)],
            indeterminate
        )
        XCTAssertFalse(appState.canSave)
        XCTAssertFalse(appState.canAutosave(session: session))

        XCTAssertThrowsError(try appState.saveCurrentDocument())
        XCTAssertEqual(saveAttempts, 1, "a quarantined session must not enter the writer again")

        appState.handleExternalChange(for: session)
        XCTAssertEqual(appState.pendingExternalTexts[post], "disk A")
        appState.keepMineForExternallyChangedFile()
        appState.autosaveTask?.cancel()
        appState.anchoredFileSaveOverride = nil
        XCTAssertNil(appState.indeterminateSessionWrites[ObjectIdentifier(session)])
        XCTAssertTrue(appState.canSave)
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

    func testWorkspaceReloadKeepsLatestSnapshotWhenOlderScanFinishesLast() async throws {
        let root = try makeTemporaryDirectory()
        try writeText("Old", to: root.appendingPathComponent("old.md"))
        try writeText("New", to: root.appendingPathComponent("new.md"))
        let scanner = ControlledWorkspaceDirectoryScanner()
        let appState = AppState(directoryScanner: scanner, shouldRestoreLastOpenedFile: false)

        appState.openExternalFile(root)
        await scanner.waitForRequestCount(1)
        let firstReloadTask = appState.workspaceReloadTask
        let firstGeneration = appState.workspaceGeneration

        appState.refreshWorkspaceAfterFileSystemChange()
        await scanner.waitForRequestCount(2)
        XCTAssertGreaterThan(appState.workspaceGeneration, firstGeneration)

        await scanner.completeRequest(at: 1, with: snapshot("new.md"))
        try await waitUntil("new snapshot applied") {
            appState.workspaceSnapshot?.entries.map(\.relativePath) == ["new.md"] &&
                appState.workspaceTree?.selectedNode?.relativePath == "new.md"
        }
        await scanner.completeRequest(at: 0, with: snapshot("old.md"))
        await firstReloadTask?.value

        XCTAssertEqual(appState.workspaceSnapshot?.entries.map(\.relativePath), ["new.md"])
        XCTAssertEqual(appState.workspaceTree?.selectedNode?.relativePath, "new.md")
    }

    func testWorkspaceClosePreventsOlderScanFromRestoringSnapshotOrTree() async throws {
        let root = try makeTemporaryDirectory()
        try writeText("Old", to: root.appendingPathComponent("old.md"))
        let scanner = ControlledWorkspaceDirectoryScanner()
        let appState = AppState(directoryScanner: scanner, shouldRestoreLastOpenedFile: false)

        appState.openExternalFile(root)
        await scanner.waitForRequestCount(1)
        let firstReloadTask = appState.workspaceReloadTask
        appState.closeWorkspace()
        await scanner.completeRequest(at: 0, with: snapshot("old.md"))
        await firstReloadTask?.value

        XCTAssertNil(appState.workspaceRootURL)
        XCTAssertNil(appState.workspaceSnapshot)
        XCTAssertNil(appState.workspaceTree)
    }

    func testWorkspaceSwitchPreventsOlderRootFromRestoringSnapshotOrTree() async throws {
        let rootA = try makeTemporaryDirectory()
        let rootB = try makeTemporaryDirectory()
        try writeText("A", to: rootA.appendingPathComponent("a.md"))
        try writeText("B", to: rootB.appendingPathComponent("b.md"))
        let scanner = ControlledWorkspaceDirectoryScanner()
        let appState = AppState(directoryScanner: scanner, shouldRestoreLastOpenedFile: false)

        appState.openExternalFile(rootA)
        await scanner.waitForRequestCount(1)
        let firstReloadTask = appState.workspaceReloadTask
        appState.openExternalFile(rootB)
        await scanner.waitForRequestCount(2)

        await scanner.completeRequest(at: 1, with: snapshot("b.md"))
        try await waitUntil("second workspace applied") {
            appState.workspaceRootURL?.standardizedFileURL == rootB.standardizedFileURL &&
                appState.workspaceSnapshot?.entries.map(\.relativePath) == ["b.md"]
        }
        await scanner.completeRequest(at: 0, with: snapshot("a.md"))
        await firstReloadTask?.value

        XCTAssertEqual(appState.workspaceRootURL?.standardizedFileURL, rootB.standardizedFileURL)
        XCTAssertEqual(appState.workspaceSnapshot?.entries.map(\.relativePath), ["b.md"])
        XCTAssertEqual(
            appState.workspaceSearchRootAuthority?.canonicalRootURL,
            try WorkspaceFileSystemRootAuthority(rootURL: rootB).canonicalRootURL
        )
        XCTAssertEqual(appState.workspaceTree?.selectedNode?.relativePath, "b.md")
    }

    func testWorkspaceRetainsRawSnapshotIndependentOfTreeFilter() async throws {
        let root = try makeTemporaryDirectory()
        try writeText("Post", to: root.appendingPathComponent("post.md"))
        let scanner = ControlledWorkspaceDirectoryScanner()
        let appState = AppState(directoryScanner: scanner, shouldRestoreLastOpenedFile: false)

        appState.openExternalFile(root)
        await scanner.waitForRequestCount(1)
        await scanner.completeRequest(at: 0, with: WorkspaceFileSnapshot(entries: [
            WorkspaceFileSnapshot.Entry(
                relativePath: "post.md",
                kind: .markdown,
                identity: "post",
                contentModificationDate: nil
            ),
            WorkspaceFileSnapshot.Entry(
                relativePath: "metadata.json",
                kind: .other,
                identity: "metadata",
                contentModificationDate: nil
            ),
        ]))
        try await waitUntil("raw snapshot applied") {
            appState.workspaceSnapshot?.entries.count == 2
        }

        XCTAssertEqual(appState.workspaceSnapshot?.entries.map(\.relativePath), ["post.md", "metadata.json"])
        XCTAssertEqual(appState.workspaceTree?.root.children.map(\.relativePath), ["post.md"])
    }

    func testWorkspaceReloadRejectsSelectedSymlinkRetargetAfterCapture() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let rootA = parent.appendingPathComponent("A", isDirectory: true)
        let rootB = parent.appendingPathComponent("B", isDirectory: true)
        let selected = parent.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        try writeText("needle A only", to: rootA.appendingPathComponent("a.md"))
        try writeText("needle B only", to: rootB.appendingPathComponent("b.md"))
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: rootA)

        let scanner = ControlledWorkspaceDirectoryScanner()
        let appState = AppState(directoryScanner: scanner, shouldRestoreLastOpenedFile: false)
        // Avoid FSEvents watcher: install only the selected root spelling under test.
        appState.workspaceRootURL = selected
        let reloadTask = Task {
            try await appState.reloadWorkspaceTree(root: selected, selectFirstIfNeeded: true)
        }
        await scanner.waitForRequestCount(1)
        await scanner.completeRequest(
            at: 0,
            with: snapshot("a.md"),
            afterCapture: {
                try FileManager.default.removeItem(at: selected)
                try FileManager.default.createSymbolicLink(
                    at: selected,
                    withDestinationURL: rootB
                )
            }
        )
        do {
            try await reloadTask.value
            XCTFail("Expected stale capture rejection")
        } catch is CancellationError {
            // Reject/retry path: do not install mixed A/B roots.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        // Stale capture for A must not install while selected spelling now names B.
        XCTAssertNil(appState.workspaceSnapshot)
        XCTAssertNil(appState.workspaceSearchRootAuthority)
        XCTAssertNil(appState.workspaceInstalledCaptureGeneration)
        XCTAssertNotEqual(appState.currentDocument.fileURL?.lastPathComponent, "a.md")
        XCTAssertNotEqual(appState.currentDocument.fileURL?.lastPathComponent, "b.md")
    }

    func testWorkspaceReloadRejectsCapturedDirectoryMovedAndReplacedAtSameSpelling() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let moved = parent.appendingPathComponent("moved-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeText("captured A", to: root.appendingPathComponent("a.md"))

        let scanner = ControlledWorkspaceDirectoryScanner()
        let appState = AppState(directoryScanner: scanner, shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        let reloadTask = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: true)
        }
        await scanner.waitForRequestCount(1)
        await scanner.completeRequest(
            at: 0,
            with: snapshot("a.md"),
            afterCapture: {
                try FileManager.default.moveItem(at: root, to: moved)
                try FileManager.default.createDirectory(
                    at: root,
                    withIntermediateDirectories: true
                )
                try "replacement B".write(
                    to: root.appendingPathComponent("b.md"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        )
        do {
            try await reloadTask.value
            XCTFail("Expected stale capture rejection")
        } catch is CancellationError {
            // Reject/retry path: no A snapshot with B editor activation.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertNil(appState.workspaceSnapshot)
        XCTAssertNil(appState.workspaceSearchRootAuthority)
        XCTAssertNil(appState.workspaceInstalledCaptureGeneration)
        // No A snapshot/search authority alongside B editor activation.
        XCTAssertNotEqual(appState.currentDocument.fileURL?.lastPathComponent, "a.md")
        XCTAssertNotEqual(appState.currentDocument.fileURL?.lastPathComponent, "b.md")
        XCTAssertNotEqual(appState.currentDocument.text, "captured A")
        XCTAssertNotEqual(appState.currentDocument.text, "replacement B")
    }

    // swiftlint:disable:next function_body_length
    func testWorkspaceReloadReplacementAfterProofPreservesInstalledStateAndDoesNotActivateB() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let moved = parent.appendingPathComponent("moved-workspace", isDirectory: true)
        let documentURL = root.appendingPathComponent("a.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeText("captured A", to: documentURL)

        let currentSession = DocumentSession(
            text: "captured A",
            url: documentURL,
            fileKind: .markdown
        )
        let scanner = ControlledWorkspaceDirectoryScanner()
        let appState = AppState(
            currentDocument: currentSession,
            directoryScanner: scanner,
            shouldRestoreLastOpenedFile: false
        )
        let previousSnapshot = snapshot("previous.md")
        let previousAuthority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let previousTree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: previousSnapshot,
            options: .init(showAllFiles: false)
        )
        let previousInstalledGeneration: UInt64 = 7
        appState.workspaceRootURL = root
        appState.workspaceSnapshot = previousSnapshot
        appState.workspaceSearchRootAuthority = previousAuthority
        appState.workspaceGeneration = previousInstalledGeneration
        appState.workspaceInstalledCaptureGeneration = previousInstalledGeneration
        appState.workspaceTree = previousTree
        appState.sessionCache[documentURL.standardizedFileURL] = currentSession
        appState.workspaceReloadPostProofHook = {
            try FileManager.default.moveItem(at: root, to: moved)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            try "replacement B".write(
                to: root.appendingPathComponent("a.md"),
                atomically: true,
                encoding: .utf8
            )
        }

        let reloadTask = Task {
            try await appState.reloadWorkspaceTree(root: root, selectFirstIfNeeded: true)
        }
        await scanner.waitForRequestCount(1)
        await scanner.completeRequest(at: 0, with: snapshot("a.md"))
        do {
            try await reloadTask.value
            XCTFail("Expected anchored reload activation to reject replacement B")
        } catch WorkspaceAnchoredFileSystemError.namespaceChanged {
            // The post-proof replacement must fail before any new App state is committed.
        } catch {
            XCTFail("Expected namespaceChanged, got \(error)")
        }

        XCTAssertEqual(appState.workspaceGeneration, previousInstalledGeneration + 1)
        XCTAssertEqual(appState.workspaceSnapshot, previousSnapshot)
        XCTAssertEqual(appState.workspaceSearchRootAuthority, previousAuthority)
        XCTAssertEqual(
            appState.workspaceInstalledCaptureGeneration,
            previousInstalledGeneration
        )
        XCTAssertEqual(appState.workspaceTree, previousTree)
        XCTAssertTrue(appState.currentDocument === currentSession)
        XCTAssertTrue(appState.sessionCache[documentURL.standardizedFileURL] === currentSession)
        XCTAssertEqual(appState.currentDocument.text, "captured A")
        XCTAssertNotEqual(appState.currentDocument.text, "replacement B")
    }

    func testSuspendedSameRootReloadDoesNotLabelOldCaptureWithNewGeneration() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeText("old alpha", to: root.appendingPathComponent("old.md"))
        try writeText("new beta", to: root.appendingPathComponent("new.md"))
        let scanner = ControlledWorkspaceDirectoryScanner()
        let provider = ControlledWorkspaceSearchStreamProvider()
        let appState = AppState(
            directoryScanner: scanner,
            workspaceSearchStreamProvider: provider,
            workspaceSearchDebounceNanoseconds: 0,
            shouldRestoreLastOpenedFile: false
        )

        appState.openExternalFile(root)
        await scanner.waitForRequestCount(1)
        let oldAuthority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        await scanner.completeRequest(at: 0, with: snapshot("old.md"))
        try await waitUntil("initial snapshot installed") {
            appState.workspaceSnapshot?.entries.map(\.relativePath) == ["old.md"]
                && appState.workspaceInstalledCaptureGeneration == appState.workspaceGeneration
        }
        let oldGeneration = appState.workspaceGeneration
        let oldInstalled = try XCTUnwrap(appState.workspaceInstalledCaptureGeneration)

        // Start a same-root reload; generation advances while the replacement scan is suspended.
        appState.scheduleWorkspaceReload(
            root: root,
            selectFirstIfNeeded: false,
            errorTitle: "Could Not Reload Workspace"
        )
        await scanner.waitForRequestCount(2)
        XCTAssertEqual(appState.workspaceGeneration, oldGeneration + 1)
        XCTAssertEqual(appState.workspaceInstalledCaptureGeneration, oldInstalled)
        XCTAssertEqual(appState.workspaceSnapshot?.entries.map(\.relativePath), ["old.md"])

        // A query started while suspended must not use the old pair labeled as the new generation.
        appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "old"))
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertNil(appState.workspaceSearchState.activeContext)

        await scanner.completeRequest(at: 1, with: snapshot("new.md"))
        try await waitUntil("replacement snapshot installed") {
            appState.workspaceSnapshot?.entries.map(\.relativePath) == ["new.md"]
                && appState.workspaceInstalledCaptureGeneration == appState.workspaceGeneration
        }

        XCTAssertNotEqual(
            appState.workspaceInstalledCaptureGeneration,
            oldInstalled
        )
        XCTAssertEqual(
            appState.workspaceSearchRootAuthority?.canonicalRootURL,
            oldAuthority.canonicalRootURL
        )
        // Still no request/result that paired the old snapshot with the new generation.
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertFalse(
            provider.requests.contains {
                $0.workspaceGeneration == appState.workspaceGeneration
                    && $0.snapshot.entries.map(\.relativePath) == ["old.md"]
            }
        )
    }

    private func snapshot(_ path: String) -> WorkspaceFileSnapshot {
        snapshot([path])
    }

    private func snapshot(_ paths: [String]) -> WorkspaceFileSnapshot {
        WorkspaceFileSnapshot(entries: paths.map { path in
            WorkspaceFileSnapshot.Entry(
                relativePath: path,
                kind: .markdown,
                identity: path,
                contentModificationDate: nil
            )
        })
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

@MainActor
final class WorkspaceSearchAppStateTests: XCTestCase {
    func testAppBindingPropagatesCanonicalEquivalentRawDifferentText() async throws {
        let original = "cafe\u{0301}"
        let replacement = "caf\u{00E9}"
        let session = DocumentSession(text: original, fileKind: .markdown)
        let appState = AppState(currentDocument: session)
        var iterator = session.textChanges(includeCurrent: false).makeAsyncIterator()

        appState.replaceDocumentText(replacement)

        let nextChange = await iterator.next()
        let change = try XCTUnwrap(nextChange)
        XCTAssertEqual(Array(session.text.utf16), Array(replacement.utf16))
        XCTAssertEqual(Array(change.text.utf16), Array(replacement.utf16))
        XCTAssertEqual(session.version, 1)
        XCTAssertTrue(session.isDirty)
        appState.completionWorkspaceTask?.cancel()
        appState.statisticsTask?.cancel()
    }

    // swiftlint:disable:next function_body_length
    func testInstalledEditorLeaseRetainsExactCrossDocumentIMECommitUntilHandoffAndTeardown() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentAURL = rootURL.appendingPathComponent("a.md")
        let documentBURL = rootURL.appendingPathComponent("b.md")
        let sourceA = "A composition: "
        let sourceB = "# B Original\nB disk body"
        try sourceA.write(to: documentAURL, atomically: true, encoding: .utf8)
        try sourceB.write(to: documentBURL, atomically: true, encoding: .utf8)
        let defaultsSuiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.set(0.5, forKey: "Plainsong.settings.autosaveIntervalSeconds")
        let sessionA = DocumentSession(
            text: sourceA,
            url: documentAURL,
            fileKind: .markdown
        )
        let appState = AppState(
            currentDocument: sessionA,
            shouldRestoreLastOpenedFile: false,
            userDefaults: defaults
        )
        let workspaceSnapshot = snapshot(paths: ["a.md", "b.md"], rootURL: rootURL)
        appState.workspaceRootURL = rootURL
        appState.workspaceSnapshot = workspaceSnapshot
        appState.workspaceSearchRootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: rootURL
        )
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.workspaceTree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: workspaceSnapshot,
            options: .init(showAllFiles: false)
        )
        appState.sessionPolicy = WorkspaceSessionLRUPolicy(limit: 1)
        appState.sessionCache[documentAURL.standardizedFileURL] = sessionA
        _ = appState.sessionPolicy.access(documentAURL, isDirty: false)

        var selectionA: NSRange? = NSRange(location: (sourceA as NSString).length, length: 0)
        var selectionB: NSRange? = NSRange(location: 2, length: 0)
        let bindingA = appState.editorDocumentBinding(for: sessionA)
        let documentAView = MarkdownTextView(
            text: bindingA.text,
            styledText: nil,
            selection: Binding(get: { selectionA }, set: { selectionA = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentAURL),
            documentBindingID: bindingA.id,
            onDocumentBindingLifecycle: bindingA.onLifecycle
        )
        let fixture = try makeEditorBridgeFixture(
            representable: documentAView,
            source: sourceA
        )
        defer {
            fixture.window.orderOut(nil)
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
            for task in appState.sessionAutosaveTasks.values {
                task.task.cancel()
            }
            for task in appState.sessionStatisticsTasks.values {
                task.task.cancel()
            }
            try? FileManager.default.removeItem(at: rootURL)
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }

        XCTAssertTrue(appState.installedEditorDocumentBindingLease?.session === sessionA)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.textSelection = selectionA ?? .notFound
        fixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        XCTAssertTrue(fixture.textView.hasMarkedText())

        try appState.activateFileSession(url: documentBURL)
        let sessionB = appState.currentDocument
        let dirtySourceB = "# B Unique\nB dirty body"
        appState.replaceDocumentText(dirtySourceB, in: sessionB)
        let pendingDocumentBAutosave = try XCTUnwrap(appState.autosaveTask)
        let pendingDocumentBStatistics = try XCTUnwrap(appState.statisticsTask)
        let pendingDocumentBCompletion = try XCTUnwrap(appState.completionWorkspaceTask)
        let bindingB = appState.editorDocumentBinding(for: sessionB)
        let documentBView = MarkdownTextView(
            text: bindingB.text,
            styledText: nil,
            selection: Binding(get: { selectionB }, set: { selectionB = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentBURL),
            documentBindingID: bindingB.id,
            onDocumentBindingLifecycle: bindingB.onLifecycle
        )
        documentBView.updateRepresentedTextView(
            fixture.scrollView,
            coordinator: fixture.coordinator
        )

        XCTAssertTrue(fixture.textView.hasMarkedText())
        XCTAssertTrue(appState.installedEditorDocumentBindingLease?.session === sessionA)
        XCTAssertTrue(appState.sessionCache[documentAURL.standardizedFileURL] === sessionA)
        XCTAssertEqual(fixture.coordinator.currentDocumentIdentity, AppState.editorDocumentIdentity(for: documentAURL))
        XCTAssertEqual(Data(sessionB.text.utf8), Data(dirtySourceB.utf8))
        XCTAssertEqual(sessionB.version, 1)
        XCTAssertEqual(selectionB, NSRange(location: 2, length: 0))

        let committedText = "臺e\u{0301}🧪"
        fixture.textView.insertText(committedText, replacementRange: .notFound)
        let committedSourceA = sourceA + committedText

        XCTAssertEqual(Data(sessionA.text.utf8), Data(committedSourceA.utf8))
        XCTAssertEqual(Array(sessionA.text.utf16), Array(committedSourceA.utf16))
        XCTAssertEqual(sessionA.version, 1)
        XCTAssertTrue(sessionA.isDirty)
        XCTAssertEqual(appState.sessionPolicy.dirtyState(for: documentAURL), true)
        XCTAssertFalse(pendingDocumentBAutosave.isCancelled)
        XCTAssertFalse(pendingDocumentBStatistics.isCancelled)
        XCTAssertFalse(pendingDocumentBCompletion.isCancelled)
        XCTAssertNotNil(appState.sessionAutosaveTasks[ObjectIdentifier(sessionA)])
        XCTAssertNotNil(appState.sessionStatisticsTasks[ObjectIdentifier(sessionA)])
        XCTAssertEqual(Data(sessionB.text.utf8), Data(dirtySourceB.utf8))
        XCTAssertEqual(sessionB.version, 1)
        XCTAssertEqual(selectionB, NSRange(location: 2, length: 0))
        XCTAssertEqual(try String(contentsOf: documentBURL, encoding: .utf8), sourceB)

        documentBView.updateRepresentedTextView(
            fixture.scrollView,
            coordinator: fixture.coordinator
        )
        XCTAssertTrue(appState.installedEditorDocumentBindingLease?.session === sessionB)
        XCTAssertNil(appState.sessionCache[documentAURL.standardizedFileURL])
        XCTAssertEqual(fixture.coordinator.currentDocumentIdentity, AppState.editorDocumentIdentity(for: documentBURL))

        bindingA.text.wrappedValue = committedSourceA + " rejected"
        XCTAssertEqual(Data(sessionA.text.utf8), Data(committedSourceA.utf8))
        let finalSourceB = "# B Unique\nB editor write succeeds"
        bindingB.text.wrappedValue = finalSourceB
        XCTAssertEqual(Data(sessionB.text.utf8), Data(finalSourceB.utf8))

        MarkdownTextView.dismantleNSView(
            fixture.scrollView,
            coordinator: fixture.coordinator
        )
        XCTAssertNil(appState.installedEditorDocumentBindingLease)
        bindingB.text.wrappedValue = finalSourceB + " rejected after teardown"
        XCTAssertEqual(Data(sessionB.text.utf8), Data(finalSourceB.utf8))

        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertEqual(sessionA.statistics, TextStatistics(text: committedSourceA))
        XCTAssertEqual(sessionB.statistics, TextStatistics(text: finalSourceB))
        XCTAssertEqual(appState.completionWorkspace.currentFileHeadingAnchors, ["#b-unique"])
        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), committedSourceA)
        XCTAssertEqual(try String(contentsOf: documentBURL, encoding: .utf8), finalSourceB)
        XCTAssertFalse(sessionA.isDirty)
        XCTAssertFalse(sessionB.isDirty)
        XCTAssertNil(appState.sessionPolicy.dirtyState(for: documentAURL))
        XCTAssertEqual(appState.sessionPolicy.dirtyState(for: documentBURL), false)
    }

    // swiftlint:disable:next function_body_length
    func testSessionScopedExternalConflictBlocksNonCurrentIMEAutosaveAndLeavesCurrentTasksIntact() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentAURL = rootURL.appendingPathComponent("a.md")
        let documentBURL = rootURL.appendingPathComponent("b.md")
        let sourceA = "A composition: "
        let dirtySourceA = "A draft composition: "
        let sourceB = "# B Original\nB disk body"
        let externalSourceA = "A changed externally"
        try sourceA.write(to: documentAURL, atomically: true, encoding: .utf8)
        try sourceB.write(to: documentBURL, atomically: true, encoding: .utf8)
        let defaultsSuiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.set(0.5, forKey: "Plainsong.settings.autosaveIntervalSeconds")
        let sessionA = DocumentSession(text: sourceA, url: documentAURL, fileKind: .markdown)
        let appState = AppState(
            currentDocument: sessionA,
            shouldRestoreLastOpenedFile: false,
            userDefaults: defaults
        )
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["a.md", "b.md"],
            currentSession: sessionA
        )
        appState.sessionPolicy = WorkspaceSessionLRUPolicy(limit: 1)
        appState.replaceDocumentText(dirtySourceA, in: sessionA)

        var selectionA: NSRange? = NSRange(location: (dirtySourceA as NSString).length, length: 0)
        var selectionB: NSRange? = NSRange(location: 2, length: 0)
        let bindingA = appState.editorDocumentBinding(for: sessionA)
        let documentAView = MarkdownTextView(
            text: bindingA.text,
            styledText: nil,
            selection: Binding(get: { selectionA }, set: { selectionA = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentAURL),
            documentBindingID: bindingA.id,
            onDocumentBindingLifecycle: bindingA.onLifecycle
        )
        let editorFixture = try makeEditorBridgeFixture(representable: documentAView, source: dirtySourceA)
        defer {
            editorFixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(
                editorFixture.scrollView,
                coordinator: editorFixture.coordinator
            )
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
            for task in appState.sessionAutosaveTasks.values {
                task.task.cancel()
            }
            for task in appState.sessionStatisticsTasks.values {
                task.task.cancel()
            }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: rootURL)
        }

        XCTAssertTrue(editorFixture.window.makeFirstResponder(editorFixture.textView))
        editorFixture.textView.textSelection = selectionA ?? .notFound
        editorFixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )

        try appState.activateFileSession(url: documentBURL)
        let sessionB = appState.currentDocument
        let dirtySourceB = "# B Unique\nB dirty body"
        appState.replaceDocumentText(dirtySourceB, in: sessionB)
        let documentBAutosave = try XCTUnwrap(appState.autosaveTask)
        let documentBStatistics = try XCTUnwrap(appState.statisticsTask)
        let documentBCompletion = try XCTUnwrap(appState.completionWorkspaceTask)
        let bindingB = appState.editorDocumentBinding(for: sessionB)
        let documentBView = MarkdownTextView(
            text: bindingB.text,
            styledText: nil,
            selection: Binding(get: { selectionB }, set: { selectionB = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentBURL),
            documentBindingID: bindingB.id,
            onDocumentBindingLifecycle: bindingB.onLifecycle
        )
        documentBView.updateRepresentedTextView(
            editorFixture.scrollView,
            coordinator: editorFixture.coordinator
        )
        XCTAssertTrue(appState.installedEditorDocumentBindingLease?.session === sessionA)

        try externalSourceA.write(to: documentAURL, atomically: true, encoding: .utf8)
        appState.lastKnownDiskModificationDates[documentAURL.standardizedFileURL] = .distantPast
        appState.handleExternalChange(for: sessionA)

        XCTAssertEqual(appState.pendingExternalTexts[documentAURL.standardizedFileURL], externalSourceA)
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertTrue(appState.currentDocument === sessionB)
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: documentAURL)
        appState.reloadExternallyChangedFile()
        XCTAssertEqual(appState.pendingExternalTexts[documentAURL.standardizedFileURL], externalSourceA)
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: documentAURL)
        appState.keepMineForExternallyChangedFile()
        XCTAssertEqual(appState.pendingExternalTexts[documentAURL.standardizedFileURL], externalSourceA)
        XCTAssertNil(appState.externalChangePrompt)

        let committedText = "臺e\u{0301}🧪"
        editorFixture.textView.insertText(committedText, replacementRange: .notFound)
        let committedSourceA = dirtySourceA + committedText
        XCTAssertFalse(documentBAutosave.isCancelled)
        XCTAssertFalse(documentBStatistics.isCancelled)
        XCTAssertFalse(documentBCompletion.isCancelled)
        try await Task.sleep(nanoseconds: 750_000_000)

        XCTAssertEqual(Array(sessionA.text.utf16), Array(committedSourceA.utf16))
        XCTAssertEqual(sessionA.version, 2)
        XCTAssertTrue(sessionA.isDirty)
        XCTAssertFalse(appState.canAutosave(session: sessionA))
        XCTAssertNil(appState.sessionAutosaveTasks[ObjectIdentifier(sessionA)])
        XCTAssertThrowsError(try appState.save(session: sessionA)) { error in
            guard case AppStateError.unresolvedExternalChange = error else {
                return XCTFail("Expected the session-scoped external conflict")
            }
        }
        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), externalSourceA)
        XCTAssertEqual(sessionB.text, dirtySourceB)
        XCTAssertFalse(sessionB.isDirty)
        XCTAssertEqual(sessionB.statistics, TextStatistics(text: dirtySourceB))
        XCTAssertEqual(appState.completionWorkspace.currentFileHeadingAnchors, ["#b-unique"])
        XCTAssertEqual(try String(contentsOf: documentBURL, encoding: .utf8), dirtySourceB)
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertNil(appState.missingFilePrompt)

        documentBView.updateRepresentedTextView(
            editorFixture.scrollView,
            coordinator: editorFixture.coordinator
        )
        XCTAssertTrue(appState.installedEditorDocumentBindingLease?.session === sessionB)
        XCTAssertTrue(appState.sessionCache[documentAURL.standardizedFileURL] === sessionA)
        XCTAssertTrue(sessionA.isDirty)
        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), externalSourceA)

        try appState.activateFileSession(url: documentAURL)
        XCTAssertEqual(appState.externalChangePrompt?.fileURL.standardizedFileURL, documentAURL.standardizedFileURL)
        appState.keepMineForExternallyChangedFile()
        XCTAssertNil(appState.pendingExternalTexts[documentAURL.standardizedFileURL])
        XCTAssertTrue(appState.canAutosave(session: sessionA))
        try appState.save(session: sessionA)
        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), committedSourceA)
        XCTAssertFalse(sessionA.isDirty)
    }

    func testReloadClearsSessionConflictAndRestoresSaveEligibility() throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("post.md")
        let original = "Original"
        let local = "Local dirty text"
        let external = "External disk text"
        try original.write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: original, url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["post.md"],
            currentSession: session
        )
        defer {
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
            try? FileManager.default.removeItem(at: rootURL)
        }

        appState.replaceDocumentText(local, in: session)
        try external.write(to: documentURL, atomically: true, encoding: .utf8)
        appState.lastKnownDiskModificationDates[documentURL.standardizedFileURL] = .distantPast
        appState.handleExternalChange(for: session)
        XCTAssertFalse(appState.canAutosave(session: session))
        XCTAssertThrowsError(try appState.save(session: session))

        appState.reloadExternallyChangedFile()

        XCTAssertEqual(session.text, external)
        XCTAssertFalse(session.isDirty)
        XCTAssertNil(appState.pendingExternalTexts[documentURL.standardizedFileURL])
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertTrue(appState.canAutosave(session: session))
        XCTAssertEqual(appState.sessionPolicy.dirtyState(for: documentURL), false)
        XCTAssertNoThrow(try appState.save(session: session))
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), external)
    }

    func testUnretirableExternalConflictBlocksWorkspaceCloseWithoutDiscardingSession() throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("post.md")
        try "Original".write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: "Original", url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["post.md"],
            currentSession: session,
            retainSecurityScope: true
        )
        defer {
            appState.pendingExternalTexts[documentURL.standardizedFileURL] = nil
            appState.externalChangePrompt = nil
            appState.closeWorkspace()
            try? FileManager.default.removeItem(at: rootURL)
        }
        appState.replaceDocumentText("Local dirty text", in: session)
        try "External disk text".write(to: documentURL, atomically: true, encoding: .utf8)
        appState.lastKnownDiskModificationDates[documentURL.standardizedFileURL] = .distantPast
        appState.handleExternalChange(for: session)

        appState.removeEditorDocumentBindingRegistration(for: session)
        appState.installedEditorDocumentBindingLease = nil
        appState.closeWorkspace()

        XCTAssertEqual(appState.workspaceRootURL?.standardizedFileURL, rootURL.standardizedFileURL)
        XCTAssertTrue(appState.currentDocument === session)
        XCTAssertTrue(appState.sessionCache[documentURL.standardizedFileURL] === session)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.text, "Local dirty text")
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), "External disk text")
        XCTAssertNotNil(appState.pendingExternalTexts[documentURL.standardizedFileURL])
        XCTAssertNotNil(appState.presentedError)
    }

    func testWorkspaceCloseRemovesUninstalledSessionBindingRegistration() throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("post.md")
        try "Source".write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: "Source", url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["post.md"],
            currentSession: session,
            retainSecurityScope: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let binding = appState.editorDocumentBinding(for: session)

        appState.closeWorkspace()

        XCTAssertNil(appState.workspaceRootURL)
        XCTAssertTrue(appState.sessionCache.isEmpty)
        XCTAssertNil(appState.editorDocumentBindingIDs[ObjectIdentifier(session)])
        XCTAssertNil(appState.editorDocumentBindingSessions[binding.id])
        XCTAssertTrue(appState.retiredEditorDocumentBindings.isEmpty)
    }

    func testRetiredInstalledConflictStaysRecoverableAfterRevocationUntilReload() throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("post.md")
        let original = "Original"
        let local = "Local dirty text"
        let external = "External disk text"
        try original.write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: original, url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["post.md"],
            currentSession: session,
            retainSecurityScope: true
        )
        defer {
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
            try? FileManager.default.removeItem(at: rootURL)
        }
        let binding = appState.editorDocumentBinding(for: session)
        binding.onLifecycle(.installed(binding.id))
        appState.replaceDocumentText(local, in: session)
        try external.write(to: documentURL, atomically: true, encoding: .utf8)
        appState.lastKnownDiskModificationDates[documentURL.standardizedFileURL] = .distantPast
        appState.handleExternalChange(for: session)

        try appState.closeWorkspaceForReplacement()
        binding.onLifecycle(.revoked(binding.id))

        let retirement = try XCTUnwrap(appState.retiredEditorDocumentBindings[binding.id])
        XCTAssertFalse(retirement.isAwaitingBindingEnd)
        XCTAssertTrue(retirement.session === session)
        XCTAssertEqual(retirement.securityScopedAuthority?.url.standardizedFileURL, rootURL.standardizedFileURL)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.text, local)
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), external)
        XCTAssertNil(appState.editorDocumentBindingIDs[ObjectIdentifier(session)])
        XCTAssertNil(appState.editorDocumentBindingSessions[binding.id])

        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: documentURL)
        appState.reloadExternallyChangedFile()

        XCTAssertEqual(session.text, external)
        XCTAssertFalse(session.isDirty)
        XCTAssertNil(appState.retiredEditorDocumentBindings[binding.id])
        XCTAssertNil(appState.pendingExternalTexts[documentURL.standardizedFileURL])
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), external)
    }

    // swiftlint:disable:next function_body_length
    func testWorkspaceToStandaloneRetainsExactBindingAuthorityUntilSuccessfulHandoff() throws {
        let workspaceRoot = try makeTemporaryDirectory()
        let standaloneRoot = try makeTemporaryDirectory()
        let documentAURL = workspaceRoot.appendingPathComponent("a.md")
        let documentBURL = standaloneRoot.appendingPathComponent("b.md")
        let sourceA = "A composition: "
        let sourceB = "B destination"
        try sourceA.write(to: documentAURL, atomically: true, encoding: .utf8)
        try sourceB.write(to: documentBURL, atomically: true, encoding: .utf8)
        let sessionA = DocumentSession(text: sourceA, url: documentAURL, fileKind: .markdown)
        let appState = AppState(currentDocument: sessionA, shouldRestoreLastOpenedFile: false)
        configureWorkspace(
            appState,
            rootURL: workspaceRoot,
            paths: ["a.md"],
            currentSession: sessionA,
            retainSecurityScope: true
        )

        var selectionA: NSRange? = NSRange(location: (sourceA as NSString).length, length: 0)
        var selectionB: NSRange? = NSRange(location: 0, length: 0)
        let bindingA = appState.editorDocumentBinding(for: sessionA)
        let documentAView = MarkdownTextView(
            text: bindingA.text,
            styledText: nil,
            selection: Binding(get: { selectionA }, set: { selectionA = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentAURL),
            documentBindingID: bindingA.id,
            onDocumentBindingLifecycle: bindingA.onLifecycle
        )
        let editorFixture = try makeEditorBridgeFixture(representable: documentAView, source: sourceA)
        defer {
            editorFixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(
                editorFixture.scrollView,
                coordinator: editorFixture.coordinator
            )
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
            try? FileManager.default.removeItem(at: workspaceRoot)
            try? FileManager.default.removeItem(at: standaloneRoot)
        }

        XCTAssertTrue(editorFixture.window.makeFirstResponder(editorFixture.textView))
        editorFixture.textView.textSelection = selectionA ?? .notFound
        editorFixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )

        try appState.open(url: documentBURL, rememberAsLastOpened: false, preserveWorkspace: false)
        let sessionB = appState.currentDocument
        let bindingB = appState.editorDocumentBinding(for: sessionB)
        let documentBView = MarkdownTextView(
            text: bindingB.text,
            styledText: nil,
            selection: Binding(get: { selectionB }, set: { selectionB = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentBURL),
            documentBindingID: bindingB.id,
            onDocumentBindingLifecycle: bindingB.onLifecycle
        )
        documentBView.updateRepresentedTextView(
            editorFixture.scrollView,
            coordinator: editorFixture.coordinator
        )

        let retirement = try XCTUnwrap(appState.retiredEditorDocumentBindings[bindingA.id])
        XCTAssertTrue(retirement.session === sessionA)
        XCTAssertEqual(retirement.securityScopedAuthority?.url.standardizedFileURL, workspaceRoot.standardizedFileURL)
        XCTAssertTrue(retirement.isAwaitingBindingEnd)
        XCTAssertTrue(appState.installedEditorDocumentBindingLease?.session === sessionA)
        XCTAssertNil(appState.workspaceRootURL)

        editorFixture.textView.insertText("臺", replacementRange: .notFound)
        documentBView.updateRepresentedTextView(
            editorFixture.scrollView,
            coordinator: editorFixture.coordinator
        )

        XCTAssertEqual(sessionA.text, sourceA + "臺")
        XCTAssertEqual(sessionA.version, 1)
        XCTAssertFalse(sessionA.isDirty)
        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), sourceA + "臺")
        XCTAssertEqual(sessionB.text, sourceB)
        XCTAssertEqual(sessionB.version, 0)
        XCTAssertNil(appState.retiredEditorDocumentBindings[bindingA.id])
        XCTAssertNil(appState.editorDocumentBindingIDs[ObjectIdentifier(sessionA)])
        XCTAssertNil(appState.editorDocumentBindingSessions[bindingA.id])
        XCTAssertTrue(appState.installedEditorDocumentBindingLease?.session === sessionB)
        bindingA.onLifecycle(.revoked(bindingA.id))
        XCTAssertTrue(appState.installedEditorDocumentBindingLease?.session === sessionB)
        XCTAssertNil(appState.retiredEditorDocumentBindings[bindingA.id])
    }

    // swiftlint:disable:next function_body_length
    func testWorkspaceToWorkspaceRetainsExactAnchoredBindingUntilDestinationInstalls() async throws {
        let workspaceA = try makeTemporaryDirectory()
        let workspaceB = try makeTemporaryDirectory()
        let documentAURL = workspaceA.appendingPathComponent("a.md")
        let documentBURL = workspaceB.appendingPathComponent("b.md")
        let sourceA = "A composition: "
        let sourceB = "B workspace"
        try sourceA.write(to: documentAURL, atomically: true, encoding: .utf8)
        try sourceB.write(to: documentBURL, atomically: true, encoding: .utf8)
        let sessionA = DocumentSession(text: sourceA, url: documentAURL, fileKind: .markdown)
        let scanner = ImmediateWorkspaceDirectoryScanner(
            snapshot: snapshot(paths: ["b.md"], rootURL: workspaceB)
        )
        let appState = AppState(
            currentDocument: sessionA,
            directoryScanner: scanner,
            shouldRestoreLastOpenedFile: false
        )
        configureWorkspace(
            appState,
            rootURL: workspaceA,
            paths: ["a.md"],
            currentSession: sessionA,
            retainSecurityScope: true
        )
        let rootAuthorityA = try XCTUnwrap(appState.workspaceSearchRootAuthority)
        let locationA = try rootAuthorityA.canonicalizedLocation(forFileURL: documentAURL)
        try appState.activateAnchoredFileSession(at: locationA)
        let anchoredBindingA = try XCTUnwrap(
            appState.anchoredSessionFileBinding(for: sessionA)
        )

        var selectionA: NSRange? = NSRange(location: (sourceA as NSString).length, length: 0)
        var selectionB: NSRange? = NSRange(location: 0, length: 0)
        let bindingA = appState.editorDocumentBinding(for: sessionA)
        let documentAView = MarkdownTextView(
            text: bindingA.text,
            styledText: nil,
            selection: Binding(get: { selectionA }, set: { selectionA = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentAURL),
            documentBindingID: bindingA.id,
            onDocumentBindingLifecycle: bindingA.onLifecycle
        )
        let editorFixture = try makeEditorBridgeFixture(representable: documentAView, source: sourceA)
        defer {
            editorFixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(
                editorFixture.scrollView,
                coordinator: editorFixture.coordinator
            )
            appState.workspaceWatcher?.stop()
            try? FileManager.default.removeItem(at: workspaceA)
            try? FileManager.default.removeItem(at: workspaceB)
        }

        XCTAssertTrue(editorFixture.window.makeFirstResponder(editorFixture.textView))
        editorFixture.textView.textSelection = selectionA ?? .notFound
        editorFixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )

        try appState.openWorkspace(url: workspaceB, rememberAsLastOpened: false)
        await appState.workspaceReloadTask?.value
        let sessionB = appState.currentDocument
        XCTAssertEqual(sessionB.fileURL?.standardizedFileURL, documentBURL.standardizedFileURL)
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: sessionA), anchoredBindingA)
        XCTAssertEqual(
            appState.anchoredSessionFileBinding(for: sessionB)?.location.rootAuthority.canonicalRootURL,
            workspaceB.standardizedFileURL
        )
        let retirement = try XCTUnwrap(appState.retiredEditorDocumentBindings[bindingA.id])
        XCTAssertEqual(retirement.securityScopedAuthority?.url.standardizedFileURL, workspaceA.standardizedFileURL)
        XCTAssertEqual(appState.workspaceAccess?.url.standardizedFileURL, workspaceB.standardizedFileURL)

        let bindingB = appState.editorDocumentBinding(for: sessionB)
        let documentBView = MarkdownTextView(
            text: bindingB.text,
            styledText: nil,
            selection: Binding(get: { selectionB }, set: { selectionB = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentBURL),
            documentBindingID: bindingB.id,
            onDocumentBindingLifecycle: bindingB.onLifecycle
        )
        documentBView.updateRepresentedTextView(
            editorFixture.scrollView,
            coordinator: editorFixture.coordinator
        )
        XCTAssertTrue(appState.installedEditorDocumentBindingLease?.session === sessionA)

        editorFixture.textView.insertText("臺", replacementRange: .notFound)
        documentBView.updateRepresentedTextView(
            editorFixture.scrollView,
            coordinator: editorFixture.coordinator
        )

        XCTAssertEqual(sessionA.text, sourceA + "臺")
        XCTAssertEqual(sessionA.version, 1)
        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), sourceA + "臺")
        XCTAssertEqual(sessionB.text, sourceB)
        XCTAssertNil(appState.retiredEditorDocumentBindings[bindingA.id])
        XCTAssertTrue(appState.installedEditorDocumentBindingLease?.session === sessionB)
    }

    // swiftlint:disable:next function_body_length
    func testDestinationOpenFailureKeepsRetiredAuthorityUntilTeardownCompletesSave() async throws {
        let workspaceA = try makeTemporaryDirectory()
        let workspaceB = try makeTemporaryDirectory()
        let documentAURL = workspaceA.appendingPathComponent("a.md")
        let missingDestinationURL = workspaceB.appendingPathComponent("missing.md")
        let sourceA = "A composition: "
        try sourceA.write(to: documentAURL, atomically: true, encoding: .utf8)
        let sessionA = DocumentSession(text: sourceA, url: documentAURL, fileKind: .markdown)
        let scanner = ImmediateWorkspaceDirectoryScanner(
            snapshot: snapshot(paths: ["missing.md"], rootURL: workspaceB)
        )
        let appState = AppState(
            currentDocument: sessionA,
            directoryScanner: scanner,
            shouldRestoreLastOpenedFile: false
        )
        configureWorkspace(
            appState,
            rootURL: workspaceA,
            paths: ["a.md"],
            currentSession: sessionA,
            retainSecurityScope: true
        )

        var selectionA: NSRange? = NSRange(location: (sourceA as NSString).length, length: 0)
        let bindingA = appState.editorDocumentBinding(for: sessionA)
        let documentAView = MarkdownTextView(
            text: bindingA.text,
            styledText: nil,
            selection: Binding(get: { selectionA }, set: { selectionA = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentAURL),
            documentBindingID: bindingA.id,
            onDocumentBindingLifecycle: bindingA.onLifecycle
        )
        let editorFixture = try makeEditorBridgeFixture(representable: documentAView, source: sourceA)
        defer {
            editorFixture.window.orderOut(nil)
            appState.workspaceWatcher?.stop()
            try? FileManager.default.removeItem(at: workspaceA)
            try? FileManager.default.removeItem(at: workspaceB)
        }

        XCTAssertTrue(editorFixture.window.makeFirstResponder(editorFixture.textView))
        editorFixture.textView.textSelection = selectionA ?? .notFound
        editorFixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )

        try appState.openWorkspace(url: workspaceB, rememberAsLastOpened: false)
        await appState.workspaceReloadTask?.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDestinationURL.path))
        XCTAssertTrue(appState.currentDocument === sessionA)
        XCTAssertTrue(appState.installedEditorDocumentBindingLease?.session === sessionA)
        let retirement = try XCTUnwrap(appState.retiredEditorDocumentBindings[bindingA.id])
        XCTAssertEqual(retirement.securityScopedAuthority?.url.standardizedFileURL, workspaceA.standardizedFileURL)
        XCTAssertTrue(retirement.isAwaitingBindingEnd)

        try Data([0xFF]).write(to: missingDestinationURL)
        XCTAssertThrowsError(
            try appState.open(
                url: missingDestinationURL,
                rememberAsLastOpened: false,
                preserveWorkspace: false
            )
        )
        let retirementAfterRepeatedFailure = try XCTUnwrap(
            appState.retiredEditorDocumentBindings[bindingA.id]
        )
        XCTAssertTrue(retirementAfterRepeatedFailure.session === sessionA)
        XCTAssertEqual(
            retirementAfterRepeatedFailure.securityScopedAuthority?.url.standardizedFileURL,
            workspaceA.standardizedFileURL
        )
        XCTAssertTrue(retirementAfterRepeatedFailure.isAwaitingBindingEnd)
        XCTAssertNil(appState.workspaceRootURL)

        editorFixture.textView.insertText("臺", replacementRange: .notFound)
        XCTAssertEqual(sessionA.text, sourceA + "臺")
        XCTAssertEqual(sessionA.version, 1)
        XCTAssertTrue(sessionA.isDirty)
        XCTAssertNotNil(appState.retiredEditorDocumentBindings[bindingA.id])

        MarkdownTextView.dismantleNSView(
            editorFixture.scrollView,
            coordinator: editorFixture.coordinator
        )
        XCTAssertNil(appState.installedEditorDocumentBindingLease)
        XCTAssertNil(appState.retiredEditorDocumentBindings[bindingA.id])
        XCTAssertNil(appState.editorDocumentBindingIDs[ObjectIdentifier(sessionA)])
        XCTAssertNil(appState.editorDocumentBindingSessions[bindingA.id])
        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), sourceA + "臺")
        XCTAssertFalse(sessionA.isDirty)
    }

    func testDebounceStartsOnlyLatestQueryWithIncreasingGeneration() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "first second"],
            debounceNanoseconds: 50_000_000
        )
        defer { cleanUp(fixture) }

        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "first"))
        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(
            pattern: "second",
            caseSensitivity: .sensitive,
            wholeWord: true
        ))

        try await waitUntil("latest debounced search starts") { provider.requests.count == 1 }
        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(request.query.pattern, "second")
        XCTAssertEqual(request.query.caseSensitivity, .sensitive)
        XCTAssertTrue(request.query.wholeWord)
        XCTAssertEqual(request.queryGeneration, 2)
        XCTAssertEqual(fixture.appState.workspaceSearchState.phase, .searching)
    }

    func testSearchDoesNotPrepareRequestWithAuthorityFromAnotherWorkspace() throws {
        let rootA = try makeTemporaryDirectory()
        let rootB = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let provider = ControlledWorkspaceSearchStreamProvider()
        let appState = AppState(
            workspaceSearchStreamProvider: provider,
            workspaceSearchDebounceNanoseconds: 0,
            shouldRestoreLastOpenedFile: false
        )
        appState.workspaceRootURL = rootB
        appState.workspaceSnapshot = snapshot(paths: ["a.md"], rootURL: rootA)
        appState.workspaceSearchRootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: rootA
        )
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1

        appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "needle"))

        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertEqual(appState.workspaceSearchState.phase, .idle)
    }

    func testReplacementCancelsConsumingTaskTerminatesProducerAndOldCleanupCannotClearNewResults() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "alpha", "b.md": "beta"]
        )
        defer { cleanUp(fixture) }

        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "alpha"))
        try await waitUntil("first search starts") { provider.requests.count == 1 }
        let firstRequest = provider.requests[0]
        provider.yield(
            .fileResult(context(for: firstRequest), result(path: "a.md", text: "alpha", needle: "alpha")),
            to: 0
        )
        try await waitUntil("first partial result applies") {
            fixture.appState.workspaceSearchState.fileResults.map(\.relativePath) == ["a.md"]
        }

        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "beta"))
        try await waitUntil("first producer terminates and replacement starts") {
            provider.terminatedSubscriptionIndices.contains(0) && provider.requests.count == 2
        }
        let secondRequest = provider.requests[1]
        provider.yield(
            .fileResult(context(for: secondRequest), result(path: "b.md", text: "beta", needle: "beta")),
            to: 1
        )
        try await waitUntil("replacement partial result applies") {
            fixture.appState.workspaceSearchState.fileResults.map(\.relativePath) == ["b.md"]
        }
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(fixture.appState.workspaceSearchState.activeQuery?.pattern, "beta")
        XCTAssertEqual(fixture.appState.workspaceSearchState.queryGeneration, secondRequest.queryGeneration)
        XCTAssertNotNil(fixture.appState.workspaceSearchTask)
    }

    func testWorkspaceCloseCancelsActiveSearch() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(provider: provider, files: ["a.md": "alpha"])
        defer { cleanUp(fixture) }
        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "alpha"))
        try await waitUntil("search starts") { provider.requests.count == 1 }

        fixture.appState.closeWorkspace()

        try await waitUntil("close terminates producer") {
            provider.terminatedSubscriptionIndices.contains(0)
        }
        XCTAssertEqual(fixture.appState.workspaceSearchState.phase, .idle)
        XCTAssertNil(fixture.appState.workspaceRootURL)
    }

    func testWorkspaceSwitchCancelsActiveSearch() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let scanner = ImmediateWorkspaceDirectoryScanner(snapshot: WorkspaceFileSnapshot(entries: []))
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "alpha"],
            directoryScanner: scanner
        )
        let secondRoot = try makeTemporaryDirectory()
        defer {
            fixture.appState.closeWorkspace()
            cleanUp(fixture)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "alpha"))
        try await waitUntil("search starts") { provider.requests.count == 1 }

        try fixture.appState.openWorkspace(url: secondRoot, rememberAsLastOpened: false)

        try await waitUntil("switch terminates producer") {
            provider.terminatedSubscriptionIndices.contains(0)
        }
        XCTAssertEqual(
            fixture.appState.workspaceRootURL?.standardizedFileURL,
            secondRoot.standardizedFileURL
        )
        XCTAssertEqual(fixture.appState.workspaceSearchState.phase, .idle)
    }

    func testGenerationAdvanceAndTeardownCancelActiveWork() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(provider: provider, files: ["a.md": "alpha"])
        defer { cleanUp(fixture) }
        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "alpha"))
        try await waitUntil("first search starts") { provider.requests.count == 1 }

        _ = fixture.appState.advanceWorkspaceGeneration()

        try await waitUntil("generation advance terminates producer") {
            provider.terminatedSubscriptionIndices.contains(0)
        }
        XCTAssertEqual(fixture.appState.workspaceSearchState.phase, .idle)

        // Until a new snapshot/authority pair is installed for the advanced generation, search
        // must not reuse the old capture labeled as the new generation.
        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "alpha"))
        XCTAssertTrue(provider.requests.count == 1)
        XCTAssertEqual(fixture.appState.workspaceSearchState.phase, .idle)
        XCTAssertNil(fixture.appState.workspaceSearchState.activeQuery)

        fixture.appState.workspaceInstalledCaptureGeneration = fixture.appState.workspaceGeneration
        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "alpha"))
        try await waitUntil("second search starts after capture reinstall") {
            provider.requests.count == 2
        }
        fixture.appState.teardownWorkspaceSearch()
        try await waitUntil("teardown terminates producer") {
            provider.terminatedSubscriptionIndices.contains(1)
        }
        XCTAssertEqual(fixture.appState.workspaceSearchState.phase, .idle)
        XCTAssertNil(fixture.appState.workspaceSearchState.activeQuery)
    }

    func testEmptyQueryCancelsActiveSearchAndReturnsToIdle() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(provider: provider, files: ["a.md": "alpha"])
        defer { cleanUp(fixture) }
        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "alpha"))
        try await waitUntil("search starts") { provider.requests.count == 1 }

        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: ""))

        try await waitUntil("empty query terminates producer") {
            provider.terminatedSubscriptionIndices.contains(0)
        }
        XCTAssertEqual(fixture.appState.workspaceSearchState.phase, .idle)
        XCTAssertNil(fixture.appState.workspaceSearchState.activeQuery)
        XCTAssertTrue(fixture.appState.workspaceSearchState.fileResults.isEmpty)
    }

    func testLateEventsFromStaleRootWorkspaceAndQueryContextsCannotMutateState() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(provider: provider, files: ["a.md": "alpha"])
        defer { cleanUp(fixture) }
        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "alpha"))
        try await waitUntil("search starts") { provider.requests.count == 1 }
        let request = provider.requests[0]
        let activeContext = context(for: request)
        let staleRoot = WorkspaceSearchContext(
            rootIdentity: "\(activeContext.rootIdentity)-stale",
            workspaceGeneration: activeContext.workspaceGeneration,
            queryGeneration: activeContext.queryGeneration
        )
        let staleWorkspace = WorkspaceSearchContext(
            rootIdentity: activeContext.rootIdentity,
            workspaceGeneration: activeContext.workspaceGeneration + 1,
            queryGeneration: activeContext.queryGeneration
        )
        let staleQuery = WorkspaceSearchContext(
            rootIdentity: activeContext.rootIdentity,
            workspaceGeneration: activeContext.workspaceGeneration,
            queryGeneration: activeContext.queryGeneration + 1
        )

        provider.yield(.fileResult(staleRoot, result(path: "a.md", text: "alpha", needle: "alpha")), to: 0)
        provider.yield(
            .progress(staleWorkspace, WorkspaceSearchProgress(completedFileCount: 1, candidateFileCount: 1)),
            to: 0
        )
        provider.yield(
            .skippedFile(staleQuery, WorkspaceSearchSkippedFile(relativePath: "a.md", reason: .unreadable)),
            to: 0
        )
        provider.yield(.completed(staleQuery, summary()), to: 0)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertTrue(fixture.appState.workspaceSearchState.fileResults.isEmpty)
        XCTAssertTrue(fixture.appState.workspaceSearchState.skippedFiles.isEmpty)
        XCTAssertNil(fixture.appState.workspaceSearchState.progress)
        XCTAssertNil(fixture.appState.workspaceSearchState.summary)
        XCTAssertEqual(fixture.appState.workspaceSearchState.phase, .searching)

        let progress = WorkspaceSearchProgress(completedFileCount: 1, candidateFileCount: 1)
        provider.yield(.progress(activeContext, progress), to: 0)
        try await waitUntil("active progress applies") {
            fixture.appState.workspaceSearchState.progress == progress
        }
    }

    func testPartialProgressSkippedCompletionAndTruncationMapDeterministically() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "alpha", "b.md": "beta"]
        )
        defer { cleanUp(fixture) }
        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "a"))
        try await waitUntil("search starts") { provider.requests.count == 1 }
        let activeContext = context(for: provider.requests[0])
        let skipped = WorkspaceSearchSkippedFile(relativePath: "z.md", reason: .unreadable)
        let progress = WorkspaceSearchProgress(completedFileCount: 2, candidateFileCount: 2)
        let completedSummary = summary(
            candidateFileCount: 2,
            searchedFileCount: 2,
            skippedFileCount: 1,
            totalMatchCount: 2,
            truncatedFilePaths: ["b.md"],
            isGloballyTruncated: true,
            skippedFiles: [skipped],
            omittedSkippedFileCount: 2
        )

        provider.yield(
            .fileResult(activeContext, result(path: "b.md", text: "beta", needle: "a", truncated: true)),
            to: 0
        )
        provider.yield(.fileResult(activeContext, result(path: "a.md", text: "alpha", needle: "a")), to: 0)
        provider.yield(.skippedFile(activeContext, skipped), to: 0)
        provider.yield(.progress(activeContext, progress), to: 0)
        provider.yield(.completed(activeContext, completedSummary), to: 0)
        provider.finish(0)

        try await waitUntil("completion maps") {
            fixture.appState.workspaceSearchState.phase == .completed
        }
        let state = fixture.appState.workspaceSearchState
        XCTAssertEqual(state.fileResults.map(\.relativePath), ["a.md", "b.md"])
        XCTAssertEqual(state.skippedFiles, [skipped])
        XCTAssertEqual(state.progress, progress)
        XCTAssertEqual(state.summary, completedSummary)
        XCTAssertTrue(state.isTruncated)
        XCTAssertTrue(state.isGloballyTruncated)
        XCTAssertEqual(state.truncatedFilePaths, ["b.md"])
    }

    func testValidationAndServiceFailureRemainDistinctAndFailureKeepsPartialResults() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(provider: provider, files: ["a.md": "alpha"])
        defer { cleanUp(fixture) }
        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "bad\nquery"))
        try await waitUntil("validation search starts") { provider.requests.count == 1 }
        provider.yield(
            .validationFailure(context(for: provider.requests[0]), .newlineInQuery),
            to: 0
        )
        provider.finish(0)
        try await waitUntil("validation maps") {
            fixture.appState.workspaceSearchState.phase == .validationFailure(.newlineInQuery)
        }

        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "alpha"))
        try await waitUntil("failure search starts") { provider.requests.count == 2 }
        let activeContext = context(for: provider.requests[1])
        provider.yield(
            .fileResult(activeContext, result(path: "a.md", text: "alpha", needle: "alpha")),
            to: 1
        )
        provider.yield(.failed(activeContext, .unexpectedProducerFailure), to: 1)
        provider.finish(1)
        try await waitUntil("service failure maps") {
            fixture.appState.workspaceSearchState.phase == .serviceFailure(.unexpectedProducerFailure)
        }

        XCTAssertEqual(fixture.appState.workspaceSearchState.fileResults.map(\.relativePath), ["a.md"])
        XCTAssertNil(fixture.appState.workspaceSearchState.summary)
    }

    // swiftlint:disable:next function_body_length
    func testDirtyOverlayCaptureIsImmutableDeduplicatedAndExcludesIneligibleSessions() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: [
                "clean.md": "clean",
                "current.md": "current disk",
                "detached.md": "detached disk",
                "warm.mdx": "warm disk",
            ],
            currentPath: "current.md"
        )
        let outsideRoot = try makeTemporaryDirectory()
        defer {
            cleanUp(fixture)
            try? FileManager.default.removeItem(at: outsideRoot)
        }
        let appState = fixture.appState
        let currentURL = fixture.rootURL.appendingPathComponent("current.md")
        let warmURL = fixture.rootURL.appendingPathComponent("warm.mdx")
        let cleanURL = fixture.rootURL.appendingPathComponent("clean.md")
        let detachedURL = fixture.rootURL.appendingPathComponent("detached.md")
        let nonMarkdownURL = fixture.rootURL.appendingPathComponent("notes.txt")
        let outsideURL = outsideRoot.appendingPathComponent("outside.md")
        try "outside".write(to: outsideURL, atomically: true, encoding: .utf8)
        try "notes".write(to: nonMarkdownURL, atomically: true, encoding: .utf8)

        appState.replaceDocumentText("current dirty")
        let warm = DocumentSession(text: "warm disk", url: warmURL, fileKind: .mdx)
        warm.replaceText("warm dirty")
        let clean = DocumentSession(text: "clean", url: cleanURL, fileKind: .markdown)
        let detached = DocumentSession(text: "detached disk", url: detachedURL, fileKind: .markdown)
        detached.replaceText("detached dirty")
        let nonMarkdown = DocumentSession(text: "notes", url: nonMarkdownURL, fileKind: .markdown)
        nonMarkdown.replaceText("notes dirty")
        let outside = DocumentSession(text: "outside", url: outsideURL, fileKind: .markdown)
        outside.replaceText("outside dirty")
        let aliasURL = fixture.rootURL.appendingPathComponent("current-alias.md")
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: currentURL)
        let duplicatePath = DocumentSession(text: "duplicate", url: aliasURL, fileKind: .markdown)
        duplicatePath.replaceText("duplicate dirty")

        appState.sessionCache[warmURL] = warm
        appState.sessionCache[cleanURL] = clean
        appState.sessionCache[detachedURL] = detached
        appState.sessionCache[nonMarkdownURL] = nonMarkdown
        appState.sessionCache[outsideURL] = outside
        appState.sessionCache[aliasURL] = duplicatePath
        appState.sessionCache[currentURL] = appState.currentDocument
        appState.detachedSessionURLs.insert(detachedURL.standardizedFileURL)

        appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "dirty"))
        try await waitUntil("overlay request starts") { provider.requests.count == 1 }
        let request = provider.requests[0]
        XCTAssertEqual(request.dirtyOverlays.overlays.map(\.relativePath), ["current.md", "warm.mdx"])
        XCTAssertEqual(request.dirtyOverlays.overlays.map(\.text), ["current dirty", "warm dirty"])

        appState.replaceDocumentText("current changed later")
        warm.replaceText("warm changed later")
        XCTAssertEqual(request.dirtyOverlays.overlays.map(\.text), ["current dirty", "warm dirty"])

        let singleFileProvider = ControlledWorkspaceSearchStreamProvider()
        let singleFile = DocumentSession(text: "single", url: outsideURL, fileKind: .markdown)
        singleFile.replaceText("single dirty")
        let singleFileState = AppState(
            currentDocument: singleFile,
            workspaceSearchStreamProvider: singleFileProvider,
            workspaceSearchDebounceNanoseconds: 0
        )
        singleFileState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "dirty"))
        XCTAssertTrue(singleFileProvider.requests.isEmpty)
        XCTAssertEqual(singleFileState.workspaceSearchState.phase, .idle)
    }

    // swiftlint:disable:next function_body_length
    func testCanonicalSymlinkIdentityReusesDirtySessionAcrossSearchTreeAndActivation() async throws {
        let rootURL = try makeTemporaryDirectory()
        let outsideRoot = try makeTemporaryDirectory()
        let targetURL = rootURL.appendingPathComponent("target.md")
        let aliasURL = rootURL.appendingPathComponent("alias.md")
        let outsideURL = outsideRoot.appendingPathComponent("outside.md")
        let escapeURL = rootURL.appendingPathComponent("escape.md")
        try "stale disk text".write(to: targetURL, atomically: true, encoding: .utf8)
        try "outside needle".write(to: outsideURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: targetURL)
        try FileManager.default.createSymbolicLink(at: escapeURL, withDestinationURL: outsideURL)
        let workspaceSnapshot = snapshot(
            paths: ["alias.md", "escape.md", "target.md"],
            rootURL: rootURL
        )
        let provider = RecordingWorkspaceSearchStreamProvider()
        let appState = AppState(
            workspaceSearchStreamProvider: provider,
            workspaceSearchDebounceNanoseconds: 0,
            shouldRestoreLastOpenedFile: false
        )
        appState.workspaceRootURL = rootURL
        appState.workspaceSnapshot = workspaceSnapshot
        appState.workspaceSearchRootAuthority = try WorkspaceFileSystemRootAuthority(
            rootURL: rootURL
        )
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.workspaceTree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: workspaceSnapshot,
            options: .init(showAllFiles: false)
        )
        defer {
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
            appState.teardownWorkspaceSearch()
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: outsideRoot)
        }

        try appState.activateFileSession(url: aliasURL)
        let aliasedSession = appState.currentDocument
        let canonicalTargetURL = targetURL.standardizedFileURL.resolvingSymlinksInPath()
        XCTAssertEqual(aliasedSession.fileURL, canonicalTargetURL)
        XCTAssertTrue(appState.sessionCache[canonicalTargetURL] === aliasedSession)
        XCTAssertNil(appState.sessionCache[aliasURL.standardizedFileURL])
        XCTAssertEqual(appState.workspaceTree?.selectedNode?.relativePath, "target.md")
        XCTAssertEqual(
            appState.activeEditorDocumentIdentity,
            AppState.editorDocumentIdentity(for: canonicalTargetURL)
        )

        let dirtyText = "# Dirty Alias\nunsaved needle 🧪"
        appState.replaceDocumentText(dirtyText, in: aliasedSession)
        appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "needle"))
        try await waitUntil("canonical symlink search completes") {
            appState.workspaceSearchState.phase == .completed
        }

        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(request.dirtyOverlays.overlays.map(\.relativePath), ["target.md"])
        XCTAssertEqual(request.dirtyOverlays.overlays.map(\.text), [dirtyText])
        let fileResult = try XCTUnwrap(appState.workspaceSearchState.fileResults.first)
        XCTAssertEqual(appState.workspaceSearchState.fileResults.map(\.relativePath), ["target.md"])
        XCTAssertEqual(
            fileResult.contentFingerprint,
            WorkspaceSearchContentFingerprint(text: dirtyText)
        )
        XCTAssertEqual(
            appState.workspaceSearchState.skippedFiles,
            [WorkspaceSearchSkippedFile(relativePath: "escape.md", reason: .symlinkEscape)]
        )
        XCTAssertEqual(appState.workspaceSearchState.summary?.candidateFileCount, 2)

        let match = try XCTUnwrap(fileResult.matches.first)
        appState.activateWorkspaceSearchResult(
            context: context(for: request),
            fileResult: fileResult,
            match: match
        )
        let navigation = try navigationRequest(from: appState.editorNavigationCommand)
        XCTAssertTrue(appState.currentDocument === aliasedSession)
        XCTAssertEqual(appState.workspaceTree?.selectedNode?.relativePath, "target.md")
        XCTAssertEqual(navigation.documentIdentity, appState.activeEditorDocumentIdentity)
        XCTAssertEqual(navigation.selection, match.range)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(provider.requests.count, 1, "fingerprint arbitration must not restart")

        try appState.activateFileSession(url: targetURL)
        XCTAssertTrue(appState.currentDocument === aliasedSession)
        XCTAssertThrowsError(try appState.activateFileSession(url: escapeURL))
        XCTAssertTrue(appState.currentDocument === aliasedSession)
    }

    func testDirtyOverlayBoundToPreviousRootAuthorityCannotEnterReplacementWorkspace() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let movedA = parent.appendingPathComponent("captured-A", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staleURL = root.appendingPathComponent("stale.md").standardizedFileURL
        try "disk A".write(to: staleURL, atomically: true, encoding: .utf8)
        let authorityA = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let locationA = try authorityA.location(relativePath: "stale.md")
        let loadedA = try MarkdownFileStore().loadResult(at: locationA)
        let staleSession = DocumentSession(
            text: "dirty A overlay",
            url: staleURL,
            fileKind: .markdown,
            isDirty: true
        )

        try FileManager.default.moveItem(at: root, to: movedA)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "disk B".write(to: staleURL, atomically: true, encoding: .utf8)
        let authorityB = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authorityB
        appState.workspaceGeneration = 2
        appState.workspaceInstalledCaptureGeneration = 2
        appState.sessionCache[staleURL] = staleSession
        appState.anchoredSessionFileBindings[ObjectIdentifier(staleSession)] =
            AnchoredWorkspaceSessionFileBinding(
                location: locationA,
                identity: loadedA.metadata.identity,
                sha256Digest: loadedA.sha256Digest
            )

        let overlays = try await appState.workspaceSearchDirtyOverlays(rootAuthority: authorityB)

        XCTAssertTrue(overlays.overlays.isEmpty)
    }

    func testMatchingFingerprintSelectsActivatesAndEmitsIncreasingExactNavigation() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "alpha", "b.md": "before needle after"],
            currentPath: "a.md"
        )
        defer { cleanUp(fixture) }
        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "needle"))
        try await waitUntil("search starts") { provider.requests.count == 1 }
        let request = provider.requests[0]
        let fileResult = result(path: "b.md", text: "before needle after", needle: "needle")
        let match = try XCTUnwrap(fileResult.matches.first)
        provider.yield(.fileResult(context(for: request), fileResult), to: 0)
        try await waitUntil("result applies") {
            fixture.appState.workspaceSearchState.fileResults == [fileResult]
        }

        fixture.appState.activateWorkspaceSearchResult(
            context: context(for: request),
            fileResult: fileResult,
            match: match
        )
        let firstRequest = try navigationRequest(from: fixture.appState.editorNavigationCommand)
        XCTAssertEqual(fixture.appState.workspaceTree?.selectedNode?.relativePath, "b.md")
        XCTAssertEqual(
            fixture.appState.currentDocument.fileURL?.standardizedFileURL,
            fixture.rootURL.appendingPathComponent("b.md").standardizedFileURL
        )
        XCTAssertEqual(firstRequest.selection, match.range)
        XCTAssertEqual(firstRequest.documentIdentity, fixture.appState.activeEditorDocumentIdentity)

        fixture.appState.activateWorkspaceSearchResult(
            context: context(for: request),
            fileResult: fileResult,
            match: match
        )
        let secondRequest = try navigationRequest(from: fixture.appState.editorNavigationCommand)
        XCTAssertGreaterThan(secondRequest.id, firstRequest.id)
        XCTAssertEqual(secondRequest.selection, match.range)

        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "other"))
        guard case let .cancel(cancellationID)? = fixture.appState.editorNavigationCommand else {
            return XCTFail("Expected query replacement to cancel pending editor navigation")
        }
        XCTAssertGreaterThan(cancellationID, secondRequest.id)
    }

    func testSearchActivationPostcheckDoesNotResolveAReplacementSymlinkToB() async throws {
        let scenario = try await makeAcceptedActivationScenario()
        let outsideRoot = try makeTemporaryDirectory()
        defer {
            cleanUp(scenario.fixture)
            try? FileManager.default.removeItem(at: outsideRoot)
        }
        let targetURL = scenario.fixture.rootURL.appendingPathComponent("b.md")
        let outsideURL = outsideRoot.appendingPathComponent("outside.md")
        try "outside B".write(to: outsideURL, atomically: true, encoding: .utf8)
        scenario.fixture.appState.workspaceSearchPostActivationHook = {
            scenario.fixture.appState.workspaceSearchPostActivationHook = nil
            try FileManager.default.removeItem(at: targetURL)
            try FileManager.default.createSymbolicLink(at: targetURL, withDestinationURL: outsideURL)
        }

        scenario.fixture.appState.activateWorkspaceSearchResult(
            context: scenario.context,
            fileResult: scenario.fileResult,
            match: scenario.match
        )

        XCTAssertEqual(scenario.fixture.appState.currentDocument.text, "beta")
        XCTAssertEqual(
            scenario.fixture.appState.workspaceTree?.selectedNode?.relativePath,
            "b.md"
        )
        let navigation = try navigationRequest(
            from: scenario.fixture.appState.editorNavigationCommand
        )
        XCTAssertEqual(navigation.documentIdentity, scenario.fixture.appState.activeEditorDocumentIdentity)
        XCTAssertEqual(navigation.selection, scenario.match.range)
    }

    func testByteDifferentCanonicalEquivalentFingerprintCancelsNavigationAndRefreshesFreshOverlay() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let diskText = "cafe\u{0301} needle"
        let liveText = "caf\u{00E9} needle"
        let fixture = try makeFixture(
            provider: provider,
            files: ["post.md": diskText],
            currentPath: "post.md"
        )
        defer { cleanUp(fixture) }
        fixture.appState.replaceDocumentText(liveText)
        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "needle"))
        try await waitUntil("stale-result search starts") { provider.requests.count == 1 }
        let firstRequest = provider.requests[0]
        let staleResult = result(path: "post.md", text: diskText, needle: "needle")
        let staleMatch = try XCTUnwrap(staleResult.matches.first)
        provider.yield(.fileResult(context(for: firstRequest), staleResult), to: 0)
        try await waitUntil("stale result applies") {
            fixture.appState.workspaceSearchState.fileResults == [staleResult]
        }

        fixture.appState.activateWorkspaceSearchResult(
            context: context(for: firstRequest),
            fileResult: staleResult,
            match: staleMatch
        )

        guard case .cancel? = fixture.appState.editorNavigationCommand else {
            return XCTFail("Expected stale fingerprint to emit editor cancellation")
        }
        try await waitUntil("fresh-overlay search restarts") { provider.requests.count == 2 }
        let refreshedRequest = provider.requests[1]
        XCTAssertGreaterThan(refreshedRequest.queryGeneration, firstRequest.queryGeneration)
        let refreshedOverlay = try XCTUnwrap(refreshedRequest.dirtyOverlays.overlays.first)
        XCTAssertEqual(Array(refreshedOverlay.text.utf8), Array(liveText.utf8))
        XCTAssertNotEqual(
            WorkspaceSearchContentFingerprint(text: diskText).utf8ByteCount,
            WorkspaceSearchContentFingerprint(text: liveText).utf8ByteCount
        )
    }

    func testStaleActivationContextDoesNotCancelUnrelatedPendingNavigation() async throws {
        let scenario = try await makeAcceptedActivationScenario()
        defer { cleanUp(scenario.fixture) }
        let olderNavigation = seedOlderPendingNavigation(in: scenario.fixture.appState)
        let staleContext = WorkspaceSearchContext(
            rootIdentity: scenario.context.rootIdentity,
            workspaceGeneration: scenario.context.workspaceGeneration,
            queryGeneration: scenario.context.queryGeneration + 1
        )

        scenario.fixture.appState.activateWorkspaceSearchResult(
            context: staleContext,
            fileResult: scenario.fileResult,
            match: scenario.match
        )

        XCTAssertEqual(
            scenario.fixture.appState.editorNavigationCommand,
            .navigate(olderNavigation)
        )
        XCTAssertEqual(scenario.fixture.appState.currentDocument.fileURL?.lastPathComponent, "a.md")
    }

    func testAcceptedActivationMissingNodeSupersedesOlderNavigation() async throws {
        let scenario = try await makeAcceptedActivationScenario()
        defer { cleanUp(scenario.fixture) }
        let olderNavigation = seedOlderPendingNavigation(in: scenario.fixture.appState)
        let currentOnly = snapshot(paths: ["a.md"], rootURL: scenario.fixture.rootURL)
        scenario.fixture.appState.workspaceTree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: currentOnly,
            options: .init(showAllFiles: false)
        )

        activateAndAssertNewerCancellation(scenario, olderThan: olderNavigation.id)
    }

    func testAcceptedActivationOpenFailureSupersedesOlderNavigation() async throws {
        let scenario = try await makeAcceptedActivationScenario()
        defer { cleanUp(scenario.fixture) }
        let olderNavigation = seedOlderPendingNavigation(in: scenario.fixture.appState)
        try FileManager.default.removeItem(
            at: scenario.fixture.rootURL.appendingPathComponent("b.md")
        )

        activateAndAssertNewerCancellation(scenario, olderThan: olderNavigation.id)
    }

    func testAcceptedActivationDetachedTargetSupersedesOlderNavigation() async throws {
        let scenario = try await makeAcceptedActivationScenario()
        defer { cleanUp(scenario.fixture) }
        let olderNavigation = seedOlderPendingNavigation(in: scenario.fixture.appState)
        let targetURL = scenario.fixture.rootURL
            .appendingPathComponent("b.md")
            .standardizedFileURL
        let detachedSession = DocumentSession(
            text: "beta",
            url: targetURL,
            fileKind: .markdown
        )
        scenario.fixture.appState.sessionCache[targetURL] = detachedSession
        scenario.fixture.appState.recordKnownDiskText("beta", for: targetURL)
        scenario.fixture.appState.detachedSessionURLs.insert(targetURL)

        activateAndAssertNewerCancellation(scenario, olderThan: olderNavigation.id)
    }

    func testAcceptedActivationIdentityMismatchSupersedesOlderNavigation() async throws {
        let scenario = try await makeAcceptedActivationScenario()
        defer { cleanUp(scenario.fixture) }
        let olderNavigation = seedOlderPendingNavigation(in: scenario.fixture.appState)
        let targetURL = scenario.fixture.rootURL
            .appendingPathComponent("b.md")
            .standardizedFileURL
        let mismatchedURL = scenario.fixture.rootURL
            .appendingPathComponent("a.md")
            .standardizedFileURL
        let mismatchedSession = DocumentSession(
            text: "alpha",
            url: mismatchedURL,
            fileKind: .markdown
        )
        scenario.fixture.appState.sessionCache[targetURL] = mismatchedSession
        scenario.fixture.appState.recordKnownDiskText("alpha", for: mismatchedURL)

        activateAndAssertNewerCancellation(scenario, olderThan: olderNavigation.id)
    }

    func testAcceptedActivationFingerprintMismatchSupersedesOlderNavigation() async throws {
        let scenario = try await makeAcceptedActivationScenario()
        defer { cleanUp(scenario.fixture) }
        let olderNavigation = seedOlderPendingNavigation(in: scenario.fixture.appState)
        try "changed beta".write(
            to: scenario.fixture.rootURL.appendingPathComponent("b.md"),
            atomically: true,
            encoding: .utf8
        )

        activateAndAssertNewerCancellation(scenario, olderThan: olderNavigation.id)
    }

    func testAcceptedActivationInvalidRangeSupersedesOlderNavigation() async throws {
        var scenario = try await makeAcceptedActivationScenario()
        defer { cleanUp(scenario.fixture) }
        let olderNavigation = seedOlderPendingNavigation(in: scenario.fixture.appState)
        let invalidMatch = TextSearchMatch(
            range: NSRange(location: 999, length: 1),
            line: 1,
            preview: "beta",
            previewMatchRange: NSRange(location: 0, length: 4)
        )
        scenario.fileResult = WorkspaceSearchFileResult(
            relativePath: "b.md",
            contentFingerprint: WorkspaceSearchContentFingerprint(text: "beta"),
            matches: [invalidMatch],
            isTruncated: false
        )
        scenario.match = invalidMatch
        scenario.fixture.appState.workspaceSearchState.fileResults = [scenario.fileResult]

        activateAndAssertNewerCancellation(scenario, olderThan: olderNavigation.id)
    }

    func testUnreadableAcceptedActivationPreservesCurrentWorkAndLeavesCancellationLatest() async throws {
        let scenario = try await makeAcceptedActivationScenario()
        defer { cleanUp(scenario.fixture) }
        let appState = scenario.fixture.appState
        let currentSession = appState.currentDocument
        let currentURL = try XCTUnwrap(currentSession.fileURL?.standardizedFileURL)
        appState.replaceDocumentText("alpha current work", in: currentSession)
        let autosave = try XCTUnwrap(appState.autosaveTask)
        let statistics = try XCTUnwrap(appState.statisticsTask)
        let completion = try XCTUnwrap(appState.completionWorkspaceTask)
        let currentPrompt = AppState.ExternalChangePrompt(fileURL: currentURL)
        appState.externalChangePrompt = currentPrompt
        let olderNavigation = seedOlderPendingNavigation(in: appState)
        let destinationURL = scenario.fixture.rootURL.appendingPathComponent("b.md")
        try FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false)

        scenario.fixture.appState.activateWorkspaceSearchResult(
            context: scenario.context,
            fileResult: scenario.fileResult,
            match: scenario.match
        )

        XCTAssertTrue(appState.currentDocument === currentSession)
        XCTAssertEqual(appState.currentDocument.fileURL?.standardizedFileURL, currentURL)
        XCTAssertEqual(appState.currentDocument.text, "alpha current work")
        XCTAssertFalse(autosave.isCancelled)
        XCTAssertFalse(statistics.isCancelled)
        XCTAssertFalse(completion.isCancelled)
        XCTAssertNotNil(appState.autosaveTask)
        XCTAssertNotNil(appState.statisticsTask)
        XCTAssertNotNil(appState.completionWorkspaceTask)
        XCTAssertEqual(appState.externalChangePrompt, currentPrompt)
        XCTAssertNil(appState.missingFilePrompt)
        guard case let .cancel(cancellationID)? = appState.editorNavigationCommand else {
            return XCTFail("Unreadable activation must leave cancellation latest")
        }
        XCTAssertGreaterThan(cancellationID, olderNavigation.id)
    }

    func testAlreadyCurrentActivationPreservesWorkAndPromptsBeforeExactNavigation() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "alpha"],
            currentPath: "a.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let session = appState.currentDocument
        let currentURL = try XCTUnwrap(session.fileURL?.standardizedFileURL)
        let dirtyText = "alpha current work"
        appState.replaceDocumentText(dirtyText, in: session)
        let autosave = try XCTUnwrap(appState.autosaveTask)
        let statistics = try XCTUnwrap(appState.statisticsTask)
        let completion = try XCTUnwrap(appState.completionWorkspaceTask)
        let currentPrompt = AppState.ExternalChangePrompt(fileURL: currentURL)
        appState.externalChangePrompt = currentPrompt
        appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "alpha"))
        try await waitUntil("current-session search starts") { provider.requests.count == 1 }
        let request = provider.requests[0]
        let fileResult = result(path: "a.md", text: dirtyText, needle: "alpha")
        let match = try XCTUnwrap(fileResult.matches.first)
        provider.yield(.fileResult(context(for: request), fileResult), to: 0)
        try await waitUntil("current-session result applies") {
            appState.workspaceSearchState.fileResults == [fileResult]
        }

        appState.activateWorkspaceSearchResult(
            context: context(for: request),
            fileResult: fileResult,
            match: match
        )

        XCTAssertTrue(appState.currentDocument === session)
        XCTAssertEqual(appState.currentDocument.text, dirtyText)
        XCTAssertFalse(autosave.isCancelled)
        XCTAssertFalse(statistics.isCancelled)
        XCTAssertFalse(completion.isCancelled)
        XCTAssertEqual(appState.externalChangePrompt, currentPrompt)
        let navigation = try navigationRequest(from: appState.editorNavigationCommand)
        XCTAssertEqual(navigation.documentIdentity, appState.activeEditorDocumentIdentity)
        XCTAssertEqual(navigation.selection, match.range)
    }

    func testCloseMissingFileRegistrationRemovalThenDismantleRevokesExactLeaseIdempotently() throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("missing.md")
        let source = "Unsaved missing source"
        try source.write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: source, url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.sessionCache[documentURL.standardizedFileURL] = session
        var selection: NSRange? = NSRange(location: 0, length: 0)
        let binding = appState.editorDocumentBinding(for: session)
        let representable = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentURL),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle
        )
        let editorFixture = try makeEditorBridgeFixture(representable: representable, source: source)
        defer {
            editorFixture.window.orderOut(nil)
            try? FileManager.default.removeItem(at: rootURL)
        }
        XCTAssertTrue(appState.installedEditorDocumentBindingLease?.session === session)

        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: documentURL)
        appState.closeMissingFile()

        XCTAssertNil(appState.editorDocumentBindingIDs[ObjectIdentifier(session)])
        XCTAssertNil(appState.editorDocumentBindingSessions[binding.id])
        XCTAssertTrue(appState.installedEditorDocumentBindingLease?.session === session)
        binding.onLifecycle(.revoked(EditorDocumentBindingID()))
        XCTAssertTrue(appState.installedEditorDocumentBindingLease?.session === session)

        MarkdownTextView.dismantleNSView(
            editorFixture.scrollView,
            coordinator: editorFixture.coordinator
        )
        XCTAssertNil(appState.installedEditorDocumentBindingLease)
        MarkdownTextView.dismantleNSView(
            editorFixture.scrollView,
            coordinator: editorFixture.coordinator
        )
        XCTAssertNil(appState.installedEditorDocumentBindingLease)
        XCTAssertTrue(appState.editorDocumentBindingIDs.isEmpty)
        XCTAssertTrue(appState.editorDocumentBindingSessions.isEmpty)
    }

    private struct AcceptedActivationScenario {
        let fixture: Fixture
        let context: WorkspaceSearchContext
        var fileResult: WorkspaceSearchFileResult
        var match: TextSearchMatch
    }

    private func makeAcceptedActivationScenario() async throws -> AcceptedActivationScenario {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "alpha", "b.md": "beta"],
            currentPath: "a.md"
        )
        fixture.appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "beta"))
        try await waitUntil("accepted activation search starts") { provider.requests.count == 1 }
        let request = provider.requests[0]
        let activeContext = context(for: request)
        let fileResult = result(path: "b.md", text: "beta", needle: "beta")
        let match = try XCTUnwrap(fileResult.matches.first)
        provider.yield(.fileResult(activeContext, fileResult), to: 0)
        try await waitUntil("accepted activation result applies") {
            fixture.appState.workspaceSearchState.fileResults == [fileResult]
        }
        return AcceptedActivationScenario(
            fixture: fixture,
            context: activeContext,
            fileResult: fileResult,
            match: match
        )
    }

    private func seedOlderPendingNavigation(in appState: AppState) -> EditorNavigationRequest {
        let request = EditorNavigationRequest(
            id: 40,
            documentIdentity: AppState.editorDocumentIdentity(
                for: appState.currentDocument.fileURL ?? URL(fileURLWithPath: "/a.md")
            ),
            selection: NSRange(location: 0, length: 1)
        )
        appState.editorNavigationGeneration = request.id
        appState.editorNavigationCommand = .navigate(request)
        return request
    }

    private func activateAndAssertNewerCancellation(
        _ scenario: AcceptedActivationScenario,
        olderThan requestID: UInt64
    ) {
        scenario.fixture.appState.activateWorkspaceSearchResult(
            context: scenario.context,
            fileResult: scenario.fileResult,
            match: scenario.match
        )
        guard case let .cancel(cancellationID)? = scenario.fixture.appState.editorNavigationCommand else {
            return XCTFail("Accepted activation failure must leave a cancellation command latest")
        }
        XCTAssertGreaterThan(cancellationID, requestID)
    }

    private struct EditorBridgeFixture {
        let window: NSWindow
        let scrollView: NSScrollView
        let textView: MarkdownSTTextView
        let coordinator: MarkdownTextViewCoordinator
    }

    private func makeEditorBridgeFixture(
        representable: MarkdownTextView,
        source: String
    ) throws -> EditorBridgeFixture {
        let frame = NSRect(x: 0, y: 0, width: 560, height: 120)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.isEditable = true
        textView.isSelectable = true
        textView.showsLineNumbers = false
        textView.text = source
        textView.textSelection = NSRange(location: 0, length: 0)
        let coordinator = representable.makeCoordinator()
        textView.textDelegate = coordinator
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        representable.updateRepresentedTextView(scrollView, coordinator: coordinator)
        return EditorBridgeFixture(
            window: window,
            scrollView: scrollView,
            textView: textView,
            coordinator: coordinator
        )
    }

    private struct Fixture {
        let appState: AppState
        let rootURL: URL
        let snapshot: WorkspaceFileSnapshot
    }

    private enum TestError: Error {
        case expectedEditorNavigation
    }

    private func configureWorkspace(
        _ appState: AppState,
        rootURL: URL,
        paths: [String],
        currentSession: DocumentSession,
        retainSecurityScope: Bool = false
    ) {
        let workspaceSnapshot = snapshot(paths: paths, rootURL: rootURL)
        appState.workspaceRootURL = rootURL
        appState.workspaceSnapshot = workspaceSnapshot
        appState.workspaceSearchRootAuthority = try? WorkspaceFileSystemRootAuthority(
            rootURL: rootURL
        )
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.workspaceTree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: workspaceSnapshot,
            options: .init(showAllFiles: false)
        )
        if retainSecurityScope {
            appState.workspaceAccess = SecurityScopedAccess.startAccessing(rootURL)
        }
        if let fileURL = currentSession.fileURL?.standardizedFileURL.resolvingSymlinksInPath() {
            appState.sessionCache[fileURL] = currentSession
            _ = appState.sessionPolicy.access(fileURL, isDirty: currentSession.isDirty)
        }
    }

    private func makeFixture(
        provider: ControlledWorkspaceSearchStreamProvider,
        files: [String: String],
        currentPath: String? = nil,
        debounceNanoseconds: UInt64 = 0,
        directoryScanner: any WorkspaceDirectoryScanning = ImmediateWorkspaceDirectoryScanner(
            snapshot: WorkspaceFileSnapshot(entries: [])
        )
    ) throws -> Fixture {
        let rootURL = try makeTemporaryDirectory()
        for (path, text) in files {
            let fileURL = rootURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        let workspaceSnapshot = snapshot(paths: files.keys.sorted(), rootURL: rootURL)
        let currentDocument: DocumentSession
        if let currentPath, let text = files[currentPath] {
            let fileURL = rootURL.appendingPathComponent(currentPath)
            currentDocument = DocumentSession(
                text: text,
                url: fileURL,
                fileKind: FileKind(url: fileURL)
            )
        } else {
            currentDocument = DocumentSession()
        }
        let appState = AppState(
            currentDocument: currentDocument,
            directoryScanner: directoryScanner,
            workspaceSearchStreamProvider: provider,
            workspaceSearchDebounceNanoseconds: debounceNanoseconds,
            shouldRestoreLastOpenedFile: false
        )
        appState.workspaceRootURL = rootURL
        appState.workspaceSnapshot = workspaceSnapshot
        let rootAuthority = try WorkspaceFileSystemRootAuthority(rootURL: rootURL)
        appState.workspaceSearchRootAuthority = rootAuthority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.workspaceTree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: workspaceSnapshot,
            options: .init(showAllFiles: false)
        )
        if let fileURL = currentDocument.fileURL?.standardizedFileURL {
            appState.sessionCache[fileURL] = currentDocument
            let location = try rootAuthority.canonicalizedLocation(forFileURL: fileURL)
            try appState.activateAnchoredFileSession(at: location)
        }
        return Fixture(appState: appState, rootURL: rootURL, snapshot: workspaceSnapshot)
    }

    private func cleanUp(_ fixture: Fixture) {
        fixture.appState.autosaveTask?.cancel()
        fixture.appState.statisticsTask?.cancel()
        fixture.appState.completionWorkspaceTask?.cancel()
        fixture.appState.teardownWorkspaceSearch()
        fixture.appState.workspaceWatcher?.stop()
        try? FileManager.default.removeItem(at: fixture.rootURL)
    }

    private func snapshot(paths: some Sequence<String>, rootURL: URL) -> WorkspaceFileSnapshot {
        WorkspaceFileSnapshot(entries: paths.map { path in
            let fileURL = rootURL.appendingPathComponent(path)
            return WorkspaceFileSnapshot.Entry(
                relativePath: path,
                kind: WorkspaceFileKind(url: fileURL, isDirectory: false),
                identity: "id:\(path)",
                contentModificationDate: nil
            )
        })
    }

    private func context(for request: WorkspaceSearchRequest) -> WorkspaceSearchContext {
        WorkspaceSearchContext(
            rootIdentity: request.rootIdentity,
            workspaceGeneration: request.workspaceGeneration,
            queryGeneration: request.queryGeneration
        )
    }

    private func result(
        path: String,
        text: String,
        needle: String,
        truncated: Bool = false
    ) -> WorkspaceSearchFileResult {
        let range = (text as NSString).range(of: needle)
        return WorkspaceSearchFileResult(
            relativePath: path,
            contentFingerprint: WorkspaceSearchContentFingerprint(text: text),
            matches: [TextSearchMatch(
                range: range,
                line: 1,
                preview: text,
                previewMatchRange: range
            )],
            isTruncated: truncated
        )
    }

    private func summary(
        candidateFileCount: Int = 0,
        searchedFileCount: Int = 0,
        skippedFileCount: Int = 0,
        totalMatchCount: Int = 0,
        truncatedFilePaths: [String] = [],
        isGloballyTruncated: Bool = false,
        skippedFiles: [WorkspaceSearchSkippedFile] = [],
        omittedSkippedFileCount: Int = 0
    ) -> WorkspaceSearchSummary {
        WorkspaceSearchSummary(
            candidateFileCount: candidateFileCount,
            searchedFileCount: searchedFileCount,
            skippedFileCount: skippedFileCount,
            ignoredFileCount: 0,
            totalEmittedMatchCount: totalMatchCount,
            truncatedFilePaths: truncatedFilePaths,
            isGloballyTruncated: isGloballyTruncated,
            skippedFiles: skippedFiles,
            omittedSkippedFileCount: omittedSkippedFileCount,
            readInstrumentation: WorkspaceSearchReadInstrumentation(
                diskReadCount: 0,
                diskReadByteCount: 0,
                maximumConcurrentReads: 0,
                maximumBufferedReadCount: 0,
                maximumOutstandingReadCount: 0
            )
        )
    }

    private func navigationRequest(from command: EditorNavigationCommand?) throws -> EditorNavigationRequest {
        guard case let .navigate(request)? = command else {
            XCTFail("Expected an editor navigation request")
            throw TestError.expectedEditorNavigation
        }
        return request
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSearchAppStateTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(
        _ description: String,
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }
}

// swiftlint:enable type_body_length

private actor StubWorkspaceImageThumbnailProvider: WorkspaceImageThumbnailLoading {
    struct Request: Equatable {
        let rootURL: URL
        let documentDirectoryRelativePath: String
        let source: String
        let maxPixelSize: Int
    }

    private let outcomes: [String: WorkspaceImageThumbnailOutcome]
    private var requests: [Request] = []

    init(outcomes: [String: WorkspaceImageThumbnailOutcome]) {
        self.outcomes = outcomes
    }

    func loadThumbnail(
        rootURL: URL,
        documentDirectoryRelativePath: String,
        source: String,
        maxPixelSize: Int
    ) async -> WorkspaceImageThumbnailOutcome {
        requests.append(Request(
            rootURL: rootURL,
            documentDirectoryRelativePath: documentDirectoryRelativePath,
            source: source,
            maxPixelSize: maxPixelSize
        ))
        return outcomes[source] ?? .failed(.missingFile)
    }

    func recordedRequests() -> [Request] {
        requests
    }
}

@MainActor
private final class RecordingWorkspaceSearchStreamProvider: WorkspaceSearchStreamProviding {
    private let service = WorkspaceSearchService()
    private(set) var requests: [WorkspaceSearchRequest] = []

    func events(for request: WorkspaceSearchRequest) -> AsyncStream<WorkspaceSearchEvent> {
        requests.append(request)
        return service.events(for: request)
    }
}

@MainActor
private final class ControlledWorkspaceSearchStreamProvider: WorkspaceSearchStreamProviding {
    private(set) var requests: [WorkspaceSearchRequest] = []
    private(set) var terminatedSubscriptionIndices: Set<Int> = []
    private var continuations: [AsyncStream<WorkspaceSearchEvent>.Continuation] = []

    func events(for request: WorkspaceSearchRequest) -> AsyncStream<WorkspaceSearchEvent> {
        let pair = AsyncStream<WorkspaceSearchEvent>.makeStream(bufferingPolicy: .unbounded)
        let index = requests.count
        requests.append(request)
        continuations.append(pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.terminatedSubscriptionIndices.insert(index)
            }
        }
        return pair.stream
    }

    func yield(_ event: WorkspaceSearchEvent, to index: Int) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].yield(event)
    }

    func finish(_ index: Int) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].finish()
    }
}

private struct ImmediateWorkspaceDirectoryScanner: WorkspaceDirectoryScanning {
    let snapshot: WorkspaceFileSnapshot

    func snapshotCapture(root: URL) async throws -> WorkspaceDirectorySnapshotCapture {
        let rootAuthority = try await WorkspaceFileSystemRootAuthority.capture(rootURL: root)
        return WorkspaceDirectorySnapshotCapture(
            snapshot: snapshot,
            rootAuthority: rootAuthority
        )
    }
}

private actor ControlledWorkspaceDirectoryScanner: WorkspaceDirectoryScanning {
    private var continuations: [CheckedContinuation<WorkspaceFileSnapshot, Error>?] = []
    private var requestCount = 0
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    /// Runs after authority+snapshot are ready and before `snapshotCapture` returns, so App
    /// install proof can observe a retargeted selected root.
    private var afterCaptureHandlers: [(@Sendable () async throws -> Void)?] = []

    func snapshotCapture(root: URL) async throws -> WorkspaceDirectorySnapshotCapture {
        let rootAuthority = try await WorkspaceFileSystemRootAuthority.capture(rootURL: root)
        requestCount += 1
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        let snapshot = try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
            afterCaptureHandlers.append(nil)
        }
        let index = requestCount - 1
        if afterCaptureHandlers.indices.contains(index),
           let handler = afterCaptureHandlers[index]
        {
            try await handler()
        }
        return WorkspaceDirectorySnapshotCapture(
            snapshot: snapshot,
            rootAuthority: rootAuthority
        )
    }

    func waitForRequestCount(_ expectedCount: Int) async {
        while requestCount < expectedCount {
            await withCheckedContinuation { continuation in
                requestWaiters.append(continuation)
            }
        }
    }

    func completeRequest(
        at index: Int,
        with snapshot: WorkspaceFileSnapshot,
        afterCapture: (@Sendable () async throws -> Void)? = nil
    ) {
        guard continuations.indices.contains(index), let continuation = continuations[index] else {
            return
        }
        if afterCaptureHandlers.indices.contains(index) {
            afterCaptureHandlers[index] = afterCapture
        }
        continuations[index] = nil
        continuation.resume(returning: snapshot)
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
