// The generated project fixes App test source membership; keep the WS3B matrix in this
// existing source without regenerating the out-of-scope project file.
// swiftlint:disable file_length type_body_length
import AppKit
import Darwin
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
        try configureImageAssetWorkspace(
            appState,
            rootURL: root,
            currentSession: firstSession
        )

        let inserter = try XCTUnwrap(appState.editorImageAssetInserter)
        appState.setCurrentDocument(secondSession)

        let insertion = await inserter([.data(Data([1, 2, 3]), suggestedFilename: "image.png")])

        XCTAssertEqual(insertion.relativePaths, ["assets/image.png"])
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: firstDirectory.appendingPathComponent("assets/image.png").path))
        XCTAssertFalse(FileManager.default
            .fileExists(atPath: secondDirectory.appendingPathComponent("assets/image.png").path))
        insertion.commit()
    }

    func testCapturedImageAssetInserterRejectsReplacedDocumentParentWithOriginalHardLink() async throws {
        let root = try makeTemporaryDirectory()
        let documentDirectory = root.appendingPathComponent("posts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: documentDirectory,
            withIntermediateDirectories: true
        )
        let documentURL = documentDirectory.appendingPathComponent("post.md")
        try "Body".write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(
            text: "Body",
            url: documentURL,
            fileKind: .markdown
        )
        let appState = AppState(currentDocument: session)
        try configureImageAssetWorkspace(
            appState,
            rootURL: root,
            currentSession: session
        )
        let inserter = try XCTUnwrap(appState.editorImageAssetInserter)

        let retainedDirectory = root.appendingPathComponent("retained-posts", isDirectory: true)
        try FileManager.default.moveItem(at: documentDirectory, to: retainedDirectory)
        try FileManager.default.createDirectory(
            at: documentDirectory,
            withIntermediateDirectories: false
        )
        let replacementDocumentURL = documentDirectory.appendingPathComponent("post.md")
        try FileManager.default.linkItem(
            at: retainedDirectory.appendingPathComponent("post.md"),
            to: replacementDocumentURL
        )
        let replacementStatus = try fileStatus(at: replacementDocumentURL)
        let retainedStatus = try fileStatus(
            at: retainedDirectory.appendingPathComponent("post.md")
        )
        XCTAssertEqual(
            replacementStatus.st_ino,
            retainedStatus.st_ino,
            "test setup must put the original document inode under a replacement parent"
        )

        let insertion = await inserter([
            .data(Data([1, 2, 3]), suggestedFilename: "image.png"),
        ])

        XCTAssertTrue(insertion.relativePaths.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: documentDirectory.appendingPathComponent("assets").path(percentEncoded: false)
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: retainedDirectory.appendingPathComponent("assets").path(percentEncoded: false)
        ))
    }

    func testImageAssetInserterGetterDoesNotReopenReplacedDocumentParent() async throws {
        let root = try makeTemporaryDirectory()
        let documentDirectory = root.appendingPathComponent("posts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: documentDirectory,
            withIntermediateDirectories: true
        )
        let documentURL = documentDirectory.appendingPathComponent("post.md")
        try "Body".write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: "Body", url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session)
        try configureImageAssetWorkspace(appState, rootURL: root, currentSession: session)

        let retainedDirectory = root.appendingPathComponent("retained-posts", isDirectory: true)
        try FileManager.default.moveItem(at: documentDirectory, to: retainedDirectory)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: false)
        try FileManager.default.linkItem(
            at: retainedDirectory.appendingPathComponent("post.md"),
            to: documentDirectory.appendingPathComponent("post.md")
        )

        let rootAuthority = try XCTUnwrap(appState.workspaceSearchRootAuthority)
        let replacementLocation = try rootAuthority.location(relativePath: "posts/post.md")
        let replacementRead = try prepareEditorImageAssetDocumentRead(
            fileStore: MarkdownFileStore(),
            at: replacementLocation
        )
        appState.adoptAnchoredFileBinding(
            AnchoredWorkspaceSessionFileBinding(
                location: replacementLocation,
                identity: replacementRead.result.metadata.identity,
                sha256Digest: replacementRead.result.sha256Digest
            ),
            for: session,
            preparedImageAssetAuthority: replacementRead.preparedAuthority
        )

        _ = appState.editorDocumentBinding(for: session)
        _ = appState.editorDocumentBinding(for: session)
        let inserter = try XCTUnwrap(
            appState.editorImageAssetInserter,
            "body/getter reads must preserve the already-captured exact authority"
        )
        let insertion = await inserter([
            .data(Data([1, 2, 3]), suggestedFilename: "image.png"),
        ])

        XCTAssertTrue(insertion.relativePaths.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: documentDirectory.appendingPathComponent("assets").path(percentEncoded: false)
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: retainedDirectory.appendingPathComponent("assets").path(percentEncoded: false)
        ))
    }

    func testImageAssetAuthorityCacheMissDoesNotRetryFromSwiftUIBody() throws {
        let root = try makeTemporaryDirectory()
        let documentDirectory = root.appendingPathComponent("posts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: documentDirectory,
            withIntermediateDirectories: true
        )
        let documentURL = documentDirectory.appendingPathComponent("post.md")
        try "Body".write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: "Body", url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session)
        try configureImageAssetWorkspace(appState, rootURL: root, currentSession: session)
        let sessionIdentity = ObjectIdentifier(session)
        appState.anchoredSessionFileBindings[sessionIdentity] = nil
        appState.unanchoredManagedSessionOwnershipProofs[sessionIdentity] = nil
        appState.editorImageAssetDocumentAuthorities[sessionIdentity] = nil

        let retainedDirectory = root.appendingPathComponent("retained-posts", isDirectory: true)
        try FileManager.default.moveItem(at: documentDirectory, to: retainedDirectory)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: false)
        try FileManager.default.linkItem(
            at: retainedDirectory.appendingPathComponent("post.md"),
            to: documentDirectory.appendingPathComponent("post.md")
        )

        _ = appState.editorDocumentBinding(for: session)
        _ = appState.editorDocumentBinding(for: session)

        XCTAssertNil(appState.unanchoredManagedSessionOwnershipProofs[sessionIdentity])
        XCTAssertNil(appState.editorImageAssetDocumentAuthorities[sessionIdentity])
        XCTAssertNil(
            appState.editorImageAssetInserter,
            "body evaluation must not inspect the replacement namespace to refill proof/cache"
        )
    }

    func testImageAssetAuthorityCacheMissCannotBootstrapReplacementParent() throws {
        let root = try makeTemporaryDirectory()
        let documentDirectory = root.appendingPathComponent("posts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: documentDirectory,
            withIntermediateDirectories: true
        )
        let documentURL = documentDirectory.appendingPathComponent("post.md")
        try "Body".write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: "Body", url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session)
        try configureImageAssetWorkspace(appState, rootURL: root, currentSession: session)
        let sessionIdentity = ObjectIdentifier(session)
        appState.editorImageAssetDocumentAuthorities[sessionIdentity] = nil

        let retainedDirectory = root.appendingPathComponent("retained-posts", isDirectory: true)
        try FileManager.default.moveItem(at: documentDirectory, to: retainedDirectory)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: false)
        try FileManager.default.linkItem(
            at: retainedDirectory.appendingPathComponent("post.md"),
            to: documentDirectory.appendingPathComponent("post.md")
        )

        let rootAuthority = try XCTUnwrap(appState.workspaceSearchRootAuthority)
        let replacementLocation = try rootAuthority.location(relativePath: "posts/post.md")
        let replacementRead = try prepareEditorImageAssetDocumentRead(
            fileStore: MarkdownFileStore(),
            at: replacementLocation
        )
        appState.adoptAnchoredFileBinding(
            AnchoredWorkspaceSessionFileBinding(
                location: replacementLocation,
                identity: replacementRead.result.metadata.identity,
                sha256Digest: replacementRead.result.sha256Digest
            ),
            for: session,
            preparedImageAssetAuthority: replacementRead.preparedAuthority
        )

        XCTAssertNil(appState.editorImageAssetDocumentAuthorities[sessionIdentity])
        XCTAssertNil(appState.editorImageAssetInserter)
    }

    func testImageAssetAuthorityRejectsReplacementParentAfterLeafIdentityChanges() throws {
        let root = try makeTemporaryDirectory()
        let documentDirectory = root.appendingPathComponent("posts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: documentDirectory,
            withIntermediateDirectories: true
        )
        let documentURL = documentDirectory.appendingPathComponent("post.md")
        try "Body".write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: "Body", url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session)
        try configureImageAssetWorkspace(appState, rootURL: root, currentSession: session)
        let sessionIdentity = ObjectIdentifier(session)
        let originalAuthority = try XCTUnwrap(
            appState.editorImageAssetDocumentAuthorities[sessionIdentity]
        )

        let retainedDirectory = root.appendingPathComponent("retained-posts", isDirectory: true)
        try FileManager.default.moveItem(at: documentDirectory, to: retainedDirectory)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: false)
        let replacementDocumentURL = documentDirectory.appendingPathComponent("post.md")
        try FileManager.default.linkItem(
            at: retainedDirectory.appendingPathComponent("post.md"),
            to: replacementDocumentURL
        )
        try "Replacement".write(
            to: replacementDocumentURL,
            atomically: true,
            encoding: .utf8
        )

        let rootAuthority = try XCTUnwrap(appState.workspaceSearchRootAuthority)
        let replacementLocation = try rootAuthority.location(relativePath: "posts/post.md")
        let replacementRead = try prepareEditorImageAssetDocumentRead(
            fileStore: MarkdownFileStore(),
            at: replacementLocation
        )
        XCTAssertNotEqual(replacementRead.result.metadata.identity, originalAuthority.identity)
        appState.adoptAnchoredFileBinding(
            AnchoredWorkspaceSessionFileBinding(
                location: replacementLocation,
                identity: replacementRead.result.metadata.identity,
                sha256Digest: replacementRead.result.sha256Digest
            ),
            for: session,
            preparedImageAssetAuthority: replacementRead.preparedAuthority
        )

        XCTAssertEqual(
            appState.editorImageAssetDocumentAuthorities[sessionIdentity]?.identity,
            originalAuthority.identity
        )
        XCTAssertNil(appState.editorImageAssetInserter)
    }

    func testAnchoredActivationCarriesPreloadedImageAuthorityAcrossParentReplacement() async throws {
        let root = try makeTemporaryDirectory()
        let documentDirectory = root.appendingPathComponent("posts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: documentDirectory,
            withIntermediateDirectories: true
        )
        let documentURL = documentDirectory.appendingPathComponent("post.md")
        try "Body".write(to: documentURL, atomically: true, encoding: .utf8)
        let rootAuthority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try rootAuthority.location(relativePath: "posts/post.md")
        let preparedRead = try prepareEditorImageAssetDocumentRead(
            fileStore: MarkdownFileStore(),
            at: location
        )
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = rootAuthority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        let activation = try appState.prepareAnchoredFileSessionActivation(
            file: preparedRead.result.file,
            at: location,
            metadata: preparedRead.result.metadata,
            sha256Digest: preparedRead.result.sha256Digest,
            preparedImageAssetAuthority: preparedRead.preparedAuthority
        )

        let retainedDirectory = root.appendingPathComponent("retained-posts", isDirectory: true)
        try FileManager.default.moveItem(at: documentDirectory, to: retainedDirectory)
        try FileManager.default.createDirectory(
            at: documentDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.linkItem(
            at: retainedDirectory.appendingPathComponent("post.md"),
            to: documentDirectory.appendingPathComponent("post.md")
        )

        appState.commitAnchoredFileSessionActivation(activation)

        XCTAssertEqual(appState.currentDocument.text, "Body")
        let inserter = try XCTUnwrap(appState.editorImageAssetInserter)
        let insertion = await inserter([
            .data(Data([1, 2, 3]), suggestedFilename: "image.png"),
        ])
        XCTAssertTrue(insertion.relativePaths.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: documentDirectory.appendingPathComponent("assets").path(percentEncoded: false)
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: retainedDirectory.appendingPathComponent("assets").path(percentEncoded: false)
        ))
    }

    func testDurableSaveRebindsImageAuthorityThroughRetainedParent() async throws {
        let root = try makeTemporaryDirectory()
        let documentURL = root.appendingPathComponent("post.md")
        try "Body".write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: "Body", url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session)
        try configureImageAssetWorkspace(appState, rootURL: root, currentSession: session)
        let originalAuthority = try XCTUnwrap(
            appState.editorImageAssetDocumentAuthorities[ObjectIdentifier(session)]
        )

        appState.replaceDocumentText("Changed", in: session)
        try appState.save(session: session)

        let savedBinding = try XCTUnwrap(appState.anchoredSessionFileBinding(for: session))
        let savedAuthority = try XCTUnwrap(
            appState.editorImageAssetDocumentAuthorities[ObjectIdentifier(session)]
        )
        XCTAssertNotEqual(savedBinding.identity, originalAuthority.identity)
        XCTAssertTrue(savedAuthority.matches(
            location: savedBinding.location,
            identity: savedBinding.identity
        ))
        let inserter = try XCTUnwrap(appState.editorImageAssetInserter)
        let insertion = await inserter([
            .data(Data([1, 2, 3]), suggestedFilename: "image.png"),
        ])
        XCTAssertEqual(insertion.relativePaths, ["assets/image.png"])
        let isValid = await insertion.validateBeforeCommit()
        XCTAssertTrue(isValid)
        await insertion.discard()
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

    func testDebugWorkspaceSearchFixtureDoesNotPersistSessionMetadata() throws {
        let directory = try makeTemporaryDirectory()
        let lastOpenedFileStore = SpyLastOpenedFileStore()
        let recentItemStore = SpyRecentItemStore()
        let appState = AppState(
            lastOpenedFileStore: lastOpenedFileStore,
            recentItemStore: recentItemStore,
            shouldRestoreLastOpenedFile: false
        )

        appState.openDebugWorkspaceSearchFixture(directory)

        XCTAssertEqual(
            appState.workspaceRootURL?.standardizedFileURL,
            directory.standardizedFileURL
        )
        XCTAssertTrue(lastOpenedFileStore.savedURLs.isEmpty)
        XCTAssertTrue(recentItemStore.savedURLs.isEmpty)
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
        try configureImageAssetWorkspace(
            appState,
            rootURL: root,
            currentSession: session
        )
        appState.preferences.setAssetFolderRelativePath("media/images")

        let inserter = try XCTUnwrap(appState.editorImageAssetInserter)
        let insertion = await inserter([.data(Data([1, 2, 3]), suggestedFilename: "image.png")])

        XCTAssertEqual(insertion.relativePaths, ["media/images/image.png"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("media/images/image.png").path(percentEncoded: false)
        ))
        insertion.commit()
    }

    func testImageNamespaceLeaseStaysHeldThroughCommitValidationAndTerminalOutcome() async throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: "Body", url: currentFile, fileKind: .markdown)
        let appState = AppState(currentDocument: session)
        try configureImageAssetWorkspace(
            appState,
            rootURL: root,
            currentSession: session
        )
        let inserter = try XCTUnwrap(appState.editorImageAssetInserter)

        let committed = await inserter([
            .data(Data([1, 2, 3]), suggestedFilename: "committed.png"),
        ])
        XCTAssertEqual(appState.workspaceImageAssetInsertionCount, 1)
        XCTAssertThrowsError(try appState.beginWorkspaceNamespaceMutation([]))
        let isCommitValid = await committed.validateBeforeCommit()
        XCTAssertTrue(isCommitValid)
        XCTAssertEqual(appState.workspaceImageAssetInsertionCount, 1)
        committed.commit()
        XCTAssertEqual(appState.workspaceImageAssetInsertionCount, 0)
        await committed.discard()
        XCTAssertEqual(appState.workspaceImageAssetInsertionCount, 0)

        let discarded = await inserter([
            .data(Data([4, 5, 6]), suggestedFilename: "discarded.png"),
        ])
        XCTAssertEqual(appState.workspaceImageAssetInsertionCount, 1)
        await discarded.discard()
        XCTAssertEqual(appState.workspaceImageAssetInsertionCount, 0)
        discarded.commit()
        XCTAssertEqual(appState.workspaceImageAssetInsertionCount, 0)
    }

    func testTerminationRejectsWhileImageDiscardCleanupOwnsNamespaceLease() async throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: "Body", url: currentFile, fileKind: .markdown)
        let appState = AppState(currentDocument: session)
        try configureImageAssetWorkspace(
            appState,
            rootURL: root,
            currentSession: session
        )
        let cleanupGate = EditorImageAssetDiscardGate()
        appState.editorImageAssetDiscardEventHandler = { event in
            guard case .willRename = event else { return }
            cleanupGate.beginAndWait()
        }
        let inserter = try XCTUnwrap(appState.editorImageAssetInserter)
        let insertion = await inserter([
            .data(Data([1, 2, 3]), suggestedFilename: "discarded.png"),
        ])

        let discardTask = Task { @MainActor in
            await insertion.discard()
        }
        try await waitUntil("image discard cleanup reaches its rename boundary") {
            cleanupGate.hasBegun
        }
        XCTAssertEqual(appState.workspaceImageAssetInsertionCount, 1)
        XCTAssertFalse(appState.prepareForTermination())
        XCTAssertEqual(appState.presentedError?.title, "Could Not Quit")

        cleanupGate.release()
        await discardTask.value
        XCTAssertEqual(appState.workspaceImageAssetInsertionCount, 0)
        XCTAssertTrue(appState.prepareForTermination())
    }

    func testDiscardedEditorImageInsertionMovesCreatedAssetsToVisibleRecovery() async throws {
        let root = try makeTemporaryDirectory()
        let externalDirectory = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        let externalImage = externalDirectory.appendingPathComponent("external.png")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        try Data([4, 5, 6]).write(to: externalImage)
        let session = DocumentSession(text: "Body", url: currentFile, fileKind: .markdown)
        let appState = AppState(currentDocument: session)
        try configureImageAssetWorkspace(
            appState,
            rootURL: root,
            currentSession: session
        )

        let inserter = try XCTUnwrap(appState.editorImageAssetInserter)
        let insertion = await inserter([
            .data(Data([1, 2, 3]), suggestedFilename: "image.png"),
            .file(externalImage),
        ])
        let placedURLs = insertion.relativePaths.map {
            root.appendingPathComponent($0).standardizedFileURL
        }
        XCTAssertEqual(
            insertion.relativePaths,
            ["assets/image.png", "assets/external.png"],
            appState.presentedError?.message ?? ""
        )
        XCTAssertTrue(placedURLs.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        })

        await insertion.discard()

        XCTAssertTrue(placedURLs.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        })
        let recoveryNames = try imageAssetDirectoryEntries(in: root)
        XCTAssertEqual(recoveryNames.count, 2)
        XCTAssertTrue(recoveryNames.allSatisfy { $0.hasPrefix("Plainsong-preserved-") })
        let recoveryData = try recoveryNames.map {
            try Data(contentsOf: root.appendingPathComponent("assets/\($0)"))
        }
        XCTAssertEqual(Set(recoveryData), Set([Data([1, 2, 3]), Data([4, 5, 6])]))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: externalImage.path(percentEncoded: false)
        ))
        XCTAssertEqual(appState.presentedError?.title, "Image Cleanup Needs Attention")
    }

    func testDiscardedEditorImageInsertionPreservesExistingWorkspaceReference() async throws {
        let root = try makeTemporaryDirectory()
        let assetsDirectory = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        let currentFile = root.appendingPathComponent("post.md")
        let existingImage = assetsDirectory.appendingPathComponent("existing.png")
        let existingData = Data([1, 2, 3])
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        try existingData.write(to: existingImage)
        let session = DocumentSession(text: "Body", url: currentFile, fileKind: .markdown)
        let appState = AppState(currentDocument: session)
        try configureImageAssetWorkspace(
            appState,
            rootURL: root,
            currentSession: session
        )

        let inserter = try XCTUnwrap(appState.editorImageAssetInserter)
        let insertion = await inserter([.file(existingImage)])
        XCTAssertEqual(
            insertion.relativePaths,
            ["assets/existing.png"],
            appState.presentedError?.message ?? ""
        )

        await insertion.discard()

        XCTAssertEqual(try Data(contentsOf: existingImage), existingData)
    }

    func testImagePlacementCommitValidationRejectsMovedAssetDirectory() async throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: "Body", url: currentFile, fileKind: .markdown)
        let appState = AppState(currentDocument: session)
        try configureImageAssetWorkspace(
            appState,
            rootURL: root,
            currentSession: session
        )

        let inserter = try XCTUnwrap(appState.editorImageAssetInserter)
        let insertion = await inserter([
            .data(Data([1, 2, 3]), suggestedFilename: "image.png"),
        ])
        XCTAssertEqual(insertion.relativePaths, ["assets/image.png"])
        let assetDirectory = root.appendingPathComponent("assets", isDirectory: true)
        let retainedDirectory = root.appendingPathComponent("assets-old", isDirectory: true)
        try FileManager.default.moveItem(at: assetDirectory, to: retainedDirectory)
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: false)
        let replacementData = Data([9, 8, 7])
        let replacementImage = assetDirectory.appendingPathComponent("image.png")
        try replacementData.write(to: replacementImage)

        let isValid = await insertion.validateBeforeCommit()
        XCTAssertFalse(isValid)
        await insertion.discard()

        XCTAssertEqual(try Data(contentsOf: replacementImage), replacementData)
        let retainedEntries = try directoryEntries(at: retainedDirectory)
        let recoveryName = try XCTUnwrap(retainedEntries.first)
        XCTAssertEqual(retainedEntries, [recoveryName])
        XCTAssertTrue(recoveryName.hasPrefix("Plainsong-preserved-"))
        XCTAssertEqual(
            try Data(contentsOf: retainedDirectory.appendingPathComponent(recoveryName)),
            Data([1, 2, 3])
        )
        XCTAssertTrue(appState.presentedError?.message.contains(
            retainedDirectory.appendingPathComponent(recoveryName).path(percentEncoded: false)
        ) == true)
        XCTAssertFalse(appState.presentedError?.message.contains(
            assetDirectory.appendingPathComponent(recoveryName).path(percentEncoded: false)
        ) == true)
    }

    func testImagePlacementCommitValidationRejectsMovedWorkspaceReferenceParent() async throws {
        let root = try makeTemporaryDirectory()
        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let currentFile = root.appendingPathComponent("post.md")
        let existingImage = mediaDirectory.appendingPathComponent("existing.png")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        try Data([1, 2, 3]).write(to: existingImage)
        let session = DocumentSession(text: "Body", url: currentFile, fileKind: .markdown)
        let appState = AppState(currentDocument: session)
        try configureImageAssetWorkspace(
            appState,
            rootURL: root,
            currentSession: session
        )

        let inserter = try XCTUnwrap(appState.editorImageAssetInserter)
        let insertion = await inserter([.file(existingImage)])
        XCTAssertEqual(insertion.relativePaths, ["media/existing.png"])
        let retainedDirectory = root.appendingPathComponent("media-old", isDirectory: true)
        try FileManager.default.moveItem(at: mediaDirectory, to: retainedDirectory)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: false)
        try FileManager.default.linkItem(
            at: retainedDirectory.appendingPathComponent("existing.png"),
            to: mediaDirectory.appendingPathComponent("existing.png")
        )

        let isValid = await insertion.validateBeforeCommit()
        XCTAssertFalse(isValid)
        await insertion.discard()

        XCTAssertEqual(
            try Data(contentsOf: mediaDirectory.appendingPathComponent("existing.png")),
            Data([1, 2, 3])
        )
        XCTAssertEqual(
            try Data(contentsOf: retainedDirectory.appendingPathComponent("existing.png")),
            Data([1, 2, 3])
        )
    }

    func testDiscardedEditorImageInsertionPreservesIdentityReplacement() async throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: "Body", url: currentFile, fileKind: .markdown)
        let appState = AppState(currentDocument: session)
        try configureImageAssetWorkspace(
            appState,
            rootURL: root,
            currentSession: session
        )

        let inserter = try XCTUnwrap(appState.editorImageAssetInserter)
        let insertion = await inserter([
            .data(Data([1, 2, 3]), suggestedFilename: "image.png"),
        ])
        let placedImage = root.appendingPathComponent("assets/image.png")
        let retainedOriginal = root.appendingPathComponent("assets/receipt-original.png")
        try FileManager.default.moveItem(at: placedImage, to: retainedOriginal)
        let replacementData = Data([9, 8, 7])
        try replacementData.write(to: placedImage)

        await insertion.discard()

        XCTAssertEqual(try Data(contentsOf: placedImage), replacementData)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: retainedOriginal.path(percentEncoded: false)
        ))
    }

    func testDiscardedEditorImageInsertionMovesSameInodeRewriteToVisibleRecovery() async throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: "Body", url: currentFile, fileKind: .markdown)
        let appState = AppState(currentDocument: session)
        try configureImageAssetWorkspace(
            appState,
            rootURL: root,
            currentSession: session
        )

        let inserter = try XCTUnwrap(appState.editorImageAssetInserter)
        let insertion = await inserter([
            .data(Data([1, 2, 3]), suggestedFilename: "image.png"),
        ])
        let placedImage = root.appendingPathComponent("assets/image.png")
        let originalStatus = try fileStatus(at: placedImage)
        let rewrittenData = Data([9, 8, 7])
        let handle = try FileHandle(forWritingTo: placedImage)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: rewrittenData)
        try handle.synchronize()
        try handle.close()
        let rewrittenStatus = try fileStatus(at: placedImage)
        XCTAssertEqual(
            rewrittenStatus.st_ino,
            originalStatus.st_ino,
            "test setup must rewrite the published asset through the same inode"
        )

        await insertion.discard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: placedImage.path(percentEncoded: false)))
        let entries = try imageAssetDirectoryEntries(in: root)
        let recoveryName = try XCTUnwrap(entries.first)
        XCTAssertEqual(entries, [recoveryName])
        XCTAssertTrue(recoveryName.hasPrefix("Plainsong-preserved-"))
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("assets/\(recoveryName)")),
            rewrittenData
        )
        XCTAssertEqual(appState.presentedError?.title, "Image Cleanup Needs Attention")
    }

    func testDiscardRacePreservesReplacementAtVisibleRecoveryPathWhenRestoreIsBlocked() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let createdData = Data([1, 2, 3])
        let replacementData = Data([9, 8, 7])
        let blockerData = Data([4, 5, 6])
        let originalURL = root.appendingPathComponent("assets/image.png")
        let retainedCreatedURL = root.appendingPathComponent("created-original.png")
        let placement = try placeEditorImageAssets(
            assets: [.data(createdData, suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        )

        let outcome = discardEditorImageAssets(
            placement.createdAssets,
            rootURL: root
        ) { event in
            switch event {
            case .willRename:
                try FileManager.default.moveItem(at: originalURL, to: retainedCreatedURL)
                try replacementData.write(to: originalURL)
            case .didRename:
                try blockerData.write(to: originalURL)
            case .didValidateRecovery:
                break
            }
        }

        let entries = try imageAssetDirectoryEntries(in: root)
        let recoveryName = try XCTUnwrap(entries.first {
            $0.hasPrefix("Plainsong-preserved-")
        })
        let recoveryURL = root
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(recoveryName)
        XCTAssertFalse(recoveryName.hasPrefix("."))
        XCTAssertEqual(try Data(contentsOf: originalURL), blockerData)
        XCTAssertEqual(try Data(contentsOf: recoveryURL), replacementData)
        XCTAssertEqual(try Data(contentsOf: retainedCreatedURL), createdData)
        XCTAssertTrue(outcome.didChangeWorkspace)
        XCTAssertTrue(
            outcome.issues.contains { $0.contains(recoveryURL.path(percentEncoded: false)) }
        )
    }

    func testDiscardReportsCreatedAssetMovedAwayFromMissingPublishedLeaf() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let createdData = Data([1, 2, 3])
        let originalURL = root.appendingPathComponent("assets/image.png")
        let retainedCreatedURL = root.appendingPathComponent("created-original.png")
        let placement = try placeEditorImageAssets(
            assets: [.data(createdData, suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        )
        try FileManager.default.moveItem(at: originalURL, to: retainedCreatedURL)

        let outcome = discardEditorImageAssets(placement.createdAssets, rootURL: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertEqual(try Data(contentsOf: retainedCreatedURL), createdData)
        XCTAssertFalse(outcome.didChangeWorkspace)
        XCTAssertTrue(outcome.issues.contains {
            $0.contains(retainedCreatedURL.path(percentEncoded: false))
        }, outcome.issues.joined(separator: "\n"))
    }

    func testDiscardFsyncFailureReportsRecoveryRacerAndMovedCreatedAsset() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let createdData = Data([1, 2, 3])
        let racerData = Data([9, 8, 7])
        let originalURL = root.appendingPathComponent("assets/image.png")
        let retainedCreatedURL = root.appendingPathComponent("created-original.png")
        let placement = try placeEditorImageAssets(
            assets: [.data(createdData, suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        )

        let outcome = discardEditorImageAssets(
            placement.createdAssets,
            rootURL: root,
            directorySynchronizer: { _ in throw CocoaError(.fileWriteUnknown) },
            eventHandler: { event in
                guard case .willRename = event else { return }
                try FileManager.default.moveItem(at: originalURL, to: retainedCreatedURL)
                try racerData.write(to: originalURL)
            }
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertEqual(try Data(contentsOf: retainedCreatedURL), createdData)
        let recoveryName = try XCTUnwrap(try imageAssetDirectoryEntries(in: root).first)
        let recoveryURL = root.appendingPathComponent("assets/\(recoveryName)")
        XCTAssertEqual(try Data(contentsOf: recoveryURL), racerData)
        XCTAssertTrue(outcome.didChangeWorkspace)
        XCTAssertTrue(outcome.issues.contains {
            $0.contains(recoveryURL.path(percentEncoded: false))
        }, outcome.issues.joined(separator: "\n"))
        XCTAssertTrue(outcome.issues.contains {
            $0.contains(retainedCreatedURL.path(percentEncoded: false))
        }, outcome.issues.joined(separator: "\n"))
    }

    func testDiscardFsyncFailureDoesNotAttributeLaterOccupantToAcquiredRacer() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let createdData = Data([1, 2, 3])
        let racerData = Data([9, 8, 7])
        let laterOccupantData = Data([4, 5, 6])
        let originalURL = root.appendingPathComponent("assets/image.png")
        let retainedCreatedURL = root.appendingPathComponent("created-original.png")
        let retainedRacerURL = root.appendingPathComponent("racer-original.png")
        let placement = try placeEditorImageAssets(
            assets: [.data(createdData, suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        )

        let outcome = discardEditorImageAssets(
            placement.createdAssets,
            rootURL: root,
            directorySynchronizer: { _ in
                let recoveryName = try XCTUnwrap(
                    try imageAssetDirectoryEntries(in: root).first {
                        $0.hasPrefix("Plainsong-preserved-")
                    }
                )
                let recoveryURL = root.appendingPathComponent("assets/\(recoveryName)")
                try FileManager.default.moveItem(at: recoveryURL, to: retainedRacerURL)
                try laterOccupantData.write(to: recoveryURL)
                throw CocoaError(.fileWriteUnknown)
            },
            eventHandler: { event in
                guard case .willRename = event else { return }
                try FileManager.default.moveItem(at: originalURL, to: retainedCreatedURL)
                try racerData.write(to: originalURL)
            }
        )

        let recoveryName = try XCTUnwrap(
            try imageAssetDirectoryEntries(in: root).first {
                $0.hasPrefix("Plainsong-preserved-")
            }
        )
        let recoveryURL = root.appendingPathComponent("assets/\(recoveryName)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertEqual(try Data(contentsOf: retainedCreatedURL), createdData)
        XCTAssertEqual(try Data(contentsOf: retainedRacerURL), racerData)
        XCTAssertEqual(try Data(contentsOf: recoveryURL), laterOccupantData)
        XCTAssertTrue(outcome.didChangeWorkspace)
        XCTAssertTrue(outcome.issues.contains {
            $0.contains("an unavailable visible path")
                && $0.contains("entry acquired by the recovery rename could not be rebound")
        }, outcome.issues.joined(separator: "\n"))
        XCTAssertTrue(outcome.issues.contains {
            $0.contains(recoveryURL.path(percentEncoded: false))
                && $0.contains("is not proof of the entry acquired by rename")
        }, outcome.issues.joined(separator: "\n"))
        XCTAssertTrue(outcome.issues.contains {
            $0.contains(retainedCreatedURL.path(percentEncoded: false))
        }, outcome.issues.joined(separator: "\n"))
        XCTAssertFalse(outcome.issues.contains {
            $0.contains(retainedRacerURL.path(percentEncoded: false))
        }, outcome.issues.joined(separator: "\n"))
    }

    func testDiscardSuccessfulFsyncDoesNotAttributeLaterOccupantToAcquiredRacer() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let createdData = Data([1, 2, 3])
        let racerData = Data([9, 8, 7])
        let laterOccupantData = Data([4, 5, 6])
        let originalURL = root.appendingPathComponent("assets/image.png")
        let retainedCreatedURL = root.appendingPathComponent("created-original.png")
        let retainedRacerURL = root.appendingPathComponent("racer-original.png")
        let placement = try placeEditorImageAssets(
            assets: [.data(createdData, suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        )

        let outcome = discardEditorImageAssets(
            placement.createdAssets,
            rootURL: root,
            directorySynchronizer: { _ in
                let recoveryName = try XCTUnwrap(
                    try imageAssetDirectoryEntries(in: root).first {
                        $0.hasPrefix("Plainsong-preserved-")
                    }
                )
                let recoveryURL = root.appendingPathComponent("assets/\(recoveryName)")
                try FileManager.default.moveItem(at: recoveryURL, to: retainedRacerURL)
                try laterOccupantData.write(to: recoveryURL)
            },
            eventHandler: { event in
                guard case .willRename = event else { return }
                try FileManager.default.moveItem(at: originalURL, to: retainedCreatedURL)
                try racerData.write(to: originalURL)
            }
        )

        let recoveryName = try XCTUnwrap(
            try imageAssetDirectoryEntries(in: root).first {
                $0.hasPrefix("Plainsong-preserved-")
            }
        )
        let recoveryURL = root.appendingPathComponent("assets/\(recoveryName)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertEqual(try Data(contentsOf: retainedCreatedURL), createdData)
        XCTAssertEqual(try Data(contentsOf: retainedRacerURL), racerData)
        XCTAssertEqual(try Data(contentsOf: recoveryURL), laterOccupantData)
        XCTAssertTrue(outcome.didChangeWorkspace)
        XCTAssertTrue(outcome.issues.contains {
            $0.contains("an unavailable visible path")
                && $0.contains("has no atomic provenance proof")
        }, outcome.issues.joined(separator: "\n"))
        XCTAssertTrue(outcome.issues.contains {
            $0.contains(recoveryURL.path(percentEncoded: false))
                && $0.contains("is not proof of the entry acquired by rename")
        }, outcome.issues.joined(separator: "\n"))
        XCTAssertTrue(outcome.issues.contains {
            $0.contains(retainedCreatedURL.path(percentEncoded: false))
        }, outcome.issues.joined(separator: "\n"))
        XCTAssertFalse(outcome.issues.contains {
            $0.contains(retainedRacerURL.path(percentEncoded: false))
        }, outcome.issues.joined(separator: "\n"))
    }

    func testDiscardSuccessfulFsyncDoesNotTreatLaterCreatedHardLinkAsAcquired() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let createdData = Data([1, 2, 3])
        let racerData = Data([9, 8, 7])
        let originalURL = root.appendingPathComponent("assets/image.png")
        let retainedCreatedURL = root.appendingPathComponent("created-original.png")
        let retainedRacerURL = root.appendingPathComponent("racer-original.png")
        let placement = try placeEditorImageAssets(
            assets: [.data(createdData, suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        )

        let outcome = discardEditorImageAssets(
            placement.createdAssets,
            rootURL: root,
            directorySynchronizer: { _ in
                let recoveryName = try XCTUnwrap(
                    try imageAssetDirectoryEntries(in: root).first {
                        $0.hasPrefix("Plainsong-preserved-")
                    }
                )
                let recoveryURL = root.appendingPathComponent("assets/\(recoveryName)")
                try FileManager.default.moveItem(at: recoveryURL, to: retainedRacerURL)
                try FileManager.default.linkItem(at: retainedCreatedURL, to: recoveryURL)
            },
            eventHandler: { event in
                guard case .willRename = event else { return }
                try FileManager.default.moveItem(at: originalURL, to: retainedCreatedURL)
                try racerData.write(to: originalURL)
            }
        )

        let recoveryName = try XCTUnwrap(
            try imageAssetDirectoryEntries(in: root).first {
                $0.hasPrefix("Plainsong-preserved-")
            }
        )
        let recoveryURL = root.appendingPathComponent("assets/\(recoveryName)")
        XCTAssertEqual(try Data(contentsOf: retainedCreatedURL), createdData)
        XCTAssertEqual(try Data(contentsOf: retainedRacerURL), racerData)
        XCTAssertEqual(try Data(contentsOf: recoveryURL), createdData)
        XCTAssertTrue(outcome.didChangeWorkspace)
        XCTAssertTrue(outcome.issues.contains {
            $0.contains("an unavailable visible path")
                && $0.contains("cannot atomically prove which entry it acquired")
        }, outcome.issues.joined(separator: "\n"))
        XCTAssertTrue(outcome.issues.contains {
            $0.contains(recoveryURL.path(percentEncoded: false))
                || $0.contains(retainedCreatedURL.path(percentEncoded: false))
        }, outcome.issues.joined(separator: "\n"))
        XCTAssertFalse(outcome.issues.contains {
            $0.contains(retainedRacerURL.path(percentEncoded: false))
        }, outcome.issues.joined(separator: "\n"))
    }

    func testDiscardPostRenameMissingStillRefreshesWithoutArtifact() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let placement = try placeEditorImageAssets(
            assets: [.data(Data([1, 2, 3]), suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        )

        let outcome = discardEditorImageAssets(
            placement.createdAssets,
            rootURL: root,
            directorySynchronizer: { _ in },
            namespaceInspector: { _, _ in .missing },
            descriptorLinkInspector: { _ in .unlinked }
        )

        XCTAssertTrue(outcome.didChangeWorkspace)
        XCTAssertTrue(outcome.issues.contains {
            $0.contains("an unavailable visible path")
                && $0.contains("cannot atomically prove which entry it acquired")
        }, outcome.issues.joined(separator: "\n"))
        XCTAssertNotNil(outcome.userFacingIssue)
    }

    func testDiscardPostRenameInspectionFailureReportsIndeterminateArtifacts() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let placement = try placeEditorImageAssets(
            assets: [.data(Data([1, 2, 3]), suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        )

        let outcome = discardEditorImageAssets(
            placement.createdAssets,
            rootURL: root,
            directorySynchronizer: { _ in },
            namespaceInspector: { _, _ in
                .indeterminate("injected namespace inspection failure")
            },
            descriptorLinkInspector: { _ in
                .indeterminate("injected descriptor inspection failure")
            }
        )

        XCTAssertTrue(outcome.didChangeWorkspace)
        XCTAssertTrue(outcome.issues.contains {
            $0.contains("injected namespace inspection failure") &&
                $0.contains("unavailable visible path")
        }, outcome.issues.joined(separator: "\n"))
        XCTAssertTrue(outcome.issues.contains {
            $0.contains("injected descriptor inspection failure") &&
                $0.contains("unavailable visible path")
        }, outcome.issues.joined(separator: "\n"))
    }

    func testDiscardMissingLeafDoesNotTreatDescriptorInspectionFailureAsMissing() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let originalURL = root.appendingPathComponent("assets/image.png")
        let retainedCreatedURL = root.appendingPathComponent("created-original.png")
        let placement = try placeEditorImageAssets(
            assets: [.data(Data([1, 2, 3]), suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        )
        try FileManager.default.moveItem(at: originalURL, to: retainedCreatedURL)

        let outcome = discardEditorImageAssets(
            placement.createdAssets,
            rootURL: root,
            directorySynchronizer: { _ in },
            descriptorLinkInspector: { _ in
                .indeterminate("injected descriptor inspection failure")
            }
        )

        XCTAssertFalse(outcome.didChangeWorkspace)
        XCTAssertTrue(outcome.issues.contains {
            $0.contains("injected descriptor inspection failure") &&
                $0.contains("unavailable visible path")
        }, outcome.issues.joined(separator: "\n"))
    }

    func testDiscardRacePreservesReplacementWhenOriginalNameRemainsFree() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let createdData = Data([1, 2, 3])
        let replacementData = Data([9, 8, 7])
        let originalURL = root.appendingPathComponent("assets/image.png")
        let retainedCreatedURL = root.appendingPathComponent("created-original.png")
        let placement = try placeEditorImageAssets(
            assets: [.data(createdData, suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        )

        let outcome = discardEditorImageAssets(
            placement.createdAssets,
            rootURL: root
        ) { event in
            guard case .willRename = event else { return }
            try FileManager.default.moveItem(at: originalURL, to: retainedCreatedURL)
            try replacementData.write(to: originalURL)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertEqual(try Data(contentsOf: retainedCreatedURL), createdData)
        let recoveryName = try XCTUnwrap(try imageAssetDirectoryEntries(in: root).first)
        XCTAssertTrue(recoveryName.hasPrefix("Plainsong-preserved-"))
        let recoveryURL = root.appendingPathComponent("assets/\(recoveryName)")
        XCTAssertEqual(try Data(contentsOf: recoveryURL), replacementData)
        XCTAssertTrue(outcome.didChangeWorkspace)
        XCTAssertTrue(outcome.issues.contains {
            $0.contains(recoveryURL.path(percentEncoded: false))
        }, outcome.issues.joined(separator: "\n"))
        XCTAssertTrue(outcome.issues.contains {
            $0.contains(retainedCreatedURL.path(percentEncoded: false))
        }, outcome.issues.joined(separator: "\n"))
    }

    func testDiscardRaceNeverRenamesReplacementOfAcquiredRecoverySource() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let createdData = Data([1, 2, 3])
        let racerData = Data([9, 8, 7])
        let laterReplacementData = Data([4, 5, 6])
        let originalURL = root.appendingPathComponent("assets/image.png")
        let retainedCreatedURL = root.appendingPathComponent("created-original.png")
        let retainedRacerURL = root.appendingPathComponent("racer-original.png")
        let placement = try placeEditorImageAssets(
            assets: [.data(createdData, suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        )
        let outcome = discardEditorImageAssets(
            placement.createdAssets,
            rootURL: root
        ) { event in
            switch event {
            case .willRename:
                try FileManager.default.moveItem(at: originalURL, to: retainedCreatedURL)
                try racerData.write(to: originalURL)
            case let .didRename(_, recoveryLeafName):
                let acquiredURL = root.appendingPathComponent("assets/\(recoveryLeafName)")
                try FileManager.default.moveItem(at: acquiredURL, to: retainedRacerURL)
                try laterReplacementData.write(to: acquiredURL)
            case .didValidateRecovery:
                break
            }
        }

        let recoveryName = try XCTUnwrap(try imageAssetDirectoryEntries(in: root).first)
        let installedRecoveryURL = root.appendingPathComponent("assets/\(recoveryName)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertEqual(try Data(contentsOf: retainedCreatedURL), createdData)
        XCTAssertEqual(try Data(contentsOf: retainedRacerURL), racerData)
        XCTAssertEqual(try Data(contentsOf: installedRecoveryURL), laterReplacementData)
        XCTAssertTrue(outcome.didChangeWorkspace)
        XCTAssertTrue(outcome.issues.contains {
            $0.contains(retainedRacerURL.path(percentEncoded: false))
        }, outcome.issues.joined(separator: "\n"))
        XCTAssertTrue(outcome.issues.contains {
            $0.contains(retainedCreatedURL.path(percentEncoded: false))
        }, outcome.issues.joined(separator: "\n"))
    }

    func testDiscardRaceReportsSymlinkRecoveryPathWhenRestoreIsBlocked() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        let targetURL = root.appendingPathComponent("target.png")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        try Data([7, 7, 7]).write(to: targetURL)
        let originalURL = root.appendingPathComponent("assets/image.png")
        let retainedCreatedURL = root.appendingPathComponent("created-original.png")
        let placement = try placeEditorImageAssets(
            assets: [.data(Data([1, 2, 3]), suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        )

        let outcome = discardEditorImageAssets(
            placement.createdAssets,
            rootURL: root
        ) { event in
            switch event {
            case .willRename:
                try FileManager.default.moveItem(at: originalURL, to: retainedCreatedURL)
                try FileManager.default.createSymbolicLink(at: originalURL, withDestinationURL: targetURL)
            case .didRename:
                try Data([4, 5, 6]).write(to: originalURL)
            case .didValidateRecovery:
                break
            }
        }

        let recoveryName = try XCTUnwrap(try imageAssetDirectoryEntries(in: root).first {
            $0.hasPrefix("Plainsong-preserved-")
        })
        let recoveryURL = root.appendingPathComponent("assets/\(recoveryName)")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: recoveryURL.path),
            targetURL.path
        )
        XCTAssertTrue(outcome.didChangeWorkspace)
        XCTAssertTrue(outcome.issues.contains {
            $0.contains(recoveryURL.path(percentEncoded: false))
        }, outcome.issues.joined(separator: "\n"))
    }

    func testDiscardRaceDoesNotAttributeReplacementPathToMovedSymlink() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        let firstTargetURL = root.appendingPathComponent("target-a.png")
        let secondTargetURL = root.appendingPathComponent("target-b.png")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        try Data([7, 7, 7]).write(to: firstTargetURL)
        try Data([8, 8, 8]).write(to: secondTargetURL)
        let originalURL = root.appendingPathComponent("assets/image.png")
        let retainedCreatedURL = root.appendingPathComponent("created-original.png")
        let movedSymlinkURL = root.appendingPathComponent("racer-link")
        let placement = try placeEditorImageAssets(
            assets: [.data(Data([1, 2, 3]), suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        )
        let outcome = discardEditorImageAssets(
            placement.createdAssets,
            rootURL: root
        ) { event in
            switch event {
            case .willRename:
                try FileManager.default.moveItem(at: originalURL, to: retainedCreatedURL)
                try FileManager.default.createSymbolicLink(
                    at: originalURL,
                    withDestinationURL: firstTargetURL
                )
            case let .didRename(_, recoveryLeafName):
                let acquiredURL = root.appendingPathComponent("assets/\(recoveryLeafName)")
                try FileManager.default.moveItem(at: acquiredURL, to: movedSymlinkURL)
                try FileManager.default.createSymbolicLink(
                    at: acquiredURL,
                    withDestinationURL: secondTargetURL
                )
            case .didValidateRecovery:
                break
            }
        }

        let recoveryName = try XCTUnwrap(try imageAssetDirectoryEntries(in: root).first)
        let installedRecoveryURL = root.appendingPathComponent("assets/\(recoveryName)")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: movedSymlinkURL.path),
            firstTargetURL.path
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: installedRecoveryURL.path
            ),
            secondTargetURL.path
        )
        XCTAssertTrue(outcome.didChangeWorkspace)
        XCTAssertTrue(outcome.issues.contains {
            $0.contains("unavailable visible path") && !$0.contains(installedRecoveryURL.path)
        }, outcome.issues.joined(separator: "\n"))
        XCTAssertTrue(outcome.issues.contains {
            $0.contains(retainedCreatedURL.path(percentEncoded: false))
        }, outcome.issues.joined(separator: "\n"))
    }

    func testPreservedNamespaceLocationDoesNotAdoptLaterRegularOccupant() throws {
        let root = try makeTemporaryDirectory()
        let assetsDirectory = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(
            at: assetsDirectory,
            withIntermediateDirectories: false
        )
        let leafURL = assetsDirectory.appendingPathComponent("image.png")
        let retainedURL = root.appendingPathComponent("retained-image.png")
        try Data([1, 2, 3]).write(to: leafURL)
        let capturedStatus = try fileStatus(at: leafURL)
        let capturedIdentity = WorkspaceFileSystemIdentity(
            device: UInt64(capturedStatus.st_dev),
            inode: UInt64(capturedStatus.st_ino)
        )
        let directoryDescriptor = Darwin.open(
            assetsDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(directoryDescriptor, 0)
        defer { Darwin.close(directoryDescriptor) }
        try FileManager.default.moveItem(at: leafURL, to: retainedURL)
        try Data([9, 8, 7]).write(to: leafURL)

        let location = editorImageAssetPreservedLocationForNamespaceEntry(
            directoryDescriptor: directoryDescriptor,
            leafName: "image.png",
            fallbackIdentity: capturedIdentity
        )

        XCTAssertNil(location.currentPath)
        XCTAssertEqual(location.identity, capturedIdentity)
        XCTAssertNotEqual(location.currentPath, leafURL.path(percentEncoded: false))
    }

    func testDiscardRaceReportsDirectoryRecoveryPathWhenRestoreIsBlocked() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let assetsDirectory = root.appendingPathComponent("assets", isDirectory: true)
        let retainedDirectory = root.appendingPathComponent("assets-old", isDirectory: true)
        let originalURL = assetsDirectory.appendingPathComponent("image.png")
        let retainedCreatedURL = root.appendingPathComponent("created-original.png")
        let placement = try placeEditorImageAssets(
            assets: [.data(Data([1, 2, 3]), suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        )

        let outcome = discardEditorImageAssets(
            placement.createdAssets,
            rootURL: root
        ) { event in
            switch event {
            case .willRename:
                try FileManager.default.moveItem(at: originalURL, to: retainedCreatedURL)
                try FileManager.default.createDirectory(
                    at: originalURL,
                    withIntermediateDirectories: false
                )
            case .didRename:
                try FileManager.default.moveItem(at: assetsDirectory, to: retainedDirectory)
                try FileManager.default.createDirectory(
                    at: assetsDirectory,
                    withIntermediateDirectories: false
                )
                try Data([4, 5, 6]).write(
                    to: retainedDirectory.appendingPathComponent("image.png")
                )
            case .didValidateRecovery:
                break
            }
        }

        let recoveryName = try XCTUnwrap(try directoryEntries(at: retainedDirectory).first {
            $0.hasPrefix("Plainsong-preserved-")
        })
        let recoveryURL = retainedDirectory.appendingPathComponent(recoveryName)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryURL.path,
            isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(outcome.didChangeWorkspace)
        XCTAssertTrue(outcome.issues.contains {
            $0.contains("/assets-old/\(recoveryName)") &&
                !$0.contains("unavailable visible path")
        }, outcome.issues.joined(separator: "\n"))
    }

    func testDiscardNeverUnlinksReplacementInstalledAfterExactRecoveryValidation() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let createdData = Data([1, 2, 3])
        let replacementData = Data([9, 8, 7])
        let assetsDirectory = root.appendingPathComponent("assets", isDirectory: true)
        let retainedCreatedURL = assetsDirectory.appendingPathComponent("retained-created.png")
        let placement = try placeEditorImageAssets(
            assets: [.data(createdData, suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        )

        let outcome = discardEditorImageAssets(
            placement.createdAssets,
            rootURL: root
        ) { event in
            guard case let .didValidateRecovery(recoveryLeafName) = event else { return }
            let recoveryURL = assetsDirectory.appendingPathComponent(recoveryLeafName)
            try FileManager.default.moveItem(at: recoveryURL, to: retainedCreatedURL)
            try replacementData.write(to: recoveryURL)
        }

        let recoveryName = try XCTUnwrap(
            directoryEntries(at: assetsDirectory).first {
                $0.hasPrefix("Plainsong-preserved-")
            }
        )
        let installedReplacementURL = assetsDirectory.appendingPathComponent(recoveryName)
        XCTAssertEqual(try Data(contentsOf: retainedCreatedURL), createdData)
        XCTAssertEqual(try Data(contentsOf: installedReplacementURL), replacementData)
        XCTAssertTrue(outcome.didChangeWorkspace)
        XCTAssertTrue(
            outcome.issues.contains {
                $0.contains(retainedCreatedURL.path(percentEncoded: false)) &&
                    $0.contains("no file was removed")
            }
        )
    }

    func testDiscardReportsMovedDirectoryPathForSameInodeRewrite() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let placement = try placeEditorImageAssets(
            assets: [.data(Data([1, 2, 3]), suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        )
        let assetsDirectory = root.appendingPathComponent("assets", isDirectory: true)
        let retainedDirectory = root.appendingPathComponent("assets-old", isDirectory: true)
        try FileManager.default.moveItem(at: assetsDirectory, to: retainedDirectory)
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: false)
        let retainedImage = retainedDirectory.appendingPathComponent("image.png")
        let rewrittenData = Data([7, 8, 9])
        let handle = try FileHandle(forWritingTo: retainedImage)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: rewrittenData)
        try handle.synchronize()
        try handle.close()

        let outcome = discardEditorImageAssets(placement.createdAssets, rootURL: root)

        let entries = try directoryEntries(at: retainedDirectory)
        let recoveryName = try XCTUnwrap(entries.first)
        let recoveryURL = retainedDirectory.appendingPathComponent(recoveryName)
        XCTAssertEqual(entries, [recoveryName])
        XCTAssertTrue(recoveryName.hasPrefix("Plainsong-preserved-"))
        XCTAssertEqual(try Data(contentsOf: recoveryURL), rewrittenData)
        XCTAssertEqual(try directoryEntries(at: assetsDirectory), [])
        XCTAssertTrue(outcome.issues.contains { $0.contains(recoveryURL.path(percentEncoded: false)) })
        XCTAssertFalse(outcome.issues.contains {
            $0.contains(assetsDirectory.appendingPathComponent(recoveryName).path(percentEncoded: false))
        })
    }

    func testEditorImageAssetPlacementDoesNotOverwriteExclusiveCreateRaceWinner() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let winnerData = Data([9, 8, 7])
        let insertedData = Data([1, 2, 3])

        let placement = try placeEditorImageAssets(
            assets: [.data(insertedData, suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        ) { event in
            guard case let .willPublish(candidateURL) = event,
                  candidateURL.lastPathComponent == "image.png"
            else {
                return
            }
            guard FileManager.default.createFile(
                atPath: candidateURL.path(percentEncoded: false),
                contents: winnerData
            ) else {
                throw CocoaError(.fileWriteFileExists)
            }
        }

        XCTAssertEqual(placement.relativePaths, ["assets/image-1.png"])
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("assets/image.png")),
            winnerData
        )
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("assets/image-1.png")),
            insertedData
        )
        XCTAssertEqual(
            try imageAssetDirectoryEntries(in: root),
            ["image-1.png", "image.png"]
        )
    }

    func testWorkspaceImageReferenceRejectsParentReplacementAfterAuthorityCapture() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let mediaDirectory = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mediaDirectory,
            withIntermediateDirectories: false
        )
        let sourceURL = mediaDirectory.appendingPathComponent("image.png")
        let sourceData = Data([1, 2, 3])
        try sourceData.write(to: sourceURL)
        let retainedDirectory = root.appendingPathComponent("media-original", isDirectory: true)

        XCTAssertThrowsError(try placeEditorImageAssets(
            assets: [.file(sourceURL)],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        ) { event in
            guard case .didCaptureWorkspaceReference = event else { return }
            try FileManager.default.moveItem(at: mediaDirectory, to: retainedDirectory)
            try FileManager.default.createDirectory(
                at: mediaDirectory,
                withIntermediateDirectories: false
            )
            try FileManager.default.linkItem(
                at: retainedDirectory.appendingPathComponent("image.png"),
                to: mediaDirectory.appendingPathComponent("image.png")
            )
        })

        let replacementURL = mediaDirectory.appendingPathComponent("image.png")
        XCTAssertEqual(try Data(contentsOf: replacementURL), sourceData)
        let replacementStatus = try fileStatus(at: replacementURL)
        let retainedStatus = try fileStatus(
            at: retainedDirectory.appendingPathComponent("image.png")
        )
        XCTAssertEqual(replacementStatus.st_dev, retainedStatus.st_dev)
        XCTAssertEqual(replacementStatus.st_ino, retainedStatus.st_ino)
    }

    func testEditorImageAssetPlacementRejectsAssetDirectoryReplacementBeforePublish() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let assetsDirectory = root.appendingPathComponent("assets", isDirectory: true)
        let relocatedDirectory = root.appendingPathComponent(
            "assets-before-publish",
            isDirectory: true
        )

        XCTAssertThrowsError(try placeEditorImageAssets(
            assets: [.data(Data([1, 2, 3]), suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        ) { event in
            guard case .willPublish = event else { return }
            try FileManager.default.moveItem(at: assetsDirectory, to: relocatedDirectory)
            try FileManager.default.createDirectory(
                at: assetsDirectory,
                withIntermediateDirectories: false
            )
        })

        XCTAssertEqual(try directoryEntries(at: assetsDirectory), [])
        let entries = try directoryEntries(at: relocatedDirectory)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries.allSatisfy { $0.hasPrefix("Plainsong-preserved-") })
    }

    func testEditorImageAssetPlacementRollsBackAssetDirectoryMovedImmediatelyAfterRename() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let assetsDirectory = root.appendingPathComponent("assets", isDirectory: true)
        let relocatedDirectory = root.appendingPathComponent(
            "assets-after-rename",
            isDirectory: true
        )

        XCTAssertThrowsError(try placeEditorImageAssets(
            assets: [.data(Data([1, 2, 3]), suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        ) { event in
            guard case .didRenameBeforeValidation = event else { return }
            try FileManager.default.moveItem(at: assetsDirectory, to: relocatedDirectory)
            try FileManager.default.createDirectory(
                at: assetsDirectory,
                withIntermediateDirectories: false
            )
        })

        XCTAssertEqual(try directoryEntries(at: assetsDirectory), [])
        let entries = try directoryEntries(at: relocatedDirectory)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries.allSatisfy { $0.hasPrefix("Plainsong-preserved-") })
    }

    func testDidPublishAssetDirectoryMoveCannotReturnStaleEditorImageReference() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let assetsDirectory = root.appendingPathComponent("assets", isDirectory: true)
        let relocatedDirectory = root.appendingPathComponent(
            "assets-after-publish-callback",
            isDirectory: true
        )

        XCTAssertThrowsError(try placeEditorImageAssets(
            assets: [.data(Data([1, 2, 3]), suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        ) { event in
            guard case .didPublish = event else { return }
            try FileManager.default.moveItem(at: assetsDirectory, to: relocatedDirectory)
            try FileManager.default.createDirectory(
                at: assetsDirectory,
                withIntermediateDirectories: false
            )
        })

        XCTAssertEqual(try directoryEntries(at: assetsDirectory), [])
        let entries = try directoryEntries(at: relocatedDirectory)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries.allSatisfy { $0.hasPrefix("Plainsong-preserved-") })
    }

    func testEditorImageAssetPlacementRejectsReplacedStagingName() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let replacementData = Data([9, 8, 7])

        XCTAssertThrowsError(try placeEditorImageAssets(
            assets: [.data(Data([1, 2, 3]), suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        ) { event in
            guard case let .willPublish(candidateURL) = event else { return }
            let directory = candidateURL.deletingLastPathComponent()
            let stagingURL = try XCTUnwrap(
                FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                ).first { $0.lastPathComponent.hasPrefix(".plainsong-image-stage-") }
            )
            try FileManager.default.removeItem(at: stagingURL)
            try replacementData.write(to: stagingURL)
        })

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("assets/image.png").path(percentEncoded: false)
        ))
        let entries = try imageAssetDirectoryEntries(in: root)
        let preservedName = try XCTUnwrap(entries.first)
        let preservedURL = root.appendingPathComponent("assets/\(preservedName)")
        XCTAssertEqual(try Data(contentsOf: preservedURL), replacementData)
        XCTAssertEqual(entries, [preservedURL.lastPathComponent])
    }

    func testPlacementRollbackMarksPreservedOriginalAsWorkspaceChange() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let assetsDirectory = root.appendingPathComponent("assets", isDirectory: true)
        let createdData = Data([1, 2, 3])
        defer {
            _ = assetsDirectory.path(percentEncoded: false).withCString {
                Darwin.chmod($0, mode_t(0o755))
            }
        }

        do {
            _ = try placeEditorImageAssets(
                assets: [.data(createdData, suggestedFilename: "image.png")],
                assetFolderRelativePath: "assets",
                rootURL: root,
                currentFileURL: currentFile
            ) { event in
                guard case let .didRenameBeforeValidation(candidateURL) = event else {
                    return
                }
                let result = candidateURL.deletingLastPathComponent()
                    .path(percentEncoded: false)
                    .withCString { Darwin.chmod($0, mode_t(0o555)) }
                guard result == 0 else { throw CocoaError(.fileWriteNoPermission) }
                throw CocoaError(.fileWriteUnknown)
            }
            XCTFail("Expected placement rollback")
        } catch {
            let rollbackError = try XCTUnwrap(
                error as? EditorImageAssetPlacementRollbackError
            )
            XCTAssertTrue(rollbackError.didChangeWorkspace)
            XCTAssertTrue(rollbackError.cleanupDescriptions.contains {
                $0.contains("staging file preserved") && $0.contains("image.png")
            })
        }

        let publishedURL = assetsDirectory.appendingPathComponent("image.png")
        XCTAssertEqual(try Data(contentsOf: publishedURL), createdData)
        XCTAssertEqual(try directoryEntries(at: assetsDirectory), ["image.png"])
    }

    func testPlacementRollbackMarksPreflightArtifactsAsWorkspaceChange() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let assetsDirectory = root.appendingPathComponent("assets", isDirectory: true)
        let retainedCreatedURL = root.appendingPathComponent("retained-created.png")
        let createdData = Data([1, 2, 3])
        let replacementData = Data([9, 8, 7])

        do {
            _ = try placeEditorImageAssets(
                assets: [.data(createdData, suggestedFilename: "image.png")],
                assetFolderRelativePath: "assets",
                rootURL: root,
                currentFileURL: currentFile
            ) { event in
                guard case let .didRenameBeforeValidation(candidateURL) = event else {
                    return
                }
                try FileManager.default.moveItem(at: candidateURL, to: retainedCreatedURL)
                try replacementData.write(to: candidateURL)
                throw CocoaError(.fileWriteUnknown)
            }
            XCTFail("Expected placement rollback")
        } catch {
            let rollbackError = try XCTUnwrap(
                error as? EditorImageAssetPlacementRollbackError
            )
            XCTAssertTrue(rollbackError.didChangeWorkspace)
            XCTAssertTrue(rollbackError.cleanupDescriptions.contains {
                $0.contains(
                    assetsDirectory.appendingPathComponent("image.png")
                        .path(percentEncoded: false)
                ) && $0.contains(retainedCreatedURL.path(percentEncoded: false))
            })
        }

        let replacementURL = assetsDirectory.appendingPathComponent("image.png")
        XCTAssertEqual(try Data(contentsOf: replacementURL), replacementData)
        XCTAssertEqual(try Data(contentsOf: retainedCreatedURL), createdData)
        XCTAssertEqual(try directoryEntries(at: assetsDirectory), ["image.png"])
    }

    func testDidPublishFailureRollsBackCurrentEditorImageAssetAndArtifacts() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try placeEditorImageAssets(
            assets: [.data(Data([1, 2, 3]), suggestedFilename: "image.png")],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        ) { event in
            guard case .didPublish = event else { return }
            throw CocoaError(.fileWriteUnknown)
        })

        let entries = try imageAssetDirectoryEntries(in: root)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries.allSatisfy { $0.hasPrefix("Plainsong-preserved-") })
    }

    func testSecondDidPublishFailureRollsBackAllEditorImageAssetsAndArtifacts() throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try placeEditorImageAssets(
            assets: [
                .data(Data([1, 2, 3]), suggestedFilename: "first.png"),
                .data(Data([4, 5, 6]), suggestedFilename: "second.png"),
            ],
            assetFolderRelativePath: "assets",
            rootURL: root,
            currentFileURL: currentFile
        ) { event in
            guard case let .didPublish(publishedURL) = event,
                  publishedURL.lastPathComponent == "second.png"
            else {
                return
            }
            throw CocoaError(.fileWriteUnknown)
        })

        let entries = try imageAssetDirectoryEntries(in: root)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.hasPrefix("Plainsong-preserved-") })
    }

    func testFailedMultiAssetInsertionRollsBackEarlierCreatedAsset() async throws {
        let root = try makeTemporaryDirectory()
        let currentFile = root.appendingPathComponent("post.md")
        try "Body".write(to: currentFile, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: "Body", url: currentFile, fileKind: .markdown)
        let appState = AppState(currentDocument: session)
        try configureImageAssetWorkspace(
            appState,
            rootURL: root,
            currentSession: session
        )
        let initialWorkspaceGeneration = appState.workspaceGeneration

        let inserter = try XCTUnwrap(appState.editorImageAssetInserter)
        let insertion = await inserter([
            .data(Data([1, 2, 3]), suggestedFilename: "image.png"),
            .data(Data([4, 5, 6]), suggestedFilename: "not-an-image.txt"),
        ])

        XCTAssertTrue(insertion.relativePaths.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("assets/image.png").path(percentEncoded: false)
        ))
        let entries = try imageAssetDirectoryEntries(in: root)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries.allSatisfy { $0.hasPrefix("Plainsong-preserved-") })
        XCTAssertEqual(appState.presentedError?.title, "Could Not Insert Image")
        XCTAssertGreaterThan(appState.workspaceGeneration, initialWorkspaceGeneration)
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
        } catch WorkspaceAnchoredFileSystemError.namespaceChanged {
            // A real final root-proof failure must reach the normal error path.
        } catch {
            XCTFail("Expected namespaceChanged, got \(error)")
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
        appState.retiredEditorDocumentSessions[post] = RetiredEditorDocumentSession(
            canonicalURL: post,
            session: sessionA,
            bindingIDs: [retiredBindingID],
            awaitingInstallations: [],
            securityScopedAuthorityOwners: []
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
        XCTAssertTrue(appState.retiredEditorDocumentSessions[post]?.session === sessionA)
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

    func testAnchoredMissingDocumentCanSaveCopyBackToItsOriginalProvenMissingPath() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appendingPathComponent("post.md").standardizedFileURL
        try writeText("disk A", to: originalURL)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let originalLocation = try authority.location(relativePath: "post.md")
        let originalRead = try MarkdownFileStore().loadResult(at: originalLocation)
        let session = DocumentSession(
            text: "unsaved A",
            url: originalURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.sessionCache[originalURL] = session
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] =
            AnchoredWorkspaceSessionFileBinding(
                location: originalLocation,
                identity: originalRead.metadata.identity,
                sha256Digest: originalRead.sha256Digest
            )
        try FileManager.default.removeItem(at: originalURL)
        appState.markSessionDetachedFromMissingFile(session, url: originalURL)
        var expectations: [WorkspaceNoFollowFileWriteExpectation] = []
        appState.anchoredFileSaveOverride = { text, location, expectation in
            expectations.append(expectation)
            return try MarkdownFileStore().save(text: text, at: location, expecting: expectation)
        }

        try appState.saveDetachedCurrentDocument(to: originalURL)

        XCTAssertEqual(expectations, [.missing])
        XCTAssertEqual(try String(contentsOf: originalURL, encoding: .utf8), "unsaved A")
        XCTAssertFalse(session.isDirty)
        XCTAssertNil(appState.missingFilePrompt)
        let inserter = try XCTUnwrap(appState.editorImageAssetInserter)
        let insertion = await inserter([
            .data(Data([1, 2, 3]), suggestedFilename: "recovered.png"),
        ])
        XCTAssertEqual(insertion.relativePaths, ["assets/recovered.png"])
        let remainsAuthorized = await insertion.validateBeforeCommit()
        XCTAssertTrue(remainsAuthorized)
        await insertion.discard()
    }

    func testUnanchoredMissingDocumentCanSaveCopyBackToItsOriginalProvenMissingPath() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appendingPathComponent("post.md").standardizedFileURL
        try writeText("disk standalone", to: originalURL)
        let session = DocumentSession(
            text: "unsaved standalone",
            url: originalURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.sessionCache[originalURL] = session
        try FileManager.default.removeItem(at: originalURL)
        appState.markSessionDetachedFromMissingFile(session, url: originalURL)
        var expectations: [WorkspaceNoFollowFileWriteExpectation] = []
        appState.anchoredFileSaveOverride = { text, location, expectation in
            expectations.append(expectation)
            return try MarkdownFileStore().save(text: text, at: location, expecting: expectation)
        }

        try appState.saveDetachedCurrentDocument(to: originalURL)

        XCTAssertEqual(expectations, [.missing])
        XCTAssertEqual(try String(contentsOf: originalURL, encoding: .utf8), "unsaved standalone")
        XCTAssertFalse(session.isDirty)
    }

    func testAnchoredMissingDocumentWithNFCSpellingRecoversToExactNFCSpelling() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nfcName = "caf\u{00E9}.md"
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let originalLocation = try authority.location(relativePath: nfcName)
        // Use the retained, lexically constructed URL rather than `.appendingPathComponent`:
        // the latter decomposes NFC to NFD immediately at construction via CoreFoundation's
        // file-system-representation bridging, before any Plainsong code runs, which would
        // not exercise the round trip through `relativePath(forFileURL:)` this test targets.
        let originalURL = originalLocation.fileURL
        try writeText("disk A", to: originalURL)
        let originalRead = try MarkdownFileStore().loadResult(at: originalLocation)
        let session = DocumentSession(
            text: "unsaved A",
            url: originalURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.sessionCache[originalURL] = session
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] =
            AnchoredWorkspaceSessionFileBinding(
                location: originalLocation,
                identity: originalRead.metadata.identity,
                sha256Digest: originalRead.sha256Digest
            )
        try FileManager.default.removeItem(at: originalURL)
        appState.markSessionDetachedFromMissingFile(session, url: originalURL)
        var expectations: [WorkspaceNoFollowFileWriteExpectation] = []
        appState.anchoredFileSaveOverride = { text, location, expectation in
            expectations.append(expectation)
            return try MarkdownFileStore().save(text: text, at: location, expecting: expectation)
        }

        let nfdAlternativeURL = try authority.location(
            relativePath: "cafe\u{0301}.md"
        ).fileURL
        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: nfdAlternativeURL))
        XCTAssertTrue(expectations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nfdAlternativeURL.path))
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(appState.missingFilePrompt?.fileURL, originalURL)

        // The panel-returned URL carries the exact NFC bytes the user typed/selected, matching
        // the retained NFC-spelled location. Recognizing this as the exact missing source
        // (rather than corrupting it to NFD via `relativePath(forFileURL:)` and spuriously
        // failing the retained-location match) is what lets `.missing` be used instead of a
        // rejected `invalidSessionIdentity`.
        try appState.saveDetachedCurrentDocument(to: originalURL)

        XCTAssertEqual(expectations, [.missing])
        XCTAssertEqual(try String(contentsOf: originalURL, encoding: .utf8), "unsaved A")
        XCTAssertFalse(session.isDirty)
        XCTAssertNil(appState.missingFilePrompt)
    }

    func testUnanchoredMissingDocumentWithNFCSpellingRecoversToExactNFCSpelling() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nfcName = "caf\u{00E9}.md"
        // Use a retained, lexically constructed URL rather than `.appendingPathComponent`: the
        // latter decomposes NFC to NFD immediately at construction, before any Plainsong code
        // runs, which would not exercise the round trip through
        // `WorkspaceFileSystemLocation(fileURL:)` this test targets.
        let originalURL = try WorkspaceFileSystemRootAuthority(rootURL: root)
            .location(relativePath: nfcName)
            .fileURL
        try writeText("disk standalone", to: originalURL)
        let session = DocumentSession(
            text: "unsaved standalone",
            url: originalURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.sessionCache[originalURL] = session
        try FileManager.default.removeItem(at: originalURL)
        appState.markSessionDetachedFromMissingFile(session, url: originalURL)
        var expectations: [WorkspaceNoFollowFileWriteExpectation] = []
        appState.anchoredFileSaveOverride = { text, location, expectation in
            expectations.append(expectation)
            return try MarkdownFileStore().save(text: text, at: location, expecting: expectation)
        }

        let nfdAlternativeURL = try WorkspaceFileSystemRootAuthority(rootURL: root)
            .location(relativePath: "cafe\u{0301}.md")
            .fileURL
        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: nfdAlternativeURL))
        XCTAssertTrue(expectations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nfdAlternativeURL.path))
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(appState.missingFilePrompt?.fileURL, originalURL)

        // Standalone (non-workspace) recovery goes through `WorkspaceFileSystemLocation(fileURL:)`
        // rather than `relativePath(forFileURL:)`; the exact NFC round trip must hold there too.
        try appState.saveDetachedCurrentDocument(to: originalURL)

        XCTAssertEqual(expectations, [.missing])
        XCTAssertEqual(try String(contentsOf: originalURL, encoding: .utf8), "unsaved standalone")
        XCTAssertFalse(session.isDirty)
    }

    func testOrdinaryStandaloneNFCSaveCopyRetainsExactLocationAndRejectsNFDAlternative() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let nfcLocation = try authority.location(relativePath: "caf\u{00E9}.md")
        guard case .committedAndDurable = WorkspaceNoFollowFileWriter.write(
            text: "disk NFC",
            to: nfcLocation,
            expecting: .missing
        ) else {
            return XCTFail("test setup must create the NFC source through literal UTF-8 bytes")
        }

        let appState = AppState(shouldRestoreLastOpenedFile: false)
        appState.openExternalFile(nfcLocation.fileURL)
        try await waitUntil("ordinary standalone NFC file opens") {
            appState.currentDocument.fileURL?.path(percentEncoded: false).utf8.elementsEqual(
                nfcLocation.fileURL.path(percentEncoded: false).utf8
            ) == true
        }
        let session = appState.currentDocument
        XCTAssertEqual(
            appState.sessionStateURL(for: session)?.path(percentEncoded: false).utf8.map(\.self),
            nfcLocation.fileURL.path(percentEncoded: false).utf8.map(\.self)
        )
        guard case let .proven(retainedProof)? =
            appState.unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(session)]
        else {
            return XCTFail("ordinary standalone opening must retain a descriptor-bound proof")
        }
        XCTAssertEqual(retainedProof.location, nfcLocation)

        appState.replaceDocumentText("local NFC edits")
        try FileManager.default.removeItem(at: nfcLocation.fileURL)
        appState.handleExternalChange(for: session)
        try await waitUntil("ordinary standalone NFC file detaches at the exact spelling") {
            appState.missingFilePrompt?.fileURL.path(percentEncoded: false).utf8.elementsEqual(
                nfcLocation.fileURL.path(percentEncoded: false).utf8
            ) == true
        }
        XCTAssertEqual(
            appState.missingFilePrompt?.fileURL.path(percentEncoded: false).utf8.map(\.self),
            nfcLocation.fileURL.path(percentEncoded: false).utf8.map(\.self)
        )

        let nfdAlternative = try authority.location(relativePath: "cafe\u{0301}.md")
        var expectations: [WorkspaceNoFollowFileWriteExpectation] = []
        appState.anchoredFileSaveOverride = { text, location, expectation in
            expectations.append(expectation)
            return try MarkdownFileStore().save(text: text, at: location, expecting: expectation)
        }
        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: nfdAlternative.fileURL))
        XCTAssertTrue(expectations.isEmpty)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(
            appState.missingFilePrompt?.fileURL.path(percentEncoded: false).utf8.map(\.self),
            nfcLocation.fileURL.path(percentEncoded: false).utf8.map(\.self)
        )

        try appState.saveDetachedCurrentDocument(to: nfcLocation.fileURL)
        XCTAssertEqual(expectations, [.missing])
        XCTAssertEqual(try MarkdownFileStore().loadResult(at: nfcLocation).file.text, "local NFC edits")
    }

    func testStandaloneAliasUsesCanonicalCacheKeyWithoutChangingNFCLeafBytes() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("source-root", isDirectory: true)
        let alias = parent.appendingPathComponent("source-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let nfcLocation = try authority.location(relativePath: "caf\u{00E9}.md")
        guard case .committedAndDurable = WorkspaceNoFollowFileWriter.write(
            text: "disk NFC",
            to: nfcLocation,
            expecting: .missing
        ) else {
            return XCTFail("test setup must create the NFC source through literal UTF-8 bytes")
        }

        let aliasBaseURL = alias.absoluteString.hasSuffix("/")
            ? alias.absoluteString
            : "\(alias.absoluteString)/"
        let aliasURL = try XCTUnwrap(URL(string: "\(aliasBaseURL)caf%C3%A9.md"))
        let aliasPath = alias.path(percentEncoded: false)
        let literalAliasPath = aliasPath.hasSuffix("/") ? String(aliasPath.dropLast()) : aliasPath
        XCTAssertEqual(
            aliasURL.path(percentEncoded: false).utf8.map(\.self),
            "\(literalAliasPath)/caf\u{00E9}.md".utf8.map(\.self)
        )
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        defer {
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
        }

        try appState.activateFileSession(url: aliasURL)
        let firstSession = appState.currentDocument
        let firstProof = try XCTUnwrap(
            appState.unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(firstSession)]
        )
        XCTAssertTrue(appState.sessionCache[nfcLocation.fileURL] === firstSession)
        XCTAssertNil(appState.sessionCache[aliasURL])
        XCTAssertEqual(
            appState.sessionStateURL(for: firstSession)?.path(percentEncoded: false).utf8.map(\.self),
            nfcLocation.fileURL.path(percentEncoded: false).utf8.map(\.self)
        )

        try appState.activateFileSession(url: aliasURL)

        XCTAssertTrue(appState.currentDocument === firstSession)
        XCTAssertEqual(
            appState.unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(firstSession)],
            firstProof
        )
    }

    func testOrdinaryAnchoredNFCSaveCopyRetainsExactLocationAndRejectsNFDAlternative() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let setupAuthority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let nfcLocation = try setupAuthority.location(relativePath: "caf\u{00E9}.md")
        guard case .committedAndDurable = WorkspaceNoFollowFileWriter.write(
            text: "disk NFC",
            to: nfcLocation,
            expecting: .missing
        ) else {
            return XCTFail("test setup must create the NFC source through literal UTF-8 bytes")
        }

        let appState = AppState(shouldRestoreLastOpenedFile: false)
        defer {
            appState.workspaceReloadTask?.cancel()
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
        }
        appState.openExternalFile(root)
        try await waitUntil("ordinary NFC workspace activation") {
            guard let binding = appState.anchoredSessionFileBinding(for: appState.currentDocument)
            else {
                return false
            }
            return binding.location.relativePath.utf8.elementsEqual("caf\u{00E9}.md".utf8)
                && appState.currentDocument.text == "disk NFC"
        }

        let session = appState.currentDocument
        let retainedLocation = try XCTUnwrap(appState.anchoredSessionFileBinding(for: session)?.location)
        XCTAssertEqual(
            retainedLocation.fileURL.path(percentEncoded: false).utf8.map(\.self),
            nfcLocation.fileURL.path(percentEncoded: false).utf8.map(\.self)
        )
        appState.replaceDocumentText("local anchored NFC edits", in: session)
        try FileManager.default.removeItem(at: retainedLocation.fileURL)
        appState.handleExternalChange(for: session)
        try await waitUntil("ordinary anchored NFC file detaches at the exact spelling") {
            appState.missingFilePrompt?.fileURL.path(percentEncoded: false).utf8.elementsEqual(
                retainedLocation.fileURL.path(percentEncoded: false).utf8
            ) == true
        }
        XCTAssertEqual(
            appState.missingFilePrompt?.fileURL.path(percentEncoded: false).utf8.map(\.self),
            retainedLocation.fileURL.path(percentEncoded: false).utf8.map(\.self)
        )

        let nfdAlternative = try retainedLocation.rootAuthority.location(
            relativePath: "cafe\u{0301}.md"
        )
        var expectations: [WorkspaceNoFollowFileWriteExpectation] = []
        appState.anchoredFileSaveOverride = { text, location, expectation in
            expectations.append(expectation)
            return try MarkdownFileStore().save(text: text, at: location, expecting: expectation)
        }
        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: nfdAlternative.fileURL))
        XCTAssertTrue(expectations.isEmpty)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(
            appState.missingFilePrompt?.fileURL.path(percentEncoded: false).utf8.map(\.self),
            retainedLocation.fileURL.path(percentEncoded: false).utf8.map(\.self)
        )

        try appState.saveDetachedCurrentDocument(to: retainedLocation.fileURL)
        XCTAssertEqual(expectations, [.missing])
        XCTAssertEqual(
            try MarkdownFileStore().loadResult(at: retainedLocation).file.text,
            "local anchored NFC edits"
        )
    }

    func testUnanchoredOrdinarySaveRejectsReplacementInodeWithoutTouchingIt() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let documentURL = root.appendingPathComponent("post.md").standardizedFileURL
        try writeText("loaded A", to: documentURL)
        let session = DocumentSession(
            text: "edited A",
            url: documentURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.sessionCache[documentURL] = session

        try FileManager.default.removeItem(at: documentURL)
        try writeText("replacement B", to: documentURL)

        XCTAssertThrowsError(try appState.saveCurrentDocument())
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), "replacement B")
        XCTAssertTrue(session.isDirty)
    }

    func testUnanchoredOrdinarySaveUsesExactLoadedContentDigest() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let documentURL = root.appendingPathComponent("post.md").standardizedFileURL
        try writeText("loaded A", to: documentURL)
        let session = DocumentSession(
            text: "edited A",
            url: documentURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.sessionCache[documentURL] = session
        let descriptor = Darwin.open(documentURL.path, O_WRONLY | O_TRUNC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        if descriptor >= 0 {
            let replacement = Data("same inode replacement".utf8)
            _ = replacement.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress, bytes.count)
            }
            Darwin.close(descriptor)
        }

        XCTAssertThrowsError(try appState.saveCurrentDocument())
        XCTAssertEqual(
            try String(contentsOf: documentURL, encoding: .utf8),
            "same inode replacement"
        )
        XCTAssertTrue(session.isDirty)
    }

    func testUnanchoredOrdinarySaveFailsClosedForDeletedOrUnavailableProof() throws {
        for startsExisting in [true, false] {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let documentURL = root.appendingPathComponent("post.md").standardizedFileURL
            if startsExisting {
                try writeText("loaded A", to: documentURL)
            }
            let session = DocumentSession(
                text: "edited A",
                url: documentURL,
                fileKind: .markdown,
                isDirty: true
            )
            let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
            appState.sessionCache[documentURL] = session
            if startsExisting {
                try FileManager.default.removeItem(at: documentURL)
            }

            XCTAssertThrowsError(
                try appState.saveCurrentDocument(),
                "startsExisting: \(startsExisting)"
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: documentURL.path))
            XCTAssertTrue(session.isDirty)
        }
    }

    func testUnanchoredSessionStateURLKeepsRetainedRawSpellingWhenLeafBecomesDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let documentURL = root.appendingPathComponent("post.md").standardizedFileURL
        try writeText("loaded", to: documentURL)
        let session = DocumentSession(
            text: "loaded",
            url: documentURL,
            fileKind: .markdown,
            isDirty: false
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        let retainedURL = try XCTUnwrap(appState.sessionStateURL(for: session))

        try FileManager.default.removeItem(at: documentURL)
        try FileManager.default.createDirectory(at: documentURL, withIntermediateDirectories: false)

        XCTAssertEqual(
            appState.sessionStateURL(for: session)?.absoluteString,
            retainedURL.absoluteString
        )
        XCTAssertFalse(try XCTUnwrap(appState.sessionStateURL(for: session)).absoluteString.hasSuffix("/"))
    }

    func testAnchoredAndQuarantinedSessionStateURLUsesRetainedSessionIdentity() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let anchoredLocation = try authority.location(relativePath: "anchored.md")
        let quarantineLocation = try authority.location(relativePath: "quarantined.md")
        let mutableDisplayURL = root.appendingPathComponent("mutable-display.md")
        try writeText("anchored", to: anchoredLocation.fileURL)
        let read = try MarkdownFileStore().loadResult(at: anchoredLocation)
        let session = DocumentSession(
            text: read.file.text,
            url: anchoredLocation.fileURL,
            fileKind: .markdown,
            isDirty: false
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        let sessionIdentity = ObjectIdentifier(session)
        appState.anchoredSessionFileBindings[sessionIdentity] = AnchoredWorkspaceSessionFileBinding(
            location: anchoredLocation,
            identity: read.metadata.identity,
            sha256Digest: read.sha256Digest
        )

        session.reset(
            text: session.text,
            url: mutableDisplayURL,
            fileKind: session.fileKind,
            isDirty: false
        )

        XCTAssertEqual(appState.sessionStateURL(for: session), anchoredLocation.fileURL)
        XCTAssertEqual(
            appState.anchoredSessionFileBinding(for: session)?.location,
            anchoredLocation
        )

        appState.indeterminateSessionWrites[sessionIdentity] = WorkspaceIndeterminateFileWrite(
            reason: .durabilityFailed,
            preparedMetadata: nil,
            recoveryArtifact: .none
        )
        appState.indeterminateSessionWriteContexts[sessionIdentity] = IndeterminateSessionWriteContext(
            location: quarantineLocation,
            preparedSHA256Digest: WorkspaceSearchContentFingerprint(text: session.text).sha256Digest
        )

        XCTAssertEqual(appState.sessionStateURL(for: session), quarantineLocation.fileURL)
    }

    func testSaveCopyDoesNotExemptSourceAcrossAtoBAtSameVisibleSpelling() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let selectedRoot = parent.appendingPathComponent("workspace", isDirectory: true)
        let movedA = parent.appendingPathComponent("workspace-a", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
        let originalURL = selectedRoot.appendingPathComponent("post.md").standardizedFileURL
        try writeText("disk A", to: originalURL)
        let session = DocumentSession(
            text: "unsaved A",
            url: originalURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.sessionCache[originalURL] = session

        try FileManager.default.moveItem(at: selectedRoot, to: movedA)
        try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
        let authorityB = try WorkspaceFileSystemRootAuthority(rootURL: selectedRoot)
        appState.workspaceRootURL = selectedRoot
        appState.workspaceSearchRootAuthority = authorityB
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.markSessionDetachedFromMissingFile(session, url: originalURL)

        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: originalURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertTrue(session.isDirty)
    }

    func testQuarantinedSaveCopyRetryRequiresLiteralNFCNFDSpellingBytes() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let nfcLocation = try authority.location(relativePath: "caf\u{00E9}.md")
        let nfdLocation = try authority.location(relativePath: "cafe\u{0301}.md")
        let session = DocumentSession(
            text: "unsaved",
            url: nfdLocation.fileURL,
            fileKind: .markdown,
            isDirty: false
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        let sessionIdentity = ObjectIdentifier(session)
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.sessionCache[nfdLocation.fileURL] = session
        let result = WorkspaceIndeterminateFileWrite(
            reason: .durabilityFailed,
            preparedMetadata: nil,
            recoveryArtifact: .none
        )
        appState.indeterminateSessionWrites[sessionIdentity] = result
        appState.indeterminateSessionWriteContexts[sessionIdentity] = IndeterminateSessionWriteContext(
            location: nfdLocation,
            preparedSHA256Digest: WorkspaceSearchContentFingerprint(text: session.text).sha256Digest
        )
        appState.detachedSessionURLs.insert(nfdLocation.fileURL)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: nfdLocation.fileURL)
        var didAttemptWrite = false
        appState.anchoredFileSaveOverride = { _, _, _ in
            didAttemptWrite = true
            throw WorkspaceAnchoredFileSystemError.namespaceChanged
        }

        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: nfcLocation.fileURL))
        XCTAssertFalse(didAttemptWrite)
        XCTAssertEqual(appState.indeterminateSessionWriteContexts[sessionIdentity]?.location, nfdLocation)
    }

    // swiftlint:disable:next function_body_length
    func testSaveCopyRejectsSameVisiblePathAcrossCachedRetiredEditorAndQuarantineAuthorities() throws {
        enum Placement: CaseIterable {
            case cached
            case retired
            case editorBound
            case quarantined
        }

        for placement in Placement.allCases {
            let parent = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: parent) }
            let selectedRoot = parent.appendingPathComponent("workspace", isDirectory: true)
            let movedA = parent.appendingPathComponent("workspace-a", isDirectory: true)
            try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
            let ownedURL = selectedRoot.appendingPathComponent("owned.md").standardizedFileURL
            try writeText("owned A", to: ownedURL)
            let authorityA = try WorkspaceFileSystemRootAuthority(rootURL: selectedRoot)
            let ownedLocationA = try authorityA.location(relativePath: "owned.md")
            let ownedReadA = try MarkdownFileStore().loadResult(at: ownedLocationA)

            try FileManager.default.moveItem(at: selectedRoot, to: movedA)
            try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
            let sourceURL = selectedRoot.appendingPathComponent("source.md").standardizedFileURL
            try writeText("source B", to: sourceURL)
            let authorityB = try WorkspaceFileSystemRootAuthority(rootURL: selectedRoot)
            let sourceLocationB = try authorityB.location(relativePath: "source.md")
            let sourceReadB = try MarkdownFileStore().loadResult(at: sourceLocationB)
            let sourceSession = DocumentSession(
                text: "unsaved source",
                url: sourceURL,
                fileKind: .markdown,
                isDirty: true
            )
            let ownedSession = DocumentSession(
                text: "owned A",
                url: ownedURL,
                fileKind: .markdown,
                isDirty: false
            )
            let appState = AppState(
                currentDocument: sourceSession,
                shouldRestoreLastOpenedFile: false
            )
            appState.workspaceRootURL = selectedRoot
            appState.workspaceSearchRootAuthority = authorityB
            appState.workspaceGeneration = 1
            appState.workspaceInstalledCaptureGeneration = 1
            appState.sessionCache[sourceURL] = sourceSession
            appState.anchoredSessionFileBindings[ObjectIdentifier(sourceSession)] =
                AnchoredWorkspaceSessionFileBinding(
                    location: sourceLocationB,
                    identity: sourceReadB.metadata.identity,
                    sha256Digest: sourceReadB.sha256Digest
                )
            try FileManager.default.removeItem(at: sourceURL)
            appState.markSessionDetachedFromMissingFile(sourceSession, url: sourceURL)

            let ownedIdentity = ObjectIdentifier(ownedSession)
            let ownedBinding = AnchoredWorkspaceSessionFileBinding(
                location: ownedLocationA,
                identity: ownedReadA.metadata.identity,
                sha256Digest: ownedReadA.sha256Digest
            )
            switch placement {
            case .cached:
                appState.sessionCache[ownedURL] = ownedSession
                appState.anchoredSessionFileBindings[ownedIdentity] = ownedBinding
            case .retired:
                appState.retiredEditorDocumentSessions[ownedURL] = RetiredEditorDocumentSession(
                    canonicalURL: ownedURL,
                    session: ownedSession,
                    bindingIDs: [],
                    awaitingInstallations: [],
                    securityScopedAuthorityOwners: []
                )
                appState.anchoredSessionFileBindings[ownedIdentity] = ownedBinding
            case .editorBound:
                let bindingID = EditorDocumentBindingID()
                appState.editorDocumentBindingIDs[ownedIdentity] = bindingID
                appState.editorDocumentBindingSessions[bindingID] = ownedSession
                appState.anchoredSessionFileBindings[ownedIdentity] = ownedBinding
            case .quarantined:
                appState.sessionCache[ownedURL] = ownedSession
                appState.indeterminateSessionWrites[ownedIdentity] = WorkspaceIndeterminateFileWrite(
                    reason: .durabilityFailed,
                    preparedMetadata: nil,
                    recoveryArtifact: .none
                )
                appState.indeterminateSessionWriteContexts[ownedIdentity] =
                    IndeterminateSessionWriteContext(
                        location: ownedLocationA,
                        preparedSHA256Digest: WorkspaceSearchContentFingerprint(
                            text: ownedSession.text
                        ).sha256Digest
                    )
            }

            XCTAssertThrowsError(
                try appState.saveDetachedCurrentDocument(to: ownedURL),
                "placement: \(placement)"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: ownedURL.path),
                "placement: \(placement)"
            )
        }
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
            isDirty: false
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
        appState.lastKnownDiskHashes[otherURL] = "known B"
        appState.detachedSessionURLs.insert(otherURL)
        try FileManager.default.createSymbolicLink(at: missingURL, withDestinationURL: otherURL)

        appState.closeMissingFile()

        XCTAssertTrue(appState.sessionCache[missingURL] === missingSession)
        XCTAssertTrue(appState.currentDocument === missingSession)
        XCTAssertNotNil(appState.indeterminateSessionWrites[ObjectIdentifier(missingSession)])
        XCTAssertEqual(
            appState.indeterminateSessionWriteContexts[ObjectIdentifier(missingSession)]?.location,
            missingLocation
        )
        XCTAssertTrue(appState.sessionCache[otherURL] === otherSession)
        XCTAssertEqual(appState.pendingExternalTexts[otherURL], "pending B")
        XCTAssertEqual(appState.lastKnownDiskHashes[otherURL], "known B")
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
        fixture.appState.retiredEditorDocumentSessions[fixture.ownedURL] =
            RetiredEditorDocumentSession(
                canonicalURL: fixture.ownedURL,
                session: fixture.ownedSession,
                bindingIDs: [retiredBindingID],
                awaitingInstallations: [],
                securityScopedAuthorityOwners: []
            )

        XCTAssertThrowsError(
            try fixture.appState.saveDetachedCurrentDocument(to: fixture.ownedURL)
        )

        XCTAssertEqual(try String(contentsOf: fixture.ownedURL, encoding: .utf8), "owned disk")
        XCTAssertTrue(
            fixture.appState.retiredEditorDocumentSessions[fixture.ownedURL]?.session
                === fixture.ownedSession
        )
        XCTAssertTrue(fixture.appState.currentDocument === fixture.missingSession)
    }

    func testOutsideSaveCopySymlinkCannotReachHardlinkOwnedByCachedSession() throws {
        let fixture = try makeSaveCopyOwnershipFixture()
        let outsideRoot = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: outsideRoot)
        }
        let ownedURL = fixture.root.appendingPathComponent("owned.md").standardizedFileURL
        let hardlinkURL = fixture.root.appendingPathComponent("owned-hardlink.md").standardizedFileURL
        let outsideAlias = outsideRoot.appendingPathComponent("copy.md").standardizedFileURL
        try writeText("cached sentinel", to: ownedURL)
        try FileManager.default.linkItem(at: ownedURL, to: hardlinkURL)
        try FileManager.default.createSymbolicLink(at: outsideAlias, withDestinationURL: hardlinkURL)
        let ownedLocation = try fixture.authority.location(relativePath: "owned.md")
        let ownedRead = try MarkdownFileStore().loadResult(at: ownedLocation)
        let ownedSession = DocumentSession(
            text: "cached dirty text",
            url: ownedURL,
            fileKind: .markdown,
            isDirty: true
        )
        fixture.appState.sessionCache[ownedURL] = ownedSession
        fixture.appState.anchoredSessionFileBindings[ObjectIdentifier(ownedSession)] =
            AnchoredWorkspaceSessionFileBinding(
                location: ownedLocation,
                identity: ownedRead.metadata.identity,
                sha256Digest: ownedRead.sha256Digest
            )

        XCTAssertThrowsError(try fixture.appState.saveDetachedCurrentDocument(to: outsideAlias))

        XCTAssertEqual(try String(contentsOf: ownedURL, encoding: .utf8), "cached sentinel")
        XCTAssertEqual(try String(contentsOf: hardlinkURL, encoding: .utf8), "cached sentinel")
        XCTAssertTrue(fixture.appState.currentDocument === fixture.missingSession)
    }

    func testOutsideSaveCopySymlinkCannotReachTargetOwnedByRetiredSession() throws {
        let fixture = try makeSaveCopyOwnershipFixture()
        let outsideRoot = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: outsideRoot)
        }
        let ownedURL = fixture.root.appendingPathComponent("retired.md").standardizedFileURL
        let outsideAlias = outsideRoot.appendingPathComponent("copy.md").standardizedFileURL
        try writeText("retired sentinel", to: ownedURL)
        try FileManager.default.createSymbolicLink(at: outsideAlias, withDestinationURL: ownedURL)
        let ownedSession = DocumentSession(
            text: "retired dirty text",
            url: ownedURL,
            fileKind: .markdown,
            isDirty: true
        )
        let bindingID = EditorDocumentBindingID()
        fixture.appState.retiredEditorDocumentSessions[ownedURL] = RetiredEditorDocumentSession(
            canonicalURL: ownedURL,
            session: ownedSession,
            bindingIDs: [bindingID],
            awaitingInstallations: [],
            securityScopedAuthorityOwners: []
        )

        XCTAssertThrowsError(try fixture.appState.saveDetachedCurrentDocument(to: outsideAlias))

        XCTAssertEqual(try String(contentsOf: ownedURL, encoding: .utf8), "retired sentinel")
        XCTAssertTrue(
            fixture.appState.retiredEditorDocumentSessions[ownedURL]?.session === ownedSession
        )
    }

    func testOutsideSaveCopySymlinkCannotReachTargetOwnedByEditorBoundSession() throws {
        let fixture = try makeSaveCopyOwnershipFixture()
        let outsideRoot = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: outsideRoot)
        }
        let ownedURL = fixture.root.appendingPathComponent("editor-bound.md").standardizedFileURL
        let outsideAlias = outsideRoot.appendingPathComponent("copy.md").standardizedFileURL
        try writeText("editor sentinel", to: ownedURL)
        try FileManager.default.createSymbolicLink(at: outsideAlias, withDestinationURL: ownedURL)
        let ownedSession = DocumentSession(
            text: "editor dirty text",
            url: ownedURL,
            fileKind: .markdown,
            isDirty: true
        )
        let bindingID = EditorDocumentBindingID()
        fixture.appState.editorDocumentBindingIDs[ObjectIdentifier(ownedSession)] = bindingID
        fixture.appState.editorDocumentBindingSessions[bindingID] = ownedSession

        XCTAssertThrowsError(try fixture.appState.saveDetachedCurrentDocument(to: outsideAlias))

        XCTAssertEqual(try String(contentsOf: ownedURL, encoding: .utf8), "editor sentinel")
        XCTAssertTrue(fixture.appState.editorDocumentBindingSessions[bindingID] === ownedSession)
    }

    func testWorkspaceSaveCopyHardlinkToUnanchoredCurrentSessionIsRejected() throws {
        let root = try makeTemporaryDirectory()
        let standaloneRoot = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: standaloneRoot)
        }
        let standaloneURL = standaloneRoot.appendingPathComponent("standalone.md").standardizedFileURL
        let destinationURL = root.appendingPathComponent("workspace-hardlink.md").standardizedFileURL
        try writeText("standalone sentinel", to: standaloneURL)
        try FileManager.default.linkItem(at: standaloneURL, to: destinationURL)
        let session = DocumentSession(
            text: "unsaved standalone text",
            url: standaloneURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.sessionCache[standaloneURL] = session
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: standaloneURL)

        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: destinationURL))

        XCTAssertEqual(
            try String(contentsOf: standaloneURL, encoding: .utf8),
            "standalone sentinel"
        )
        XCTAssertEqual(
            try String(contentsOf: destinationURL, encoding: .utf8),
            "standalone sentinel"
        )
        XCTAssertTrue(session.isDirty)
    }

    func testWorkspaceSaveCopyHardlinkToEveryUnanchoredManagedSessionIsRejected() throws {
        for ownership in ["cached", "retired", "editor-bound"] {
            let fixture = try makeSaveCopyOwnershipFixture()
            let standaloneRoot = try makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: fixture.root)
                try? FileManager.default.removeItem(at: standaloneRoot)
            }
            let standaloneURL = standaloneRoot
                .appendingPathComponent("\(ownership).md")
                .standardizedFileURL
            let destinationURL = fixture.root
                .appendingPathComponent("\(ownership)-hardlink.md")
                .standardizedFileURL
            try writeText("\(ownership) sentinel", to: standaloneURL)
            try FileManager.default.linkItem(at: standaloneURL, to: destinationURL)
            let ownedSession = DocumentSession(
                text: "\(ownership) dirty text",
                url: standaloneURL,
                fileKind: .markdown,
                isDirty: true
            )
            switch ownership {
            case "cached":
                fixture.appState.sessionCache[standaloneURL] = ownedSession
            case "retired":
                let bindingID = EditorDocumentBindingID()
                fixture.appState.retiredEditorDocumentSessions[standaloneURL] =
                    RetiredEditorDocumentSession(
                        canonicalURL: standaloneURL,
                        session: ownedSession,
                        bindingIDs: [bindingID],
                        awaitingInstallations: [],
                        securityScopedAuthorityOwners: []
                    )
            default:
                let bindingID = EditorDocumentBindingID()
                fixture.appState.editorDocumentBindingIDs[ObjectIdentifier(ownedSession)] = bindingID
                fixture.appState.editorDocumentBindingSessions[bindingID] = ownedSession
            }

            XCTAssertThrowsError(
                try fixture.appState.saveDetachedCurrentDocument(to: destinationURL),
                ownership
            )

            XCTAssertEqual(
                try String(contentsOf: standaloneURL, encoding: .utf8),
                "\(ownership) sentinel"
            )
            XCTAssertEqual(
                try String(contentsOf: destinationURL, encoding: .utf8),
                "\(ownership) sentinel"
            )
        }
    }

    func testWorkspaceSaveCopyRejectsHardlinkOwnedByUnlinkedUnanchoredManagedSession() throws {
        let fixture = try makeSaveCopyOwnershipFixture()
        let standaloneRoot = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: standaloneRoot)
        }
        let ownedURL = standaloneRoot.appendingPathComponent("owned.md").standardizedFileURL
        let destinationURL = fixture.root.appendingPathComponent("owned-hardlink.md").standardizedFileURL
        try writeText("owned sentinel", to: ownedURL)
        let ownedSession = DocumentSession(
            text: "owned dirty text",
            url: ownedURL,
            fileKind: .markdown,
            isDirty: true
        )
        fixture.appState.sessionCache[ownedURL] = ownedSession
        fixture.appState.retainUnanchoredManagedSessionOwnership(for: ownedSession)
        try FileManager.default.linkItem(at: ownedURL, to: destinationURL)
        try FileManager.default.removeItem(at: ownedURL)

        XCTAssertThrowsError(try fixture.appState.saveDetachedCurrentDocument(to: destinationURL))

        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "owned sentinel")
        XCTAssertTrue(ownedSession.isDirty)
    }

    func testWorkspaceSaveCopyRejectsHardlinkOwnedBeforeUnanchoredSessionPathWasReplaced() throws {
        let fixture = try makeSaveCopyOwnershipFixture()
        let standaloneRoot = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: standaloneRoot)
        }
        let ownedURL = standaloneRoot.appendingPathComponent("owned.md").standardizedFileURL
        let destinationURL = fixture.root.appendingPathComponent("owned-hardlink.md").standardizedFileURL
        try writeText("owned sentinel", to: ownedURL)
        let ownedSession = DocumentSession(
            text: "owned dirty text",
            url: ownedURL,
            fileKind: .markdown,
            isDirty: true
        )
        fixture.appState.sessionCache[ownedURL] = ownedSession
        fixture.appState.retainUnanchoredManagedSessionOwnership(for: ownedSession)
        try FileManager.default.linkItem(at: ownedURL, to: destinationURL)
        try FileManager.default.removeItem(at: ownedURL)
        try writeText("replacement inode", to: ownedURL)

        XCTAssertThrowsError(try fixture.appState.saveDetachedCurrentDocument(to: destinationURL))

        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "owned sentinel")
        XCTAssertEqual(try String(contentsOf: ownedURL, encoding: .utf8), "replacement inode")
        XCTAssertTrue(ownedSession.isDirty)
    }

    func testWorkspaceSaveCopyFailsClosedForUnanchoredManagedSessionWithoutOwnershipProof() throws {
        let fixture = try makeSaveCopyOwnershipFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unprovableURL = fixture.root.appendingPathComponent("unprovable.md").standardizedFileURL
        let destinationURL = fixture.root.appendingPathComponent("destination.md").standardizedFileURL
        let unprovableSession = DocumentSession(
            text: "unprovable dirty text",
            url: unprovableURL,
            fileKind: .markdown,
            isDirty: true
        )
        fixture.appState.sessionCache[unprovableURL] = unprovableSession
        fixture.appState.retainUnanchoredManagedSessionOwnership(for: unprovableSession)

        XCTAssertThrowsError(try fixture.appState.saveDetachedCurrentDocument(to: destinationURL))

        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertTrue(unprovableSession.isDirty)
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

    private struct SaveCopyOwnershipFixture {
        let root: URL
        let authority: WorkspaceFileSystemRootAuthority
        let appState: AppState
        let missingSession: DocumentSession
    }

    private func makeSaveCopyOwnershipFixture() throws -> SaveCopyOwnershipFixture {
        let root = try makeTemporaryDirectory()
        let missingURL = root.appendingPathComponent("missing.md").standardizedFileURL
        try writeText("missing disk", to: missingURL)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let missingLocation = try authority.location(relativePath: "missing.md")
        let missingRead = try MarkdownFileStore().loadResult(at: missingLocation)
        let missingSession = DocumentSession(
            text: "unsaved missing text",
            url: missingURL,
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
        appState.anchoredSessionFileBindings[ObjectIdentifier(missingSession)] =
            AnchoredWorkspaceSessionFileBinding(
                location: missingLocation,
                identity: missingRead.metadata.identity,
                sha256Digest: missingRead.sha256Digest
            )
        appState.detachedSessionURLs.insert(missingURL)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: missingURL)
        return SaveCopyOwnershipFixture(
            root: root,
            authority: authority,
            appState: appState,
            missingSession: missingSession
        )
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

    func testInitialSaveCopyMissingInspectionRejectsCreateRacerWithoutTouchingIt() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingURL = root.appendingPathComponent("missing.md").standardizedFileURL
        let destinationURL = root.appendingPathComponent("recovered.md").standardizedFileURL
        try writeText("disk A", to: missingURL)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let missingLocation = try authority.location(relativePath: "missing.md")
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

        var writerEntries = 0
        appState.anchoredFileSaveOverride = { text, location, expectation in
            writerEntries += 1
            XCTAssertEqual(expectation, .missing)
            try self.writeText("create racer", to: destinationURL)
            return try MarkdownFileStore().save(
                text: text,
                at: location,
                expecting: expectation
            )
        }

        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: destinationURL))

        XCTAssertEqual(writerEntries, 1)
        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "create racer")
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.fileURL?.standardizedFileURL, missingURL)
    }

    func testInitialSaveCopyExistingInspectionRejectsReplacementRacerWithoutTouchingIt() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingURL = root.appendingPathComponent("missing.md").standardizedFileURL
        let destinationURL = root.appendingPathComponent("recovered.md").standardizedFileURL
        let racerURL = root.appendingPathComponent("racer.md").standardizedFileURL
        try writeText("disk A", to: missingURL)
        try writeText("original destination", to: destinationURL)
        try writeText("replacement racer", to: racerURL)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let missingLocation = try authority.location(relativePath: "missing.md")
        let destinationLocation = try authority.location(relativePath: "recovered.md")
        let loaded = try MarkdownFileStore().loadResult(at: missingLocation)
        let originalDestination = try MarkdownFileStore().loadResult(at: destinationLocation)
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

        var writerEntries = 0
        appState.anchoredFileSaveOverride = { text, location, expectation in
            writerEntries += 1
            XCTAssertEqual(expectation, .existing(originalDestination.metadata.identity))
            try FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: racerURL, to: destinationURL)
            return try MarkdownFileStore().save(
                text: text,
                at: location,
                expecting: expectation
            )
        }

        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: destinationURL))

        XCTAssertEqual(writerEntries, 1)
        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "replacement racer")
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.fileURL?.standardizedFileURL, missingURL)
    }

    // swiftlint:disable:next function_body_length
    func testIndeterminateSaveCopyRehomesReadableDestinationAndBlocksBlindRetry() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("missing.md").standardizedFileURL
        try writeText("missing A", to: sourceURL)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let missingLocation = try authority.location(relativePath: "missing.md")
        // App session maps retain the descriptor-canonical location spelling, not the
        // caller's `/var` alias for the selected root.
        let missingURL = missingLocation.fileURL
        let destinationURL = try authority.location(relativePath: "recovered.md").fileURL
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
        try await waitUntil("Keep Mine clears the readable Save Copy quarantine") {
            appState.indeterminateSessionWrites[ObjectIdentifier(session)] == nil &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }
        appState.autosaveTask?.cancel()
        XCTAssertNil(appState.indeterminateSessionWrites[ObjectIdentifier(session)])
        XCTAssertTrue(appState.canSave)
    }

    // swiftlint:disable:next function_body_length
    func testIndeterminateSaveCopyWithProvenMissingDestinationRetriesOnlyAtExactLocation() throws {
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

        let differentDestination = root.appendingPathComponent("recovered-copy.md").standardizedFileURL
        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: differentDestination))
        XCTAssertEqual(expectations, [.missing])

        try appState.saveDetachedCurrentDocument(to: destinationURL)

        XCTAssertEqual(expectations, [.missing, .missing])
        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "unsaved A")
        XCTAssertNil(appState.indeterminateSessionWrites[ObjectIdentifier(session)])
        XCTAssertNil(appState.indeterminateSessionWriteContexts[ObjectIdentifier(session)])
        XCTAssertNil(appState.missingFilePrompt)
        XCTAssertFalse(appState.currentDocument.isDirty)
    }

    func testIndeterminateSaveCopyExposesSymlinkReconciliationUntilExactLocationIsReadable() async throws {
        try await assertUnavailableIndeterminateSaveCopyReconciliation(state: .symbolicLink) { destination in
            let target = destination.deletingLastPathComponent().appendingPathComponent("target.md")
            try self.writeText("symlink target", to: target)
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        } repair: { destination in
            try FileManager.default.removeItem(at: destination)
            try self.writeText("disk after repair", to: destination)
        }
    }

    func testIndeterminateSaveCopyExposesNonRegularReconciliationUntilExactLocationIsReadable() async throws {
        try await assertUnavailableIndeterminateSaveCopyReconciliation(state: .notRegularFile) { destination in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        } repair: { destination in
            try FileManager.default.removeItem(at: destination)
            try self.writeText("disk after repair", to: destination)
        }
    }

    func testIndeterminateSaveCopyExposesUnreadableReconciliationUntilExactLocationIsReadable() async throws {
        try await assertUnavailableIndeterminateSaveCopyReconciliation(state: .unreadable) { destination in
            try self.writeText("unreadable disk", to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0],
                ofItemAtPath: destination.path
            )
        } repair: { destination in
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
            try self.writeText("disk after repair", to: destination)
        }
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

    func testArtifactNoticeSurvivesWorkspaceCloseAndAcknowledgementKeepsArtifact() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let post = root.appendingPathComponent("post.md").standardizedFileURL
        let recovery = root.appendingPathComponent(".post.recovery").standardizedFileURL
        try writeText("disk A", to: post)
        try writeText("retained artifact", to: recovery)
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
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.workspaceAccess = SecurityScopedAccess.startAccessing(root)
        appState.sessionCache[post] = session
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] =
            AnchoredWorkspaceSessionFileBinding(
                location: location,
                identity: loaded.metadata.identity,
                sha256Digest: loaded.sha256Digest
            )
        appState.anchoredFileSaveOverride = { text, destination, expectation in
            let outcome = try MarkdownFileStore().save(
                text: text,
                at: destination,
                expecting: expectation
            )
            guard case let .committedAndDurable(actual) = outcome else {
                XCTFail("Expected durable save")
                return outcome
            }
            return .committedAndDurable(
                WorkspaceDurableFileWrite(
                    metadata: actual.metadata,
                    cleanupState: .retained(recoveryLocation)
                )
            )
        }

        try appState.save(session: session)
        let noticeID = try XCTUnwrap(appState.fileWriteArtifactNotices.first?.id)
        try appState.closeWorkspaceForReplacement()

        XCTAssertEqual(appState.fileWriteArtifactNotices.map(\.id), [noticeID])
        XCTAssertEqual(try String(contentsOf: recovery, encoding: .utf8), "retained artifact")
        appState.acknowledgeFileWriteArtifactNotice(id: noticeID)
        XCTAssertTrue(appState.fileWriteArtifactNotices.isEmpty)
        XCTAssertEqual(try String(contentsOf: recovery, encoding: .utf8), "retained artifact")
    }

    func testPresentedReconciliationErrorIncludesEveryRecoveryArtifactPath() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let retained = try authority.location(relativePath: ".retained-recovery")
        let indeterminate = try authority.location(relativePath: ".indeterminate-recovery")
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        let destination = root.appendingPathComponent("post.md")

        let expectations: [(WorkspaceFileWriteArtifactState, WorkspaceFileSystemLocation, String)] = [
            (.retained(retained), retained, "was retained at"),
            (.removalIndeterminate(indeterminate), indeterminate, "could not be confirmed"),
        ]
        for (artifact, location, wording) in expectations {
            appState.present(
                MarkdownFileStoreError.writeRequiresReconciliation(
                    destination,
                    WorkspaceIndeterminateFileWrite(
                        reason: .namespaceChanged,
                        preparedMetadata: nil,
                        recoveryArtifact: artifact
                    )
                ),
                title: "Could Not Save Copy"
            )

            XCTAssertEqual(appState.presentedError?.title, "Could Not Save Copy")
            XCTAssertTrue(appState.presentedError?.message.contains(wording) == true)
            XCTAssertTrue(appState.presentedError?.message.contains(location.fileURL.path) == true)
        }
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

    // swiftlint:disable:next function_body_length
    func testDurableSaveCopyBindFailureQuarantinesAndRetainsCleanupNotice() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingURL = root.appendingPathComponent("missing.md").standardizedFileURL
        let destinationURL = root.appendingPathComponent("recovered.md").standardizedFileURL
        let committedURL = root.appendingPathComponent("committed-recovered.md").standardizedFileURL
        let cleanupURL = root.appendingPathComponent(".recovered.cleanup").standardizedFileURL
        try writeText("disk A", to: missingURL)
        try writeText("retained cleanup", to: cleanupURL)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let missingLocation = try authority.location(relativePath: "missing.md")
        let cleanupLocation = try authority.location(relativePath: ".recovered.cleanup")
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
        var writerEntries = 0
        var durableResult: WorkspaceDurableFileWrite?
        appState.anchoredFileSaveOverride = { text, location, expectation in
            writerEntries += 1
            let outcome = try MarkdownFileStore().save(
                text: text,
                at: location,
                expecting: expectation
            )
            guard case let .committedAndDurable(actual) = outcome else {
                XCTFail("Expected a durable Save Copy")
                return outcome
            }
            try FileManager.default.moveItem(at: destinationURL, to: committedURL)
            try self.writeText("replacement B", to: destinationURL)
            let exposed = WorkspaceDurableFileWrite(
                metadata: actual.metadata,
                cleanupState: .retained(cleanupLocation)
            )
            durableResult = exposed
            return .committedAndDurable(exposed)
        }

        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: destinationURL)) { error in
            guard case let MarkdownFileStoreError.writeRequiresReconciliation(url, result) = error
            else {
                return XCTFail("Expected postcommit reconciliation, got \(error)")
            }
            XCTAssertEqual(url.standardizedFileURL, destinationURL)
            XCTAssertEqual(result.reason, .namespaceChanged)
            XCTAssertEqual(result.preparedMetadata, durableResult?.metadata)
            XCTAssertEqual(result.recoveryArtifact, .retained(cleanupLocation))
        }

        let sessionIdentity = ObjectIdentifier(session)
        XCTAssertEqual(writerEntries, 1)
        XCTAssertEqual(try String(contentsOf: committedURL, encoding: .utf8), "unsaved A")
        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "replacement B")
        XCTAssertEqual(session.fileURL?.standardizedFileURL, destinationURL)
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(appState.sessionCache[destinationURL] === session)
        XCTAssertNil(appState.sessionCache[missingURL])
        XCTAssertEqual(
            appState.indeterminateSessionWrites[sessionIdentity]?.recoveryArtifact,
            .retained(cleanupLocation)
        )
        XCTAssertEqual(appState.pendingExternalTexts[destinationURL], "replacement B")
        XCTAssertFalse(appState.canSave)
        XCTAssertEqual(
            appState.fileWriteArtifactNotices,
            [
                FileWriteArtifactNotice(
                    destinationURL: destinationURL,
                    destinationWasCommitted: true,
                    artifactState: .retained(cleanupLocation)
                ),
            ]
        )

        XCTAssertThrowsError(try appState.saveCurrentDocument())
        XCTAssertEqual(writerEntries, 1)
        appState.reloadExternallyChangedFile()
        try await waitUntil("Reload clears postcommit Save Copy quarantine") {
            appState.indeterminateSessionWrites[sessionIdentity] == nil &&
                appState.externalReloadTasks[sessionIdentity] == nil
        }
        XCTAssertEqual(
            appState.fileWriteArtifactNotices.first?.artifactState,
            .retained(cleanupLocation)
        )
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

    func testStandaloneSaveTreatsCommittedCleanupOutcomeAsSuccessWithNotice() throws {
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
        appState.anchoredFileSaveOverride = { text, location, expectation in
            let outcome = try MarkdownFileStore().save(
                text: text,
                at: location,
                expecting: expectation
            )
            guard case let .committedAndDurable(actual) = outcome else {
                XCTFail("Expected deterministic standalone save")
                return outcome
            }
            return .committedAndDurable(
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

    func testStandaloneSaveCopyTreatsCommittedCleanupOutcomeAsSuccessfulRehome() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingURL = root.appendingPathComponent("missing.md").standardizedFileURL
        let destinationURL = root.appendingPathComponent("recovered.md").standardizedFileURL
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let recoveryLocation = try authority.location(relativePath: ".recovered.cleanup")
        try writeText("disk A", to: missingURL)
        let session = DocumentSession(
            text: "unsaved A",
            url: missingURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        try FileManager.default.removeItem(at: missingURL)
        appState.sessionCache[missingURL] = session
        appState.detachedSessionURLs.insert(missingURL)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: missingURL)
        appState.anchoredFileSaveOverride = { text, location, expectation in
            let outcome = try MarkdownFileStore().save(
                text: text,
                at: location,
                expecting: expectation
            )
            guard case let .committedAndDurable(actual) = outcome else {
                XCTFail("Expected deterministic standalone Save Copy")
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
        XCTAssertNil(appState.indeterminateSessionWrites[ObjectIdentifier(session)])
        XCTAssertEqual(
            appState.fileWriteArtifactNotices.first?.artifactState,
            .removalIndeterminate(recoveryLocation)
        )
        XCTAssertEqual(appState.presentedError?.title, "File Saved; Cleanup Required")
    }

    func testStandaloneOrdinaryIndeterminateSaveQuarantinesExactLocationAndBlocksSecondWriterEntry() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let post = root.appendingPathComponent("post.md").standardizedFileURL
        try writeText("disk A", to: post)
        let location = try WorkspaceFileSystemLocation(fileURL: post)
        let loaded = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(
            text: "edited A",
            url: post,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.sessionCache[post] = session
        let indeterminate = WorkspaceIndeterminateFileWrite(
            reason: .durabilityFailed,
            preparedMetadata: loaded.metadata,
            recoveryArtifact: .retained(location)
        )
        var writerEntries = 0
        appState.anchoredFileSaveOverride = { _, actualLocation, expectation in
            writerEntries += 1
            XCTAssertEqual(actualLocation, location)
            XCTAssertEqual(
                expectation,
                .existingContent(
                    loaded.metadata.identity,
                    sha256Digest: loaded.sha256Digest
                )
            )
            return .committedButIndeterminate(indeterminate)
        }

        XCTAssertThrowsError(try appState.saveCurrentDocument())

        let context = try XCTUnwrap(
            appState.indeterminateSessionWriteContexts[ObjectIdentifier(session)]
        )
        XCTAssertEqual(context.location, location)
        XCTAssertEqual(
            context.preparedSHA256Digest,
            WorkspaceSearchContentFingerprint(text: session.text).sha256Digest
        )
        XCTAssertEqual(appState.indeterminateSessionWrites[ObjectIdentifier(session)], indeterminate)
        XCTAssertEqual(appState.externalChangePrompt?.fileURL.standardizedFileURL, post)
        XCTAssertFalse(appState.canAutosave(session: session))

        XCTAssertThrowsError(try appState.saveCurrentDocument())
        XCTAssertEqual(writerEntries, 1)
        XCTAssertEqual(try String(contentsOf: post, encoding: .utf8), "disk A")
    }

    func testOutsideSaveCopyIndeterminateQuarantineAllowsOnlyExactMissingRetry() throws {
        let sourceRoot = try makeTemporaryDirectory()
        let destinationRoot = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: destinationRoot)
        }
        let missingURL = sourceRoot.appendingPathComponent("missing.md").standardizedFileURL
        let destinationURL = destinationRoot.appendingPathComponent("recovered.md").standardizedFileURL
        try writeText("disk A", to: missingURL)
        let session = DocumentSession(
            text: "unsaved A",
            url: missingURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        try FileManager.default.removeItem(at: missingURL)
        appState.sessionCache[missingURL] = session
        appState.detachedSessionURLs.insert(missingURL)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: missingURL)
        let indeterminate = WorkspaceIndeterminateFileWrite(
            reason: .durabilityFailed,
            preparedMetadata: nil,
            recoveryArtifact: .none
        )
        var writerEntries = 0
        var firstLocation: WorkspaceFileSystemLocation?
        appState.anchoredFileSaveOverride = { _, location, expectation in
            writerEntries += 1
            firstLocation = firstLocation ?? location
            XCTAssertEqual(location, firstLocation)
            XCTAssertEqual(expectation, .missing)
            return .committedButIndeterminate(indeterminate)
        }

        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: destinationURL))

        let context = try XCTUnwrap(
            appState.indeterminateSessionWriteContexts[ObjectIdentifier(session)]
        )
        XCTAssertEqual(context.location, firstLocation)
        XCTAssertEqual(context.location.fileURL, destinationURL)
        XCTAssertEqual(appState.missingFilePrompt?.fileURL.standardizedFileURL, destinationURL)
        XCTAssertFalse(appState.canAutosave(session: session))

        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: destinationURL))
        XCTAssertEqual(writerEntries, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testIndeterminateAnchoredSaveBlocksBlindRetryUntilExplicitReconciliation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let initialPostURL = root.appendingPathComponent("post.md").standardizedFileURL
        try writeText("disk A", to: initialPostURL)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: "post.md")
        let post = location.fileURL
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
        try await waitUntil("Keep Mine clears the indeterminate anchored write") {
            appState.indeterminateSessionWrites[ObjectIdentifier(session)] == nil &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }
        appState.autosaveTask?.cancel()
        appState.anchoredFileSaveOverride = nil
        XCTAssertNil(appState.indeterminateSessionWrites[ObjectIdentifier(session)])
        XCTAssertTrue(appState.canSave)
    }

    // swiftlint:disable:next function_body_length
    func testKeepMineMarksCleanQuarantineDirtyWhenCanonicalEquivalentDiskBytesDiffer() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let localText = "caf\u{00E9}"
        let diskText = "cafe\u{0301}"
        XCTAssertFalse(ExactSourceText.matches(localText, diskText))

        let initialPostURL = root.appendingPathComponent("post.md").standardizedFileURL
        try writeText(localText, to: initialPostURL)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: "post.md")
        let post = location.fileURL
        let loadedA = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(
            text: localText,
            url: post,
            fileKind: .markdown,
            isDirty: false
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        defer { appState.autosaveTask?.cancel() }
        let sessionIdentity = ObjectIdentifier(session)
        appState.sessionCache[post] = session
        _ = appState.sessionPolicy.access(post, isDirty: false)
        appState.anchoredSessionFileBindings[sessionIdentity] = AnchoredWorkspaceSessionFileBinding(
            location: location,
            identity: loadedA.metadata.identity,
            sha256Digest: loadedA.sha256Digest
        )
        let indeterminate = WorkspaceIndeterminateFileWrite(
            reason: .durabilityFailed,
            preparedMetadata: loadedA.metadata,
            recoveryArtifact: .retained(location)
        )
        appState.indeterminateSessionWrites[sessionIdentity] = indeterminate
        appState.indeterminateSessionWriteContexts[sessionIdentity] = IndeterminateSessionWriteContext(
            location: location,
            preparedSHA256Digest: WorkspaceSearchContentFingerprint(text: localText).sha256Digest
        )

        try writeText(diskText, to: post)
        appState.handleExternalChange(for: session)
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(appState.indeterminateSessionWrites[sessionIdentity], indeterminate)
        let pendingText = try XCTUnwrap(appState.pendingExternalTexts[post])
        XCTAssertTrue(ExactSourceText.matches(pendingText, diskText))

        appState.keepMineForExternallyChangedFile()
        try await waitUntil("Keep Mine resolves the clean quarantine") {
            appState.indeterminateSessionWrites[sessionIdentity] == nil &&
                appState.externalReloadTasks[sessionIdentity] == nil
        }

        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(appState.sessionPolicy.dirtyState(for: post), true)
        XCTAssertNil(appState.indeterminateSessionWrites[sessionIdentity])
        XCTAssertNil(appState.pendingExternalTexts[post])
        XCTAssertTrue(appState.canAutosave(session: session))
        XCTAssertNotNil(appState.autosaveTask)
        XCTAssertEqual(try Data(contentsOf: post), Data(diskText.utf8))

        appState.flushAutosaveIfNeeded()

        XCTAssertEqual(try Data(contentsOf: post), Data(localText.utf8))
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(appState.sessionPolicy.dirtyState(for: post), false)
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

        try await waitUntil("deleted file detaches") {
            appState.missingFilePrompt?.fileURL.standardizedFileURL == post.standardizedFileURL &&
                !appState.canSave
        }
        XCTAssertEqual(appState.missingFilePrompt?.fileURL.standardizedFileURL, post.standardizedFileURL)
        XCTAssertFalse(appState.canSave)

        try await Task.sleep(nanoseconds: 1_250_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: post.path))
    }

    // swiftlint:disable:next function_body_length
    func testAnchoredDeleteSwitchRecreateKeepMineClearsDetachedFenceAndRestoresSaving() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let initialPostURL = root.appendingPathComponent("post.md").standardizedFileURL
        try writeText("disk A", to: initialPostURL)
        let parkedPostURL = root.appendingPathComponent("post-parked.md").standardizedFileURL
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: "post.md")
        let otherLocation = try authority.location(relativePath: "other.md")
        try writeText("other B", to: otherLocation.fileURL)
        let post = location.fileURL
        let loadedA = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(
            text: loadedA.file.text,
            url: post,
            fileKind: .markdown,
            isDirty: false
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        defer { appState.autosaveTask?.cancel() }
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.sessionCache[post] = session
        _ = appState.sessionPolicy.access(post, isDirty: false)
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] =
            AnchoredWorkspaceSessionFileBinding(
                location: location,
                identity: loadedA.metadata.identity,
                sha256Digest: loadedA.sha256Digest
            )
        appState.replaceDocumentText("local edits")
        XCTAssertTrue(session.isDirty)

        try FileManager.default.moveItem(at: post, to: parkedPostURL)
        appState.handleExternalChange(for: session)
        try await waitUntil("anchored missing file detaches") {
            appState.detachedSessionURLs.contains(post)
        }
        XCTAssertTrue(appState.detachedSessionURLs.contains(post))
        XCTAssertEqual(appState.missingFilePrompt?.fileURL, post)

        try appState.activateAnchoredFileSession(at: otherLocation)
        XCTAssertFalse(appState.currentDocument === session)
        XCTAssertEqual(appState.currentDocument.fileURL, otherLocation.fileURL)
        XCTAssertNil(appState.missingFilePrompt)
        XCTAssertTrue(appState.detachedSessionURLs.contains(post))

        try FileManager.default.moveItem(at: parkedPostURL, to: post)
        try appState.activateAnchoredFileSession(at: location)
        try await waitUntil("anchored reactivation publishes the restored disk conflict") {
            appState.pendingExternalTexts[post] == "disk A"
        }

        XCTAssertTrue(appState.currentDocument === session)
        XCTAssertTrue(appState.sessionCache[post] === session)
        XCTAssertEqual(session.text, "local edits")
        XCTAssertEqual(appState.pendingExternalTexts[post], "disk A")
        XCTAssertEqual(
            appState.pendingExternalFileVersions[post]?.identity,
            loadedA.metadata.identity
        )
        XCTAssertEqual(
            appState.pendingExternalFileVersions[post]?.sha256Digest,
            loadedA.sha256Digest
        )
        XCTAssertEqual(appState.externalChangePrompt?.fileURL, post)
        XCTAssertTrue(appState.detachedSessionURLs.contains(post))

        appState.keepMineForExternallyChangedFile()
        try await waitUntil("anchored Keep Mine clears the detached fence") {
            !appState.detachedSessionURLs.contains(post) &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }

        XCTAssertFalse(appState.detachedSessionURLs.contains(post))
        XCTAssertNil(appState.pendingExternalTexts[post])
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertNil(appState.missingFilePrompt)
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(appState.canSave)
        XCTAssertTrue(appState.canAutosave(session: session))
        XCTAssertNotNil(appState.autosaveTask)
        XCTAssertNoThrow(try appState.saveCurrentDocument())
        XCTAssertEqual(try String(contentsOf: post, encoding: .utf8), "local edits")
    }

    // swiftlint:disable:next function_body_length
    func testStandaloneDeleteSwitchRecreateKeepMineClearsDetachedFenceAndRestoresSaving() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let initialPostURL = root.appendingPathComponent("post.md").standardizedFileURL
        try writeText("disk A", to: initialPostURL)
        let parkedPostURL = root.appendingPathComponent("post-parked.md").standardizedFileURL
        let location = try WorkspaceFileSystemLocation(fileURL: initialPostURL)
        let otherURL = root.appendingPathComponent("other.md").standardizedFileURL
        try writeText("other B", to: otherURL)
        let post = location.fileURL
        let loadedA = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(
            text: loadedA.file.text,
            url: post,
            fileKind: .markdown,
            isDirty: false
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        defer { appState.autosaveTask?.cancel() }
        let sessionIdentity = ObjectIdentifier(session)
        appState.sessionCache[post] = session
        _ = appState.sessionPolicy.access(post, isDirty: false)
        appState.unanchoredManagedSessionOwnershipProofs[sessionIdentity] = .proven(
            UnanchoredManagedSessionFileProof(
                location: location,
                identity: loadedA.metadata.identity,
                sha256Digest: loadedA.sha256Digest,
                installedWorkspaceLocation: nil
            )
        )
        appState.replaceDocumentText("standalone local edits")
        XCTAssertTrue(session.isDirty)

        try FileManager.default.moveItem(at: post, to: parkedPostURL)
        appState.handleExternalChange(for: session)
        try await waitUntil("standalone missing file detaches") {
            appState.detachedSessionURLs.contains(post)
        }
        XCTAssertTrue(appState.detachedSessionURLs.contains(post))
        XCTAssertEqual(appState.missingFilePrompt?.fileURL, post)

        try appState.activateFileSession(url: otherURL)
        XCTAssertFalse(appState.currentDocument === session)
        XCTAssertEqual(appState.currentDocument.fileURL, otherURL)
        XCTAssertNil(appState.missingFilePrompt)
        XCTAssertTrue(appState.detachedSessionURLs.contains(post))

        try FileManager.default.moveItem(at: parkedPostURL, to: post)
        try appState.activateFileSession(url: post)
        try await waitUntil("standalone reactivation publishes the restored disk conflict") {
            appState.pendingExternalTexts[post] == "disk A"
        }

        XCTAssertTrue(appState.currentDocument === session)
        XCTAssertTrue(appState.sessionCache[post] === session)
        XCTAssertEqual(session.text, "standalone local edits")
        XCTAssertEqual(appState.pendingExternalTexts[post], "disk A")
        XCTAssertEqual(
            appState.pendingExternalFileVersions[post]?.identity,
            loadedA.metadata.identity
        )
        XCTAssertEqual(
            appState.pendingExternalFileVersions[post]?.sha256Digest,
            loadedA.sha256Digest
        )
        XCTAssertEqual(appState.externalChangePrompt?.fileURL, post)
        XCTAssertTrue(appState.detachedSessionURLs.contains(post))

        appState.keepMineForExternallyChangedFile()
        try await waitUntil("standalone Keep Mine clears the detached fence") {
            !appState.detachedSessionURLs.contains(post) &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }

        XCTAssertFalse(appState.detachedSessionURLs.contains(post))
        XCTAssertNil(appState.pendingExternalTexts[post])
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertNil(appState.missingFilePrompt)
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(appState.canSave)
        XCTAssertTrue(appState.canAutosave(session: session))
        XCTAssertNotNil(appState.autosaveTask)
        XCTAssertNoThrow(try appState.saveCurrentDocument())
        XCTAssertEqual(
            try String(contentsOf: post, encoding: .utf8),
            "standalone local edits"
        )
    }

    func testUnanchoredSameInodeRewriteWithPreservedMtimeEntersConflictAndBlocksOverwrite() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let post = directory.appendingPathComponent("post.md")
        try writeText("Original", to: post)
        let originalStatus = try fileStatus(at: post)
        let appState = AppState(shouldRestoreLastOpenedFile: false)

        appState.openExternalFile(post)
        try await waitUntil("standalone same-inode source opens") {
            appState.currentDocument.fileURL?.standardizedFileURL == post.standardizedFileURL
        }
        let session = appState.currentDocument
        guard case let .proven(originalProof)? =
            appState.unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(session)]
        else {
            return XCTFail("opening a standalone file must retain its original proof")
        }
        appState.replaceDocumentText("Local unsaved edits", in: session)

        // Rewrite B through the same inode, then restore the exact kernel mtime captured for A.
        // The direct handler below must still compare the retained SHA-256, not mtime/FNV.
        let handle = try FileHandle(forWritingTo: post)
        try handle.truncate(atOffset: 0)
        handle.write(Data("Changed on disk, same inode".utf8))
        try handle.close()
        try restoreAccessAndModificationTimes(of: post, from: originalStatus)
        let rewrittenStatus = try fileStatus(at: post)
        XCTAssertEqual(rewrittenStatus.st_ino, originalStatus.st_ino, "test setup must rewrite the same inode")
        assertModificationTime(rewrittenStatus, matches: originalStatus)

        appState.handleExternalChange(for: session)
        try await waitUntil("same-inode rewrite publishes a conflict") {
            appState.externalChangePrompt?.fileURL.standardizedFileURL == post.standardizedFileURL
        }

        let promptURL = try XCTUnwrap(appState.externalChangePrompt?.fileURL)
        XCTAssertEqual(promptURL.standardizedFileURL, post.standardizedFileURL)
        XCTAssertEqual(appState.pendingExternalTexts[promptURL], "Changed on disk, same inode")
        XCTAssertEqual(appState.currentDocument.text, "Local unsaved edits")
        XCTAssertEqual(
            appState.unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(session)],
            .proven(originalProof)
        )
        XCTAssertFalse(appState.canAutosave(session: session))

        appState.flushAutosaveIfNeeded()
        XCTAssertThrowsError(try appState.saveCurrentDocument())

        XCTAssertEqual(
            try String(contentsOf: post, encoding: .utf8),
            "Changed on disk, same inode",
            "autosave/Cmd-S must not overwrite external bytes before Reload or Keep Mine resolves"
        )
    }

    func testUnanchoredReplacementInodeWithPreservedMtimeEntersConflictAndBlocksOverwrite() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let post = directory.appendingPathComponent("post.md")
        try writeText("Original", to: post)
        let originalStatus = try fileStatus(at: post)
        let appState = AppState(shouldRestoreLastOpenedFile: false)

        appState.openExternalFile(post)
        try await waitUntil("standalone replacement source opens") {
            appState.currentDocument.fileURL?.standardizedFileURL == post.standardizedFileURL
        }
        let session = appState.currentDocument
        guard case let .proven(originalProof)? =
            appState.unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(session)]
        else {
            return XCTFail("opening a standalone file must retain its original proof")
        }
        appState.replaceDocumentText("Local unsaved edits", in: session)

        // Atomic replacement B receives A's original mtime after the rename. The changed
        // inode alone must be enough to enter conflict handling before any proof is adopted.
        try "Changed on disk, replaced inode".write(to: post, atomically: true, encoding: .utf8)
        try restoreAccessAndModificationTimes(of: post, from: originalStatus)
        let replacementStatus = try fileStatus(at: post)
        XCTAssertNotEqual(replacementStatus.st_ino, originalStatus.st_ino, "test setup must replace the inode")
        assertModificationTime(replacementStatus, matches: originalStatus)

        appState.handleExternalChange(for: session)
        try await waitUntil("replacement inode publishes a conflict") {
            appState.externalChangePrompt?.fileURL.standardizedFileURL == post.standardizedFileURL
        }

        let promptURL = try XCTUnwrap(appState.externalChangePrompt?.fileURL)
        XCTAssertEqual(promptURL.standardizedFileURL, post.standardizedFileURL)
        XCTAssertEqual(appState.pendingExternalTexts[promptURL], "Changed on disk, replaced inode")
        XCTAssertEqual(appState.currentDocument.text, "Local unsaved edits")
        XCTAssertEqual(
            appState.unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(session)],
            .proven(originalProof)
        )
        XCTAssertFalse(appState.canAutosave(session: session))

        appState.flushAutosaveIfNeeded()
        XCTAssertThrowsError(try appState.saveCurrentDocument())

        XCTAssertEqual(
            try String(contentsOf: post, encoding: .utf8),
            "Changed on disk, replaced inode",
            "autosave/Cmd-S must not overwrite external bytes before Reload or Keep Mine resolves"
        )
    }

    func testCachedStandaloneActivationArbitratesThroughItsRetainedProof() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("post.md")
        try writeText("disk A", to: sourceURL)
        let location = try WorkspaceFileSystemLocation(fileURL: sourceURL)
        let loaded = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(
            text: "local edits",
            url: location.fileURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(
            currentDocument: DocumentSession(),
            shouldRestoreLastOpenedFile: false
        )
        defer {
            appState.autosaveTask?.cancel()
            for task in appState.sessionAutosaveTasks.values {
                task.task.cancel()
            }
        }
        let sessionIdentity = ObjectIdentifier(session)
        let originalProof = UnanchoredManagedSessionFileProof(
            location: location,
            identity: loaded.metadata.identity,
            sha256Digest: loaded.sha256Digest,
            installedWorkspaceLocation: nil
        )
        appState.sessionCache[location.fileURL] = session
        appState.unanchoredManagedSessionOwnershipProofs[sessionIdentity] = .proven(originalProof)
        appState.scheduleAutosave(for: session)
        XCTAssertNotNil(appState.sessionAutosaveTasks[sessionIdentity])

        try writeText("disk B", to: location.fileURL)
        try appState.activateFileSession(url: location.fileURL)
        try await waitUntil("cached standalone activation publishes its conflict") {
            appState.pendingExternalTexts[location.fileURL] == "disk B"
        }

        XCTAssertTrue(appState.currentDocument === session)
        XCTAssertEqual(appState.pendingExternalTexts[location.fileURL], "disk B")
        XCTAssertEqual(
            appState.unanchoredManagedSessionOwnershipProofs[sessionIdentity],
            .proven(originalProof)
        )
        XCTAssertNil(appState.sessionAutosaveTasks[sessionIdentity])
        XCTAssertThrowsError(try appState.save(session: session))
        XCTAssertEqual(try String(contentsOf: location.fileURL, encoding: .utf8), "disk B")
    }

    func testAnchoredSameInodeRewriteWithPreservedMtimeEntersConflictAndBlocksOverwrite() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: "post.md")
        try writeText("Original", to: location.fileURL)
        let loaded = try MarkdownFileStore().loadResult(at: location)
        let originalStatus = try fileStatus(at: location.fileURL)
        let session = DocumentSession(
            text: loaded.file.text,
            url: location.fileURL,
            fileKind: .markdown,
            isDirty: false
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.sessionCache[location.fileURL] = session
        let originalBinding = AnchoredWorkspaceSessionFileBinding(
            location: location,
            identity: loaded.metadata.identity,
            sha256Digest: loaded.sha256Digest
        )
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] = originalBinding
        appState.replaceDocumentText("Local anchored edits", in: session)

        let handle = try FileHandle(forWritingTo: location.fileURL)
        try handle.truncate(atOffset: 0)
        handle.write(Data("Changed anchored, same inode".utf8))
        try handle.close()
        try restoreAccessAndModificationTimes(of: location.fileURL, from: originalStatus)
        let rewrittenStatus = try fileStatus(at: location.fileURL)
        XCTAssertEqual(rewrittenStatus.st_ino, originalStatus.st_ino)
        assertModificationTime(rewrittenStatus, matches: originalStatus)

        appState.handleExternalChange(for: session)
        try await waitUntil("anchored same-inode rewrite publishes a conflict") {
            appState.pendingExternalTexts[location.fileURL] == "Changed anchored, same inode"
        }

        XCTAssertEqual(appState.pendingExternalTexts[location.fileURL], "Changed anchored, same inode")
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: session), originalBinding)
        XCTAssertEqual(session.text, "Local anchored edits")
        XCTAssertFalse(appState.canAutosave(session: session))
        appState.flushAutosaveIfNeeded()
        XCTAssertThrowsError(try appState.saveCurrentDocument())
        XCTAssertEqual(try String(contentsOf: location.fileURL, encoding: .utf8), "Changed anchored, same inode")
    }

    func testAnchoredReplacementInodeWithPreservedMtimeEntersConflictAndBlocksOverwrite() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: "post.md")
        try writeText("Original", to: location.fileURL)
        let loaded = try MarkdownFileStore().loadResult(at: location)
        let originalStatus = try fileStatus(at: location.fileURL)
        let session = DocumentSession(
            text: loaded.file.text,
            url: location.fileURL,
            fileKind: .markdown,
            isDirty: false
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = root
        appState.workspaceSearchRootAuthority = authority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.sessionCache[location.fileURL] = session
        let originalBinding = AnchoredWorkspaceSessionFileBinding(
            location: location,
            identity: loaded.metadata.identity,
            sha256Digest: loaded.sha256Digest
        )
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] = originalBinding
        appState.replaceDocumentText("Local anchored edits", in: session)

        try "Changed anchored, replaced inode".write(
            to: location.fileURL,
            atomically: true,
            encoding: .utf8
        )
        try restoreAccessAndModificationTimes(of: location.fileURL, from: originalStatus)
        let replacementStatus = try fileStatus(at: location.fileURL)
        XCTAssertNotEqual(replacementStatus.st_ino, originalStatus.st_ino)
        assertModificationTime(replacementStatus, matches: originalStatus)

        appState.handleExternalChange(for: session)
        try await waitUntil("anchored replacement inode publishes a conflict") {
            appState.pendingExternalTexts[location.fileURL] == "Changed anchored, replaced inode"
        }

        XCTAssertEqual(
            appState.pendingExternalTexts[location.fileURL],
            "Changed anchored, replaced inode"
        )
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: session), originalBinding)
        XCTAssertEqual(session.text, "Local anchored edits")
        XCTAssertFalse(appState.canAutosave(session: session))
        appState.flushAutosaveIfNeeded()
        XCTAssertThrowsError(try appState.saveCurrentDocument())
        XCTAssertEqual(
            try String(contentsOf: location.fileURL, encoding: .utf8),
            "Changed anchored, replaced inode"
        )
    }

    func testStandaloneSaveDetectedExternalVersionEntersConflictBeforeOverwrite() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let post = directory.appendingPathComponent("post.md")
        try writeText("disk A", to: post)
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        appState.openExternalFile(post)
        try await waitUntil("standalone save-race source opens") {
            appState.currentDocument.fileURL?.standardizedFileURL == post.standardizedFileURL
        }
        let session = appState.currentDocument
        guard case let .proven(proofA)? =
            appState.unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(session)]
        else {
            return XCTFail("standalone source must retain a proof before the save race")
        }
        appState.replaceDocumentText("local edits", in: session)
        XCTAssertNotNil(appState.autosaveTask)

        try writeText("disk B", to: post)

        XCTAssertThrowsError(try appState.saveCurrentDocument())
        try await waitUntil("standalone save race publishes a conflict") {
            appState.pendingExternalTexts[proofA.location.fileURL] == "disk B"
        }
        XCTAssertEqual(appState.pendingExternalTexts[proofA.location.fileURL], "disk B")
        XCTAssertEqual(
            appState.unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(session)],
            .proven(proofA)
        )
        XCTAssertEqual(appState.externalChangePrompt?.fileURL, proofA.location.fileURL)
        XCTAssertNil(appState.autosaveTask)
        XCTAssertFalse(appState.canAutosave(session: session))

        appState.flushAutosaveIfNeeded()
        XCTAssertThrowsError(try appState.saveCurrentDocument())
        XCTAssertEqual(try String(contentsOf: post, encoding: .utf8), "disk B")
    }

    func testAnchoredSaveDetectedExternalVersionEntersConflictBeforeOverwrite() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: "post.md")
        try writeText("disk A", to: location.fileURL)
        let loadedA = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(
            text: loadedA.file.text,
            url: location.fileURL,
            fileKind: .markdown,
            isDirty: false
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.sessionCache[location.fileURL] = session
        let bindingA = AnchoredWorkspaceSessionFileBinding(
            location: location,
            identity: loadedA.metadata.identity,
            sha256Digest: loadedA.sha256Digest
        )
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] = bindingA
        appState.replaceDocumentText("local edits", in: session)
        XCTAssertNotNil(appState.autosaveTask)

        try writeText("disk B", to: location.fileURL)

        XCTAssertThrowsError(try appState.saveCurrentDocument())
        try await waitUntil("anchored save race publishes a conflict") {
            appState.pendingExternalTexts[location.fileURL] == "disk B"
        }
        XCTAssertEqual(appState.pendingExternalTexts[location.fileURL], "disk B")
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: session), bindingA)
        XCTAssertEqual(appState.externalChangePrompt?.fileURL, location.fileURL)
        XCTAssertNil(appState.autosaveTask)
        XCTAssertFalse(appState.canAutosave(session: session))

        appState.flushAutosaveIfNeeded()
        XCTAssertThrowsError(try appState.saveCurrentDocument())
        XCTAssertEqual(try String(contentsOf: location.fileURL, encoding: .utf8), "disk B")
    }

    func testCachedAndRetiredAnchoredActivationDoNotAdoptExternalProofBeforeArbitration() throws {
        for source in ["cached", "retired"] {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
            let location = try authority.location(relativePath: "post.md")
            try writeText("disk A", to: location.fileURL)
            let original = try MarkdownFileStore().loadResult(at: location)
            let session = DocumentSession(
                text: original.file.text,
                url: location.fileURL,
                fileKind: .markdown,
                isDirty: false
            )
            let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
            appState.workspaceRootURL = root
            appState.workspaceSearchRootAuthority = authority
            appState.workspaceGeneration = 1
            appState.workspaceInstalledCaptureGeneration = 1
            let originalBinding = AnchoredWorkspaceSessionFileBinding(
                location: location,
                identity: original.metadata.identity,
                sha256Digest: original.sha256Digest
            )
            appState.anchoredSessionFileBindings[ObjectIdentifier(session)] = originalBinding
            appState.replaceDocumentText("local (source) edits", in: session)

            let retiredBindingID: EditorDocumentBindingID?
            var staleInspectionTask: Task<Void, Never>?
            switch source {
            case "cached":
                appState.sessionCache[location.fileURL] = session
                retiredBindingID = nil
            case "retired":
                let bindingID = EditorDocumentBindingID()
                appState.retiredEditorDocumentSessions[location.fileURL] = RetiredEditorDocumentSession(
                    canonicalURL: location.fileURL,
                    session: session,
                    bindingIDs: [bindingID],
                    awaitingInstallations: [],
                    securityScopedAuthorityOwners: []
                )
                retiredBindingID = bindingID
                appState.setCurrentDocument(
                    DocumentSession(text: "other", fileKind: .markdown),
                    synchronizingWorkspaceTree: false
                )
                let task = Task {
                    _ = try? await Task.sleep(nanoseconds: 60_000_000_000)
                }
                staleInspectionTask = task
                appState.externalDiskInspectionTasks[ObjectIdentifier(session)] =
                    ExternalDiskInspectionTask(
                        token: UUID(),
                        session: session,
                        canonicalURL: location.fileURL,
                        location: location,
                        lifecycleGeneration: appState.currentSessionLifecycleGeneration(
                            for: session
                        ),
                        diskEventGeneration: appState.currentExternalDiskEventGeneration(
                            for: session
                        ),
                        sourceSnapshot: EditorDocumentSourceSnapshot(
                            source: session.text,
                            revision: session.version
                        ),
                        task: task
                    )
            default:
                XCTFail("unexpected activation source")
                continue
            }
            defer { staleInspectionTask?.cancel() }

            try writeText("disk B (source)", to: location.fileURL)
            let observed = try MarkdownFileStore().loadResult(at: location)
            let activation = try appState.prepareAnchoredFileSessionActivation(
                file: observed.file,
                at: location,
                metadata: observed.metadata,
                sha256Digest: observed.sha256Digest
            )
            switch (source, activation.source) {
            case ("cached", .cached), ("retired", .retired(_)):
                break
            default:
                XCTFail("activation must retain its expected reusable-session source")
            }

            appState.commitAnchoredFileSessionActivation(activation)

            XCTAssertEqual(
                appState.anchoredSessionFileBinding(for: session),
                originalBinding,
                "\(source) activation must keep A's identity/SHA until explicit resolution"
            )
            XCTAssertEqual(session.text, "local (source) edits")
            XCTAssertEqual(appState.pendingExternalTexts[location.fileURL], "disk B (source)")
            XCTAssertFalse(appState.canAutosave(session: session))
            if retiredBindingID != nil {
                XCTAssertNotNil(
                    appState.retiredEditorDocumentSessions[location.fileURL],
                    "a rejected retired activation must not drop its retained authority"
                )
                XCTAssertNil(appState.externalDiskInspectionTasks[ObjectIdentifier(session)])
                XCTAssertEqual(staleInspectionTask?.isCancelled, true)
            }
            appState.flushAutosaveIfNeeded()
            XCTAssertThrowsError(try appState.save(session: session))
            XCTAssertEqual(try String(contentsOf: location.fileURL, encoding: .utf8), "disk B (source)")
        }
    }

    // swiftlint:disable:next function_body_length
    func testRetiredAnchoredDetachedActivationRequiresResolutionForSameObservedVersion() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parkedURL = root.appendingPathComponent("post-parked.md").standardizedFileURL
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: "post.md")
        try writeText("disk A", to: location.fileURL)
        let original = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(
            text: original.file.text,
            url: location.fileURL,
            fileKind: .markdown,
            isDirty: false
        )
        session.replaceText("local edits")
        let appState = AppState(
            currentDocument: DocumentSession(text: "other", fileKind: .markdown),
            shouldRestoreLastOpenedFile: false
        )
        defer { appState.autosaveTask?.cancel() }
        let originalBinding = AnchoredWorkspaceSessionFileBinding(
            location: location,
            identity: original.metadata.identity,
            sha256Digest: original.sha256Digest
        )
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] = originalBinding
        let bindingID = EditorDocumentBindingID()
        appState.retiredEditorDocumentSessions[location.fileURL] = RetiredEditorDocumentSession(
            canonicalURL: location.fileURL,
            session: session,
            bindingIDs: [bindingID],
            awaitingInstallations: [],
            securityScopedAuthorityOwners: []
        )

        try FileManager.default.moveItem(at: location.fileURL, to: parkedURL)
        appState.handleExternalChange(for: session)
        try await waitUntil("retired anchored session detaches") {
            appState.detachedSessionURLs.contains(location.fileURL)
        }
        XCTAssertTrue(appState.detachedSessionURLs.contains(location.fileURL))

        try FileManager.default.moveItem(at: parkedURL, to: location.fileURL)
        let restored = try MarkdownFileStore().loadResult(at: location)
        XCTAssertEqual(restored.metadata.identity, original.metadata.identity)
        XCTAssertEqual(restored.sha256Digest, original.sha256Digest)
        let activation = try appState.prepareAnchoredFileSessionActivation(
            file: restored.file,
            at: location,
            metadata: restored.metadata,
            sha256Digest: restored.sha256Digest
        )
        guard case .retired = activation.source else {
            return XCTFail("detached retained session must use retired activation")
        }

        appState.commitAnchoredFileSessionActivation(activation)
        try await waitUntil("retired anchored activation publishes a conflict") {
            appState.pendingExternalTexts[location.fileURL] == "disk A"
        }

        XCTAssertTrue(appState.currentDocument === session)
        XCTAssertTrue(appState.detachedSessionURLs.contains(location.fileURL))
        XCTAssertEqual(appState.pendingExternalTexts[location.fileURL], "disk A")
        XCTAssertEqual(appState.externalChangePrompt?.fileURL, location.fileURL)
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: session), originalBinding)
        XCTAssertNotNil(appState.retiredEditorDocumentSessions[location.fileURL])
        XCTAssertFalse(appState.canAutosave(session: session))
        XCTAssertThrowsError(try appState.save(session: session))

        appState.reloadExternallyChangedFile()
        try await waitUntil("retired anchored Reload converges") {
            session.text == "disk A" &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }

        XCTAssertEqual(session.text, "disk A")
        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(appState.detachedSessionURLs.contains(location.fileURL))
        XCTAssertNil(appState.pendingExternalTexts[location.fileURL])
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertNil(appState.retiredEditorDocumentSessions[location.fileURL])
    }

    // swiftlint:disable:next function_body_length
    func testRetiredStandaloneDetachedActivationRequiresResolutionForSameObservedVersion() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let postURL = root.appendingPathComponent("post.md").standardizedFileURL
        let parkedURL = root.appendingPathComponent("post-parked.md").standardizedFileURL
        try writeText("disk A", to: postURL)
        let location = try WorkspaceFileSystemLocation(fileURL: postURL)
        let original = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(
            text: original.file.text,
            url: location.fileURL,
            fileKind: .markdown,
            isDirty: false
        )
        session.replaceText("local edits")
        let appState = AppState(
            currentDocument: DocumentSession(text: "other", fileKind: .markdown),
            shouldRestoreLastOpenedFile: false
        )
        defer { appState.autosaveTask?.cancel() }
        let originalProof = UnanchoredManagedSessionFileProof(
            location: location,
            identity: original.metadata.identity,
            sha256Digest: original.sha256Digest,
            installedWorkspaceLocation: nil
        )
        appState.unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(session)] = .proven(
            originalProof
        )
        let bindingID = EditorDocumentBindingID()
        appState.retiredEditorDocumentSessions[location.fileURL] = RetiredEditorDocumentSession(
            canonicalURL: location.fileURL,
            session: session,
            bindingIDs: [bindingID],
            awaitingInstallations: [],
            securityScopedAuthorityOwners: []
        )

        try FileManager.default.moveItem(at: location.fileURL, to: parkedURL)
        appState.handleExternalChange(for: session)
        try await waitUntil("retired standalone session detaches") {
            appState.detachedSessionURLs.contains(location.fileURL)
        }
        XCTAssertTrue(appState.detachedSessionURLs.contains(location.fileURL))

        try FileManager.default.moveItem(at: parkedURL, to: location.fileURL)
        let restored = try MarkdownFileStore().loadResult(at: location)
        XCTAssertEqual(restored.metadata.identity, original.metadata.identity)
        XCTAssertEqual(restored.sha256Digest, original.sha256Digest)

        try appState.activateFileSession(url: location.fileURL)
        try await waitUntil("retired standalone activation publishes a conflict") {
            appState.pendingExternalTexts[location.fileURL] == "disk A"
        }

        XCTAssertTrue(appState.currentDocument === session)
        XCTAssertTrue(appState.sessionCache[location.fileURL] === session)
        XCTAssertTrue(appState.detachedSessionURLs.contains(location.fileURL))
        XCTAssertEqual(appState.pendingExternalTexts[location.fileURL], "disk A")
        XCTAssertEqual(appState.externalChangePrompt?.fileURL, location.fileURL)
        XCTAssertEqual(
            appState.unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(session)],
            .proven(originalProof)
        )
        XCTAssertNil(appState.retiredEditorDocumentSessions[location.fileURL])
        XCTAssertFalse(appState.canAutosave(session: session))
        XCTAssertThrowsError(try appState.save(session: session))

        appState.reloadExternallyChangedFile()
        try await waitUntil("retired standalone Reload converges") {
            session.text == "disk A" &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }

        XCTAssertEqual(session.text, "disk A")
        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(appState.detachedSessionURLs.contains(location.fileURL))
        XCTAssertNil(appState.pendingExternalTexts[location.fileURL])
        XCTAssertNil(appState.externalChangePrompt)
    }

    func testStandaloneCachedAndRetiredSessionsDoNotCrossReplacementParentAuthority() throws {
        for source in ["cached", "retired"] {
            let parent = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: parent) }
            let root = parent.appendingPathComponent("workspace", isDirectory: true)
            let movedRoot = parent.appendingPathComponent("captured-A", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let sourceURL = root.appendingPathComponent("post.md")
            try writeText("disk A", to: sourceURL)
            let locationA = try WorkspaceFileSystemLocation(fileURL: sourceURL)
            let loadedA = try MarkdownFileStore().loadResult(at: locationA)
            let session = DocumentSession(
                text: "local A edits",
                url: locationA.fileURL,
                fileKind: .markdown,
                isDirty: true
            )
            let appState = AppState(
                currentDocument: DocumentSession(),
                shouldRestoreLastOpenedFile: false
            )
            let sessionIdentity = ObjectIdentifier(session)
            let proofA = UnanchoredManagedSessionFileProof(
                location: locationA,
                identity: loadedA.metadata.identity,
                sha256Digest: loadedA.sha256Digest,
                installedWorkspaceLocation: nil
            )
            appState.unanchoredManagedSessionOwnershipProofs[sessionIdentity] = .proven(proofA)

            let retiredBindingID: EditorDocumentBindingID?
            switch source {
            case "cached":
                appState.sessionCache[locationA.fileURL] = session
                retiredBindingID = nil
            case "retired":
                let bindingID = EditorDocumentBindingID()
                appState.retiredEditorDocumentSessions[locationA.fileURL] = RetiredEditorDocumentSession(
                    canonicalURL: locationA.fileURL,
                    session: session,
                    bindingIDs: [bindingID],
                    awaitingInstallations: [],
                    securityScopedAuthorityOwners: []
                )
                retiredBindingID = bindingID
            default:
                XCTFail("unexpected source")
                continue
            }

            try FileManager.default.moveItem(at: root, to: movedRoot)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try writeText("disk B", to: sourceURL)
            let locationB = try WorkspaceFileSystemLocation(fileURL: sourceURL)
            XCTAssertEqual(locationB.fileURL, locationA.fileURL)
            XCTAssertNotEqual(locationB, locationA)

            switch source {
            case "cached":
                XCTAssertThrowsError(try appState.activateFileSession(url: sourceURL))
                XCTAssertTrue(appState.currentDocument !== session)
                XCTAssertTrue(appState.sessionCache[locationA.fileURL] === session)
            case "retired":
                try appState.activateFileSession(url: sourceURL)
                XCTAssertTrue(appState.currentDocument !== session)
                XCTAssertEqual(appState.currentDocument.text, "disk B")
                let bindingID = try XCTUnwrap(retiredBindingID)
                let retirement = appState.retiredEditorDocumentSessions[locationA.fileURL]
                XCTAssertTrue(retirement?.session === session)
                XCTAssertTrue(retirement?.bindingIDs.contains(bindingID) == true)
            default:
                XCTFail("unexpected source")
            }

            XCTAssertEqual(
                appState.unanchoredManagedSessionOwnershipProofs[sessionIdentity],
                .proven(proofA)
            )
            XCTAssertThrowsError(try appState.save(session: session))
            XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "disk B")
        }
    }

    func testStatefulRetiredStandaloneSessionRejectsReplacementParentAuthority() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let movedRoot = parent.appendingPathComponent("captured-A", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("post.md")
        try writeText("disk A", to: sourceURL)
        let locationA = try WorkspaceFileSystemLocation(fileURL: sourceURL)
        let loadedA = try MarkdownFileStore().loadResult(at: locationA)
        let session = DocumentSession(
            text: "local A edits",
            url: locationA.fileURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(
            currentDocument: DocumentSession(),
            shouldRestoreLastOpenedFile: false
        )
        let sessionIdentity = ObjectIdentifier(session)
        let proofA = UnanchoredManagedSessionFileProof(
            location: locationA,
            identity: loadedA.metadata.identity,
            sha256Digest: loadedA.sha256Digest,
            installedWorkspaceLocation: nil
        )
        appState.unanchoredManagedSessionOwnershipProofs[sessionIdentity] = .proven(proofA)
        let bindingID = EditorDocumentBindingID()
        appState.retiredEditorDocumentSessions[locationA.fileURL] = RetiredEditorDocumentSession(
            canonicalURL: locationA.fileURL,
            session: session,
            bindingIDs: [bindingID],
            awaitingInstallations: [],
            securityScopedAuthorityOwners: []
        )

        try writeText("disk B1", to: sourceURL)
        appState.handleExternalChange(for: session)
        try await waitUntil("retired standalone session records B1") {
            appState.pendingExternalTexts[locationA.fileURL] == "disk B1"
        }
        XCTAssertEqual(appState.pendingExternalTexts[locationA.fileURL], "disk B1")
        XCTAssertEqual(
            appState.unanchoredManagedSessionOwnershipProofs[sessionIdentity],
            .proven(proofA)
        )

        try FileManager.default.moveItem(at: root, to: movedRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeText("disk B2", to: sourceURL)
        let locationB = try WorkspaceFileSystemLocation(fileURL: sourceURL)
        let loadedB = try MarkdownFileStore().loadResult(at: locationB)
        XCTAssertEqual(locationB.fileURL, locationA.fileURL)
        XCTAssertNotEqual(locationB, locationA)

        XCTAssertThrowsError(try appState.activateFileSession(url: sourceURL)) { error in
            guard case let .invalidSessionIdentity(url) = error as? AppStateError else {
                return XCTFail("replacement B must fail through the authority identity guard: \(error)")
            }
            XCTAssertEqual(url, locationB.fileURL)
        }
        XCTAssertTrue(appState.retiredEditorDocumentSessions[locationA.fileURL]?.session === session)
        XCTAssertNil(appState.sessionCache[locationB.fileURL])
        XCTAssertEqual(appState.pendingExternalTexts[locationA.fileURL], "disk B1")
        XCTAssertEqual(
            appState.unanchoredManagedSessionOwnershipProofs[sessionIdentity],
            .proven(proofA)
        )

        // Even if a fresh B session was already cached at the lexical key, it must not consume
        // A's pending fence through the cache-hit fast path.
        let cachedB = DocumentSession(
            text: loadedB.file.text,
            url: locationB.fileURL,
            fileKind: loadedB.file.fileKind,
            isDirty: false
        )
        appState.sessionCache[locationB.fileURL] = cachedB
        appState.unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(cachedB)] = .proven(
            UnanchoredManagedSessionFileProof(
                location: locationB,
                identity: loadedB.metadata.identity,
                sha256Digest: loadedB.sha256Digest,
                installedWorkspaceLocation: nil
            )
        )
        XCTAssertThrowsError(try appState.activateFileSession(url: sourceURL))
        XCTAssertTrue(appState.sessionCache[locationB.fileURL] === cachedB)
        XCTAssertTrue(appState.currentDocument !== cachedB)
        XCTAssertEqual(appState.pendingExternalTexts[locationA.fileURL], "disk B1")
        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "disk B2")
    }

    func testStatefulAwaitingRetiredAnchoredSessionRejectsReplacementParentAuthority() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let movedRoot = parent.appendingPathComponent("captured-A", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let authorityA = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let locationA = try authorityA.location(relativePath: "post.md")
        try writeText("disk A", to: locationA.fileURL)
        let loadedA = try MarkdownFileStore().loadResult(at: locationA)
        let session = DocumentSession(
            text: "local A edits",
            url: locationA.fileURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(
            currentDocument: DocumentSession(),
            shouldRestoreLastOpenedFile: false
        )
        let bindingA = AnchoredWorkspaceSessionFileBinding(
            location: locationA,
            identity: loadedA.metadata.identity,
            sha256Digest: loadedA.sha256Digest
        )
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] = bindingA
        let bindingID = EditorDocumentBindingID()
        appState.retiredEditorDocumentSessions[locationA.fileURL] = RetiredEditorDocumentSession(
            canonicalURL: locationA.fileURL,
            session: session,
            bindingIDs: [bindingID],
            awaitingInstallations: [],
            securityScopedAuthorityOwners: []
        )

        try writeText("disk B1", to: locationA.fileURL)
        appState.handleExternalChange(for: session)
        try await waitUntil("retired anchored session records B1") {
            appState.pendingExternalTexts[locationA.fileURL] == "disk B1"
        }
        XCTAssertEqual(appState.pendingExternalTexts[locationA.fileURL], "disk B1")
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: session), bindingA)

        try FileManager.default.moveItem(at: root, to: movedRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeText("disk B2", to: root.appendingPathComponent("post.md"))
        let authorityB = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let locationB = try authorityB.location(relativePath: "post.md")
        XCTAssertEqual(locationB.fileURL, locationA.fileURL)
        XCTAssertNotEqual(locationB, locationA)
        let loadedB = try MarkdownFileStore().loadResult(at: locationB)

        XCTAssertThrowsError(try appState.prepareAnchoredFileSessionActivation(
            file: loadedB.file,
            at: locationB,
            metadata: loadedB.metadata,
            sha256Digest: loadedB.sha256Digest
        )) { error in
            guard case let .invalidSessionIdentity(url) = error as? AppStateError else {
                return XCTFail("replacement B must fail through the authority identity guard: \(error)")
            }
            XCTAssertEqual(url, locationB.fileURL)
        }
        XCTAssertTrue(appState.retiredEditorDocumentSessions[locationA.fileURL]?.session === session)
        XCTAssertEqual(appState.pendingExternalTexts[locationA.fileURL], "disk B1")
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: session), bindingA)
        XCTAssertEqual(try String(contentsOf: locationB.fileURL, encoding: .utf8), "disk B2")
    }

    func testReloadExternalConflictUsesFreshCTextAndProofAfterPendingB() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: "post.md")
        try writeText("disk A", to: location.fileURL)
        let loadedA = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(
            text: loadedA.file.text,
            url: location.fileURL,
            fileKind: .markdown,
            isDirty: false
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.sessionCache[location.fileURL] = session
        let bindingA = AnchoredWorkspaceSessionFileBinding(
            location: location,
            identity: loadedA.metadata.identity,
            sha256Digest: loadedA.sha256Digest
        )
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] = bindingA
        appState.replaceDocumentText("local edits")

        try writeText("disk B", to: location.fileURL)
        appState.handleExternalChange(for: session)
        try await waitUntil("Reload scenario records disk B") {
            appState.pendingExternalTexts[location.fileURL] == "disk B"
        }
        XCTAssertEqual(appState.pendingExternalTexts[location.fileURL], "disk B")
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: session), bindingA)

        try writeText("disk C", to: location.fileURL)
        let loadedC = try MarkdownFileStore().loadResult(at: location)
        appState.reloadExternallyChangedFile()
        try await waitUntil("Reload applies fresh disk C") {
            session.text == "disk C" &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }

        XCTAssertEqual(session.text, "disk C")
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(
            appState.anchoredSessionFileBinding(for: session),
            AnchoredWorkspaceSessionFileBinding(
                location: location,
                identity: loadedC.metadata.identity,
                sha256Digest: loadedC.sha256Digest
            )
        )
        XCTAssertNil(appState.pendingExternalTexts[location.fileURL])
        XCTAssertNil(appState.pendingExternalFileVersions[location.fileURL])
        XCTAssertNil(appState.externalChangePrompt)
    }

    func testKeepMineExternalConflictUsesFreshCProofBeforeWritingLocalEdits() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: "post.md")
        try writeText("disk A", to: location.fileURL)
        let loadedA = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(
            text: loadedA.file.text,
            url: location.fileURL,
            fileKind: .markdown,
            isDirty: false
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.sessionCache[location.fileURL] = session
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] =
            AnchoredWorkspaceSessionFileBinding(
                location: location,
                identity: loadedA.metadata.identity,
                sha256Digest: loadedA.sha256Digest
            )
        appState.replaceDocumentText("local edits")

        try writeText("disk B", to: location.fileURL)
        appState.handleExternalChange(for: session)
        try await waitUntil("Keep Mine scenario records disk B") {
            appState.pendingExternalTexts[location.fileURL] == "disk B"
        }
        try writeText("disk C", to: location.fileURL)
        let loadedC = try MarkdownFileStore().loadResult(at: location)

        var expectations: [WorkspaceNoFollowFileWriteExpectation] = []
        appState.anchoredFileSaveOverride = { text, fileLocation, expectation in
            expectations.append(expectation)
            return try MarkdownFileStore().save(text: text, at: fileLocation, expecting: expectation)
        }
        appState.keepMineForExternallyChangedFile()
        try await waitUntil("Keep Mine adopts fresh disk C proof") {
            appState.pendingExternalTexts[location.fileURL] == nil &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }

        XCTAssertEqual(
            appState.anchoredSessionFileBinding(for: session),
            AnchoredWorkspaceSessionFileBinding(
                location: location,
                identity: loadedC.metadata.identity,
                sha256Digest: loadedC.sha256Digest
            )
        )
        XCTAssertNil(appState.pendingExternalTexts[location.fileURL])
        XCTAssertTrue(session.isDirty)
        try appState.saveCurrentDocument()
        XCTAssertEqual(
            expectations,
            [
                .existingContent(
                    loadedC.metadata.identity,
                    sha256Digest: loadedC.sha256Digest
                ),
            ]
        )
        XCTAssertEqual(try String(contentsOf: location.fileURL, encoding: .utf8), "local edits")
    }

    func testKeepMineRebasesSavedTextToFreshCanonicalEquivalentC() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: "post.md")
        let diskA = "cafe\u{0301}"
        let diskC = "caf\u{00E9}"
        XCTAssertTrue(diskA == diskC)
        XCTAssertFalse(ExactSourceText.matches(diskA, diskC))
        try writeText(diskA, to: location.fileURL)
        let loadedA = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(
            text: loadedA.file.text,
            url: location.fileURL,
            fileKind: .markdown,
            isDirty: false
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        defer { appState.autosaveTask?.cancel() }
        appState.sessionCache[location.fileURL] = session
        _ = appState.sessionPolicy.access(location.fileURL, isDirty: false)
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] =
            AnchoredWorkspaceSessionFileBinding(
                location: location,
                identity: loadedA.metadata.identity,
                sha256Digest: loadedA.sha256Digest
            )
        let localText = "local edits"
        appState.replaceDocumentText(localText)

        try writeText("disk B", to: location.fileURL)
        appState.handleExternalChange(for: session)
        try await waitUntil("canonical-equivalent scenario records disk B") {
            appState.pendingExternalTexts[location.fileURL] == "disk B"
        }
        try writeText(diskC, to: location.fileURL)

        appState.keepMineForExternallyChangedFile()
        try await waitUntil("Keep Mine rebases the exact disk C bytes") {
            appState.pendingExternalTexts[location.fileURL] == nil &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }
        appState.autosaveTask?.cancel()

        XCTAssertTrue(ExactSourceText.matches(session.text, localText))
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(appState.sessionPolicy.dirtyState(for: location.fileURL), true)
        XCTAssertEqual(try Data(contentsOf: location.fileURL), Data(diskC.utf8))

        appState.replaceDocumentText(diskC)

        XCTAssertTrue(ExactSourceText.matches(session.text, diskC))
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(appState.sessionPolicy.dirtyState(for: location.fileURL), false)

        appState.replaceDocumentText(diskA)

        XCTAssertTrue(ExactSourceText.matches(session.text, diskA))
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(appState.sessionPolicy.dirtyState(for: location.fileURL), true)
        XCTAssertEqual(try Data(contentsOf: location.fileURL), Data(diskC.utf8))
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
        } catch WorkspaceAnchoredFileSystemError.namespaceChanged {
            // A real initial root-proof failure must reach the normal error path.
        } catch {
            XCTFail("Expected namespaceChanged, got \(error)")
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
        } catch WorkspaceAnchoredFileSystemError.namespaceChanged {
            // A real initial root-proof failure must reach the normal error path.
        } catch {
            XCTFail("Expected namespaceChanged, got \(error)")
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

    private func assertUnavailableIndeterminateSaveCopyReconciliation(
        state: IndeterminateFileWriteReconciliationState,
        makeUnavailable: @escaping (URL) throws -> Void,
        repair: (URL) throws -> Void
    ) async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appendingPathComponent("missing.md").standardizedFileURL
        let destinationURL = root.appendingPathComponent("recovered.md").standardizedFileURL
        try writeText("original disk", to: originalURL)
        let session = DocumentSession(
            text: "unsaved A",
            url: originalURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.sessionCache[originalURL] = session
        try FileManager.default.removeItem(at: originalURL)
        appState.markSessionDetachedFromMissingFile(session, url: originalURL)
        let indeterminate = WorkspaceIndeterminateFileWrite(
            reason: .durabilityFailed,
            preparedMetadata: nil,
            recoveryArtifact: .none
        )
        var writerEntries = 0
        appState.anchoredFileSaveOverride = { _, _, expectation in
            writerEntries += 1
            XCTAssertEqual(expectation, .missing)
            try makeUnavailable(destinationURL)
            return .committedButIndeterminate(indeterminate)
        }

        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: destinationURL))

        XCTAssertEqual(writerEntries, 1)
        XCTAssertEqual(appState.currentDocument.fileURL, destinationURL)
        XCTAssertEqual(
            appState.currentDocument.fileURL?.absoluteString,
            destinationURL.absoluteString
        )
        XCTAssertEqual(
            appState.indeterminateFileWriteReconciliationPrompt,
            IndeterminateFileWriteReconciliationPrompt(fileURL: destinationURL, state: state)
        )
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertNil(appState.missingFilePrompt)
        XCTAssertFalse(appState.canSave)

        try repair(destinationURL)
        appState.refreshIndeterminateFileWriteReconciliation()

        XCTAssertNil(appState.indeterminateFileWriteReconciliationPrompt)
        XCTAssertEqual(appState.externalChangePrompt?.fileURL.standardizedFileURL, destinationURL)
        XCTAssertEqual(appState.pendingExternalTexts[destinationURL], "disk after repair")
        XCTAssertEqual(writerEntries, 1)

        appState.reloadExternallyChangedFile()
        try await waitUntil("Reload accepts the repaired Save Copy destination") {
            appState.indeterminateSessionWrites[ObjectIdentifier(session)] == nil &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }
        XCTAssertNil(appState.indeterminateSessionWrites[ObjectIdentifier(session)])
        XCTAssertEqual(session.text, "disk after repair")
        XCTAssertFalse(session.isDirty)
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
        return try WorkspaceFileSystemRootAuthority(rootURL: url).canonicalRootURL
    }

    private func imageAssetDirectoryEntries(in root: URL) throws -> [String] {
        let directory = root.appendingPathComponent("assets", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return []
        }
        return try directoryEntries(at: directory)
    }

    private func directoryEntries(at directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false)
        ).sorted()
    }

    private func configureImageAssetWorkspace(
        _ appState: AppState,
        rootURL: URL,
        currentSession: DocumentSession
    ) throws {
        let rootAuthority = try WorkspaceFileSystemRootAuthority(rootURL: rootURL)
        let fileURL = try XCTUnwrap(currentSession.fileURL)
        let location = try rootAuthority.canonicalizedLocation(forFileURL: fileURL)
        let preparedRead = try prepareEditorImageAssetDocumentRead(
            fileStore: MarkdownFileStore(),
            at: location
        )
        let loaded = preparedRead.result
        appState.workspaceRootURL = rootURL
        appState.workspaceSearchRootAuthority = rootAuthority
        appState.workspaceGeneration = 1
        appState.workspaceInstalledCaptureGeneration = 1
        appState.adoptAnchoredFileBinding(
            AnchoredWorkspaceSessionFileBinding(
                location: location,
                identity: loaded.metadata.identity,
                sha256Digest: loaded.sha256Digest
            ),
            for: currentSession,
            preparedImageAssetAuthority: preparedRead.preparedAuthority,
            allowsImageAssetAuthorityBootstrap: true
        )
        appState.sessionCache[location.fileURL] = currentSession
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

    private func fileStatus(at url: URL) throws -> stat {
        var status = stat()
        let result = url.path(percentEncoded: false).withCString {
            Darwin.lstat($0, &status)
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status
    }

    private func restoreAccessAndModificationTimes(of url: URL, from status: stat) throws {
        var timestamps = [status.st_atimespec, status.st_mtimespec]
        let result = url.path(percentEncoded: false).withCString { path in
            timestamps.withUnsafeMutableBufferPointer { values in
                Darwin.utimensat(AT_FDCWD, path, values.baseAddress, 0)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func assertModificationTime(_ actual: stat, matches expected: stat) {
        XCTAssertEqual(actual.st_mtimespec.tv_sec, expected.st_mtimespec.tv_sec)
        XCTAssertEqual(actual.st_mtimespec.tv_nsec, expected.st_mtimespec.tv_nsec)
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
    func testSearchNavigationCancellationStillAutomaticallyInstallsSingleDestinationUpdate() async throws {
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
        appState.sessionPolicy = WorkspaceSessionLRUPolicy(limit: 1)
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["a.md", "b.md"],
            currentSession: sessionA
        )
        let rootAuthority = try XCTUnwrap(appState.workspaceSearchRootAuthority)

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
            onDocumentBindingLifecycle: bindingA.onLifecycle,
            documentSourceContract: bindingA.sourceContract
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

        XCTAssertTrue(appState.isEditorDocumentBindingInstalled(bindingA.id, session: sessionA))
        let installationA = try XCTUnwrap(
            appState.editorBindingInstallations.first(where: { $0.value === sessionA })?.key
        )
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.textSelection = selectionA ?? .notFound
        fixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        XCTAssertTrue(fixture.textView.hasMarkedText())

        let searchResult = result(
            path: "a.md",
            text: sourceA,
            needle: "composition",
            rootURL: rootURL
        )
        let searchMatch = try XCTUnwrap(searchResult.matches.first)
        let searchContext = WorkspaceSearchContext(
            rootIdentity: rootAuthority.canonicalRootURL.path(percentEncoded: false),
            workspaceGeneration: appState.workspaceGeneration,
            queryGeneration: 1
        )
        appState.workspaceSearchState = WorkspaceSearchState(
            activeQuery: TextSearchQuery(pattern: "composition"),
            queryGeneration: 1,
            activeContext: searchContext,
            phase: .completed,
            fileResults: [searchResult]
        )
        appState.activateWorkspaceSearchResult(
            context: searchContext,
            fileResult: searchResult,
            match: searchMatch
        )
        guard case .navigate? = appState.editorNavigationCommand else {
            return XCTFail("Expected a real App search-navigation request for A")
        }
        let pendingNavigationAView = MarkdownTextView(
            text: bindingA.text,
            styledText: nil,
            selection: Binding(get: { selectionA }, set: { selectionA = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentAURL),
            documentBindingID: bindingA.id,
            onDocumentBindingLifecycle: bindingA.onLifecycle,
            documentSourceContract: bindingA.sourceContract,
            navigationCommand: appState.editorNavigationCommand
        )
        pendingNavigationAView.updateRepresentedTextView(
            fixture.scrollView,
            coordinator: fixture.coordinator
        )

        try appState.activateFileSession(url: documentBURL)
        guard case .cancel? = appState.editorNavigationCommand else {
            return XCTFail("Ordinary App document switch must emit navigation cancellation")
        }
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
            onDocumentBindingLifecycle: bindingB.onLifecycle,
            documentSourceContract: bindingB.sourceContract,
            navigationCommand: appState.editorNavigationCommand
        )
        documentBView.updateRepresentedTextView(
            fixture.scrollView,
            coordinator: fixture.coordinator
        )

        XCTAssertTrue(fixture.textView.hasMarkedText())
        XCTAssertTrue(appState.isEditorDocumentBindingInstalled(bindingA.id, session: sessionA))
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

        try await waitUntil("single destination update retries after IME commit") {
            appState.isEditorDocumentBindingInstalled(bindingB.id, session: sessionB) &&
                fixture.coordinator.currentDocumentIdentity == AppState.editorDocumentIdentity(
                    for: documentBURL
                )
        }
        XCTAssertTrue(appState.isEditorDocumentBindingInstalled(bindingB.id, session: sessionB))
        XCTAssertNil(appState.sessionCache[documentAURL.standardizedFileURL])
        XCTAssertEqual(fixture.coordinator.currentDocumentIdentity, AppState.editorDocumentIdentity(for: documentBURL))

        _ = bindingA.sourceContract.publish(EditorDocumentSourcePublication(
            installation: installationA,
            base: EditorDocumentSourceSnapshot(source: committedSourceA, revision: sessionA.version),
            source: committedSourceA + " rejected"
        ))
        XCTAssertEqual(Data(sessionA.text.utf8), Data(committedSourceA.utf8))
        let finalSourceB = "# B Unique\nB editor write succeeds"
        fixture.textView.textSelection = NSRange(
            location: 0,
            length: (dirtySourceB as NSString).length
        )
        fixture.textView.insertText(finalSourceB, replacementRange: .notFound)
        let installationB = try XCTUnwrap(
            appState.editorBindingInstallations.first(where: { $0.value === sessionB })?.key
        )
        XCTAssertEqual(Data(sessionB.text.utf8), Data(finalSourceB.utf8))
        XCTAssertEqual(Data(sessionA.text.utf8), Data(committedSourceA.utf8))

        MarkdownTextView.dismantleNSView(
            fixture.scrollView,
            coordinator: fixture.coordinator
        )
        XCTAssertTrue(appState.editorBindingInstallations.isEmpty)
        _ = bindingB.sourceContract.publish(EditorDocumentSourcePublication(
            installation: installationB,
            base: EditorDocumentSourceSnapshot(source: finalSourceB, revision: sessionB.version),
            source: finalSourceB + " rejected after teardown"
        ))
        XCTAssertEqual(Data(sessionB.text.utf8), Data(finalSourceB.utf8))

        appState.flushAutosaveIfNeeded()
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
        let canonicalA = try XCTUnwrap(appState.sessionStateURL(for: sessionA))
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
            onDocumentBindingLifecycle: bindingA.onLifecycle,
            documentSourceContract: bindingA.sourceContract
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
            onDocumentBindingLifecycle: bindingB.onLifecycle,
            documentSourceContract: bindingB.sourceContract
        )
        documentBView.updateRepresentedTextView(
            editorFixture.scrollView,
            coordinator: editorFixture.coordinator
        )
        XCTAssertTrue(appState.isEditorDocumentBindingInstalled(bindingA.id, session: sessionA))

        try externalSourceA.write(to: documentAURL, atomically: true, encoding: .utf8)
        appState.lastKnownDiskModificationDates[canonicalA] = .distantPast
        appState.handleExternalChange(for: sessionA)

        try await waitUntil("non-current A records its external conflict") {
            appState.pendingExternalTexts[canonicalA] == externalSourceA
        }
        XCTAssertEqual(appState.pendingExternalTexts[canonicalA], externalSourceA)
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertTrue(appState.currentDocument === sessionB)
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: canonicalA)
        appState.reloadExternallyChangedFile()
        XCTAssertEqual(appState.pendingExternalTexts[canonicalA], externalSourceA)
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: canonicalA)
        appState.keepMineForExternallyChangedFile()
        XCTAssertEqual(appState.pendingExternalTexts[canonicalA], externalSourceA)
        XCTAssertNil(appState.externalChangePrompt)

        let committedText = "臺e\u{0301}🧪"
        editorFixture.textView.insertText(committedText, replacementRange: .notFound)
        let committedSourceA = dirtySourceA + committedText
        XCTAssertFalse(documentBAutosave.isCancelled)
        XCTAssertFalse(documentBStatistics.isCancelled)
        XCTAssertFalse(documentBCompletion.isCancelled)
        XCTAssertTrue(appState.canAutosave(session: sessionB))
        XCTAssertFalse(appState.hasPendingEditorSource(for: sessionB))
        XCTAssertNil(appState.externalDiskInspectionTasks[ObjectIdentifier(sessionB)])
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
        XCTAssertNil(appState.presentedError, appState.presentedError?.message ?? "")
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
        XCTAssertTrue(appState.isEditorDocumentBindingInstalled(bindingB.id, session: sessionB))
        XCTAssertTrue(appState.sessionCache[canonicalA] === sessionA)
        XCTAssertTrue(sessionA.isDirty)
        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), externalSourceA)

        try appState.activateFileSession(url: documentAURL)
        XCTAssertEqual(appState.externalChangePrompt?.fileURL.standardizedFileURL, documentAURL.standardizedFileURL)
        appState.keepMineForExternallyChangedFile()
        try await waitUntil("non-current Keep Mine completes after reactivation") {
            appState.externalReloadTasks[ObjectIdentifier(sessionA)] == nil &&
                appState.externalChangePrompt == nil
        }
        XCTAssertNil(appState.pendingExternalTexts[canonicalA])
        XCTAssertTrue(appState.canAutosave(session: sessionA))
        try appState.save(session: sessionA)
        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), committedSourceA)
        XCTAssertFalse(sessionA.isDirty)
    }

    func testContentFencedBackgroundAutosaveDetectsInPlaceRewriteBeforeWatcher() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentAURL = rootURL.appendingPathComponent("a.md")
        let documentBURL = rootURL.appendingPathComponent("b.md")
        let originalA = "AAAA"
        let localA = "A local dirty source"
        let externalA = "BBBB"
        try originalA.write(to: documentAURL, atomically: true, encoding: .utf8)
        try "B source".write(to: documentBURL, atomically: true, encoding: .utf8)
        let defaultsSuiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.set(0.5, forKey: "Plainsong.settings.autosaveIntervalSeconds")
        let sessionA = DocumentSession(
            text: originalA,
            url: documentAURL,
            fileKind: .markdown
        )
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
        let canonicalA = try XCTUnwrap(appState.sessionStateURL(for: sessionA))
        appState.recordKnownDiskText(originalA, for: canonicalA)
        let originalIdentity = try regularIdentity(at: documentAURL)
        defer {
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
            appState.workspaceReloadTask?.cancel()
            for task in appState.sessionAutosaveTasks.values {
                task.task.cancel()
            }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: rootURL)
        }

        appState.replaceDocumentText(localA, in: sessionA)
        try appState.activateFileSession(url: documentBURL)
        XCTAssertNotNil(appState.sessionAutosaveTasks[ObjectIdentifier(sessionA)])
        let handle = try FileHandle(forWritingTo: documentAURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(externalA.utf8))
        try handle.synchronize()
        try handle.close()
        XCTAssertEqual(try regularIdentity(at: documentAURL), originalIdentity)

        try await waitUntil("content-fenced autosave starts coherent inspection") {
            appState.pendingExternalTexts[canonicalA] == externalA &&
                appState.externalDiskInspectionTasks[ObjectIdentifier(sessionA)] == nil
        }

        XCTAssertTrue(appState.currentDocument.fileURL == documentBURL)
        XCTAssertEqual(sessionA.text, localA)
        XCTAssertTrue(sessionA.isDirty)
        XCTAssertFalse(appState.canAutosave(session: sessionA))
        XCTAssertNil(appState.sessionAutosaveTasks[ObjectIdentifier(sessionA)])
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertEqual(appState.presentedError?.title, "Autosave Failed")
        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), externalA)
    }

    func testRealWatcherImmediatelyInspectsNonCurrentWarmSession() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentAURL = rootURL.appendingPathComponent("a.md")
        let documentBURL = rootURL.appendingPathComponent("b.md")
        let originalA = "AAAA"
        let externalA = "BBBB"
        try originalA.write(to: documentAURL, atomically: true, encoding: .utf8)
        try "B source".write(to: documentBURL, atomically: true, encoding: .utf8)
        let defaultsSuiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.set(30.0, forKey: "Plainsong.settings.autosaveIntervalSeconds")
        let sessionA = DocumentSession(
            text: originalA,
            url: documentAURL,
            fileKind: .markdown
        )
        let scanner = ControlledWorkspaceDirectoryScanner()
        let appState = AppState(
            currentDocument: sessionA,
            directoryScanner: scanner,
            shouldRestoreLastOpenedFile: false,
            userDefaults: defaults
        )
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["a.md", "b.md"],
            currentSession: sessionA
        )
        let canonicalA = try XCTUnwrap(appState.sessionStateURL(for: sessionA))
        appState.recordKnownDiskText(originalA, for: canonicalA)
        defer {
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
            appState.workspaceReloadTask?.cancel()
            for task in appState.sessionAutosaveTasks.values {
                task.task.cancel()
            }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: rootURL)
        }

        appState.replaceDocumentText("A local dirty source", in: sessionA)
        try appState.activateFileSession(url: documentBURL)
        let originalIdentity = try regularIdentity(at: documentAURL)
        let handle = try FileHandle(forWritingTo: documentAURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(externalA.utf8))
        try handle.synchronize()
        try handle.close()
        XCTAssertEqual(try regularIdentity(at: documentAURL), originalIdentity)

        appState.refreshWorkspaceAfterFileSystemChange()
        await scanner.waitForRequestCount(1)
        let reloadTask = appState.workspaceReloadTask

        try await waitUntil("real watcher fans out to non-current A before tree scan completes") {
            appState.pendingExternalTexts[canonicalA] == externalA &&
                appState.externalDiskInspectionTasks[ObjectIdentifier(sessionA)] == nil
        }
        XCTAssertNotNil(reloadTask)
        await scanner.completeRequest(
            at: 0,
            with: snapshot(paths: ["a.md", "b.md"], rootURL: rootURL)
        )
        await reloadTask?.value
        XCTAssertTrue(appState.currentDocument.fileURL == documentBURL)
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertFalse(appState.canAutosave(session: sessionA))
        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), externalA)
    }

    func testReloadClearsSessionConflictAndRestoresSaveEligibility() async throws {
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
        let canonicalURL = try XCTUnwrap(appState.sessionStateURL(for: session))
        defer {
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
            try? FileManager.default.removeItem(at: rootURL)
        }

        appState.replaceDocumentText(local, in: session)
        try external.write(to: documentURL, atomically: true, encoding: .utf8)
        appState.lastKnownDiskModificationDates[canonicalURL] = .distantPast
        appState.handleExternalChange(for: session)
        try await waitUntil("external conflict is ready for Reload") {
            appState.pendingExternalTexts[canonicalURL] == external &&
                appState.externalChangePrompt?.fileURL == canonicalURL
        }
        XCTAssertFalse(appState.canAutosave(session: session))
        XCTAssertThrowsError(try appState.save(session: session))

        appState.reloadExternallyChangedFile()

        try await waitUntil("Reload synchronizes the session and clears its conflict") {
            session.text == external &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }

        XCTAssertEqual(session.text, external)
        XCTAssertFalse(session.isDirty)
        XCTAssertNil(appState.pendingExternalTexts[canonicalURL])
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertTrue(appState.canAutosave(session: session))
        XCTAssertEqual(appState.sessionPolicy.dirtyState(for: documentURL), false)
        XCTAssertNoThrow(try appState.save(session: session))
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), external)
    }

    func testWatcherEventYSupersedesSuspendedReloadXAndStaleDropsOlderResult() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("post.md")
        let original = "Original"
        let local = "Local dirty text"
        let olderDisk = "Older delayed disk text"
        let newerDisk = "Newer delayed disk text"
        try original.write(to: documentURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let reader = ControlledCoherentFileReader()
        let session = DocumentSession(text: original, url: documentURL, fileKind: .markdown)
        let appState = AppState(
            currentDocument: session,
            coherentFileReader: reader,
            shouldRestoreLastOpenedFile: false
        )
        let key = try XCTUnwrap(appState.sessionStateURL(for: session))
        appState.sessionCache[key] = session
        appState.replaceDocumentText(local, in: session)
        appState.pendingExternalTexts[key] = "detected disk conflict"
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: key)

        appState.reloadExternallyChangedFile()
        try await waitUntil("first delayed Reload starts") { reader.requestCount == 1 }
        var mainActorAdvanced = false
        Task { @MainActor in mainActorAdvanced = true }
        await Task.yield()
        XCTAssertTrue(mainActorAdvanced)
        XCTAssertEqual(session.text, local)
        XCTAssertFalse(appState.canSave)

        appState.handleExternalChange(for: session)
        try await waitUntil("watcher event Y starts a newer physical read") { reader.requestCount == 2 }
        let identity = try regularIdentity(at: documentURL)
        reader.resolve(
            request: 0,
            with: .loaded(coherentSnapshot(text: olderDisk, identity: identity))
        )
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(session.text, local)
        XCTAssertEqual(appState.pendingExternalTexts[key], "detected disk conflict")

        reader.resolve(
            request: 1,
            with: .loaded(coherentSnapshot(text: newerDisk, identity: identity))
        )
        try await waitUntil("newer delayed Reload wins") {
            session.text == newerDisk &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }
        XCTAssertNil(appState.pendingExternalTexts[key])
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertTrue(appState.canSave)
    }

    func testReloadSelectionSupersedesOlderInFlightDiskInspection() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("post.md")
        let original = "Original"
        let local = "Local dirty text"
        let olderDisk = "Older inspection X"
        let newerDisk = "Resolution Y"
        try original.write(to: documentURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let reader = ControlledCoherentFileReader()
        let session = DocumentSession(text: original, url: documentURL, fileKind: .markdown)
        let appState = AppState(
            currentDocument: session,
            coherentFileReader: reader,
            shouldRestoreLastOpenedFile: false
        )
        let key = try XCTUnwrap(appState.sessionStateURL(for: session))
        appState.sessionCache[key] = session
        appState.replaceDocumentText(local, in: session)
        appState.pendingExternalTexts[key] = olderDisk
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: key)

        appState.handleExternalChange(for: session)
        try await waitUntil("older disk inspection suspends") { reader.requestCount == 1 }
        appState.reloadExternallyChangedFile()
        try await waitUntil("Reload starts a superseding read") { reader.requestCount == 2 }
        guard reader.requestCount == 2 else { return }
        XCTAssertNil(appState.externalDiskInspectionTasks[ObjectIdentifier(session)])

        let identity = try regularIdentity(at: documentURL)
        reader.resolve(
            request: 1,
            with: .loaded(coherentSnapshot(text: newerDisk, identity: identity))
        )
        try await waitUntil("Reload Y completes") {
            session.text == newerDisk &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }
        XCTAssertEqual(appState.lastKnownDiskHashes[key], AppState.contentHash(newerDisk))

        reader.resolve(
            request: 0,
            with: .loaded(coherentSnapshot(text: olderDisk, identity: identity))
        )
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(session.text, newerDisk)
        XCTAssertFalse(session.isDirty)
        XCTAssertNil(appState.pendingExternalTexts[key])
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertEqual(appState.lastKnownDiskHashes[key], AppState.contentHash(newerDisk))
        XCTAssertTrue(appState.canAutosave(session: session))
    }

    func testKeepMineSelectionSupersedesOlderInFlightDiskInspection() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("post.md")
        let original = "Original"
        let local = "Local dirty text"
        let olderDisk = "Older inspection X"
        let newerDisk = "Resolution Y"
        try original.write(to: documentURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let reader = ControlledCoherentFileReader()
        let session = DocumentSession(text: original, url: documentURL, fileKind: .markdown)
        let appState = AppState(
            currentDocument: session,
            coherentFileReader: reader,
            shouldRestoreLastOpenedFile: false
        )
        let key = try XCTUnwrap(appState.sessionStateURL(for: session))
        appState.sessionCache[key] = session
        appState.replaceDocumentText(local, in: session)
        appState.pendingExternalTexts[key] = olderDisk
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: key)

        appState.handleExternalChange(for: session)
        try await waitUntil("older Keep Mine inspection suspends") { reader.requestCount == 1 }
        appState.keepMineForExternallyChangedFile()
        try await waitUntil("Keep Mine starts a superseding read") { reader.requestCount == 2 }
        guard reader.requestCount == 2 else { return }
        XCTAssertNil(appState.externalDiskInspectionTasks[ObjectIdentifier(session)])

        let identity = try regularIdentity(at: documentURL)
        reader.resolve(
            request: 1,
            with: .loaded(coherentSnapshot(text: newerDisk, identity: identity))
        )
        try await waitUntil("Keep Mine Y completes") {
            appState.externalReloadTasks[ObjectIdentifier(session)] == nil &&
                appState.autosaveTask != nil
        }
        let autosave = try XCTUnwrap(appState.autosaveTask)
        XCTAssertEqual(appState.lastKnownDiskHashes[key], AppState.contentHash(newerDisk))

        reader.resolve(
            request: 0,
            with: .loaded(coherentSnapshot(text: olderDisk, identity: identity))
        )
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(session.text, local)
        XCTAssertTrue(session.isDirty)
        XCTAssertNil(appState.pendingExternalTexts[key])
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertEqual(appState.lastKnownDiskHashes[key], AppState.contentHash(newerDisk))
        XCTAssertNotNil(appState.autosaveTask)
        XCTAssertFalse(autosave.isCancelled)
        XCTAssertTrue(appState.canAutosave(session: session))
    }

    func testOneMiBReloadPreparationStaysOffMainAndMainActorApplyIsBounded() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("post.md")
        let local = "Local source"
        let oneMiBSource = String(repeating: "a", count: 1_048_576)
        XCTAssertEqual(oneMiBSource.utf8.count, 1_048_576)
        try local.write(to: documentURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let reader = ControlledCoherentFileReader()
        let preparationGate = ExternalReloadPreparationGate()
        let preparer = ProductionExternalReloadApplicationPreparer(
            willPrepare: { preparationGate.beginAndWait() },
            didPrepare: { preparationGate.finish() }
        )
        let session = DocumentSession(
            text: local,
            url: documentURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(
            currentDocument: session,
            coherentFileReader: reader,
            externalReloadApplicationPreparer: preparer,
            shouldRestoreLastOpenedFile: false
        )
        let key = documentURL.standardizedFileURL
        appState.sessionCache[key] = session
        appState.pendingExternalTexts[key] = oneMiBSource
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: key)
        appState.reloadExternallyChangedFile()
        try await waitUntil("1 MiB physical Reload read starts") { reader.requestCount == 1 }

        try reader.resolve(
            request: 0,
            with: .loaded(coherentSnapshot(
                text: oneMiBSource,
                identity: regularIdentity(at: documentURL)
            ))
        )
        try await waitUntil("off-main payload preparation reaches its gate") {
            preparationGate.hasBegun
        }
        var mainActorSentinelAdvanced = false
        Task { @MainActor in mainActorSentinelAdvanced = true }
        await Task.yield()
        XCTAssertTrue(mainActorSentinelAdvanced)
        XCTAssertEqual(session.text, local)
        XCTAssertNotNil(appState.externalReloadTasks[ObjectIdentifier(session)])

        preparationGate.release()
        try await waitUntil(
            "1 MiB Reload applies",
            timeoutNanoseconds: 5_000_000_000
        ) {
            session.text.utf8.count == 1_048_576 &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }
        let preparationFinishedAt = try XCTUnwrap(preparationGate.finishedUptimeNanoseconds)
        let observedApplyLatency = DispatchTime.now().uptimeNanoseconds - preparationFinishedAt
        XCTAssertLessThan(
            observedApplyLatency,
            50_000_000,
            "The bounded MainActor application stage should remain below 50 ms"
        )
        XCTAssertEqual(session.statistics, TextStatistics(text: oneMiBSource))
    }

    func testWatcherSupersessionCancelsSuspendedReloadPreparationBeforeStaleApply() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("post.md")
        let local = "Local source"
        let staleDisk = String(repeating: "x", count: 1_048_576)
        let newerDisk = "Disk source Y"
        try local.write(to: documentURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let reader = ControlledCoherentFileReader()
        let scanner = ControlledWorkspaceDirectoryScanner()
        let preparationGate = ExternalReloadPreparationGate()
        let preparer = ProductionExternalReloadApplicationPreparer(
            willPrepare: { preparationGate.beginAndWait() },
            didPrepare: { preparationGate.finish() }
        )
        let session = DocumentSession(
            text: local,
            url: documentURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(
            currentDocument: session,
            coherentFileReader: reader,
            externalReloadApplicationPreparer: preparer,
            directoryScanner: scanner,
            shouldRestoreLastOpenedFile: false
        )
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["post.md"],
            currentSession: session
        )
        let key = try XCTUnwrap(appState.sessionStateURL(for: session))
        appState.pendingExternalTexts[key] = staleDisk
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: key)
        appState.reloadExternallyChangedFile()
        try await waitUntil("stale Reload read starts") { reader.requestCount == 1 }
        let staleIdentity = try regularIdentity(at: documentURL)
        reader.resolve(
            request: 0,
            with: .loaded(coherentSnapshot(text: staleDisk, identity: staleIdentity))
        )
        try await waitUntil("stale payload preparation suspends") {
            preparationGate.hasBegun
        }

        try newerDisk.write(to: documentURL, atomically: true, encoding: .utf8)
        let newerIdentity = try regularIdentity(at: documentURL)
        appState.refreshWorkspaceAfterFileSystemChange()
        await scanner.waitForRequestCount(1)
        try await waitUntil("real watcher Y supersedes before its tree scan resumes") {
            reader.requestCount == 2
        }
        reader.resolve(
            request: 1,
            with: .loaded(coherentSnapshot(text: newerDisk, identity: newerIdentity))
        )
        try await waitUntil("newer payload applies while stale work remains suspended") {
            session.text == newerDisk &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }

        preparationGate.release()
        try await Task.sleep(nanoseconds: 50_000_000)
        await scanner.completeRequest(
            at: 0,
            with: snapshot(paths: ["post.md"], rootURL: rootURL)
        )
        await appState.workspaceReloadTask?.value
        XCTAssertEqual(session.text, newerDisk)
        XCTAssertEqual(preparationGate.successfulPreparationCount, 1)
        XCTAssertNil(appState.pendingExternalReloadApplications[ObjectIdentifier(session)])
    }

    func testNativeTypingIsRejectedBeforeMutationWhilePhysicalReloadReadIsSuspended() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("post.md")
        let local = "Local source"
        let disk = "Coherent disk source"
        try local.write(to: documentURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let reader = ControlledCoherentFileReader()
        let session = DocumentSession(
            text: local,
            url: documentURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(
            currentDocument: session,
            coherentFileReader: reader,
            shouldRestoreLastOpenedFile: false
        )
        let key = documentURL.standardizedFileURL
        appState.sessionCache[key] = session
        let binding = appState.editorDocumentBinding(for: session)
        var selection: NSRange? = NSRange(location: (local as NSString).length, length: 0)
        let view = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: key),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let fixture = try makeEditorBridgeFixture(representable: view, source: local)
        defer {
            fixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
        }

        appState.pendingExternalTexts[key] = disk
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: key)
        let previousVersion = session.version
        let previousDirtyState = session.isDirty
        let previousDiskSource = try String(contentsOf: documentURL, encoding: .utf8)
        let previousWriter = appState.editorWriterInstallations[ObjectIdentifier(session)]
        appState.reloadExternallyChangedFile()
        try await waitUntil("physical Reload read suspends") { reader.requestCount == 1 }

        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.textSelection = selection ?? .notFound
        fixture.textView.insertText("!", replacementRange: .notFound)

        XCTAssertEqual(fixture.textView.text, local)
        XCTAssertEqual(session.text, local)
        XCTAssertEqual(session.version, previousVersion)
        XCTAssertEqual(session.isDirty, previousDirtyState)
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), previousDiskSource)
        XCTAssertNotNil(appState.externalReloadTasks[ObjectIdentifier(session)])
        XCTAssertEqual(appState.editorWriterInstallations[ObjectIdentifier(session)], previousWriter)

        try reader.resolve(
            request: 0,
            with: .loaded(coherentSnapshot(text: disk, identity: regularIdentity(at: documentURL)))
        )
        try await waitUntil("Reload applies after the read resumes") {
            session.text == disk && fixture.textView.text == disk &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }
    }

    // swiftlint:disable:next function_body_length
    func testWatcherYSupersedesReloadXDuringPartialCoordinatorConvergence() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("post.md")
        let local = "Local source"
        let disk = "Disk source X"
        let newerDisk = "Disk source Y"
        try local.write(to: documentURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let reader = ControlledCoherentFileReader()
        let session = DocumentSession(
            text: local,
            url: documentURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(
            currentDocument: session,
            coherentFileReader: reader,
            shouldRestoreLastOpenedFile: false
        )
        let key = documentURL.standardizedFileURL
        appState.sessionCache[key] = session
        let binding = appState.editorDocumentBinding(for: session)
        var selection1: NSRange? = NSRange(location: (local as NSString).length, length: 0)
        var selection2 = selection1
        let view1 = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: Binding(get: { selection1 }, set: { selection1 = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: key),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let view2 = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: Binding(get: { selection2 }, set: { selection2 = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: key),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let installationsBeforeFixture1 = Set(appState.editorBindingInstallations.keys)
        let fixture1 = try makeEditorBridgeFixture(representable: view1, source: local)
        let installation1 = try XCTUnwrap(
            Set(appState.editorBindingInstallations.keys)
                .subtracting(installationsBeforeFixture1)
                .first
        )
        let fixture2 = try makeEditorBridgeFixture(representable: view2, source: local, makeKey: false)
        let installation2 = try XCTUnwrap(
            Set(appState.editorBindingInstallations.keys).subtracting([installation1]).first
        )
        defer {
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
            fixture1.window.orderOut(nil)
            fixture2.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture1.scrollView, coordinator: fixture1.coordinator)
            MarkdownTextView.dismantleNSView(fixture2.scrollView, coordinator: fixture2.coordinator)
        }
        let secondSynchronizer = try XCTUnwrap(
            appState.editorDocumentSourceSynchronizers[installation2]
        )
        appState.editorDocumentSourceSynchronizers[installation2] = { _ in false }

        appState.pendingExternalTexts[key] = disk
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: key)
        appState.reloadExternallyChangedFile()
        try await waitUntil("two-coordinator Reload read suspends") { reader.requestCount == 1 }
        try reader.resolve(
            request: 0,
            with: .loaded(coherentSnapshot(text: disk, identity: regularIdentity(at: documentURL)))
        )
        try await waitUntil("only the first coordinator converges") {
            session.text == disk && fixture1.textView.text == disk && fixture2.textView.text == local &&
                appState.pendingExternalReloadApplications[ObjectIdentifier(session)] != nil
        }
        XCTAssertFalse(appState.canAutosave(session: session))
        XCTAssertNil(appState.sessionAutosaveTasks[ObjectIdentifier(session)])
        XCTAssertThrowsError(try appState.save(session: session)) { error in
            guard case let AppStateError.unresolvedExternalChange(url) = error else {
                return XCTFail("Expected unresolved external change")
            }
            XCTAssertEqual(url, documentURL.standardizedFileURL)
        }
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), local)

        XCTAssertTrue(fixture1.window.makeFirstResponder(fixture1.textView))
        fixture1.textView.textSelection = NSRange(location: (disk as NSString).length, length: 0)
        fixture1.textView.insertText("!", replacementRange: .notFound)
        XCTAssertEqual(fixture1.textView.text, disk)
        XCTAssertEqual(session.text, disk)
        XCTAssertNotNil(appState.externalReloadTasks[ObjectIdentifier(session)])

        appState.handleExternalChange(for: session)
        try await waitUntil("watcher Y starts a new read during partial X convergence") {
            reader.requestCount == 2
        }
        XCTAssertEqual(session.text, disk)
        XCTAssertEqual(fixture1.textView.text, disk)
        XCTAssertEqual(fixture2.textView.text, local)
        XCTAssertNotNil(appState.externalReloadTasks[ObjectIdentifier(session)])

        try reader.resolve(
            request: 1,
            with: .loaded(coherentSnapshot(
                text: newerDisk,
                identity: regularIdentity(at: documentURL)
            ))
        )
        try await waitUntil("Y replaces X but remains fenced on the second coordinator") {
            session.text == newerDisk &&
                fixture1.textView.text == newerDisk &&
                fixture2.textView.text == local &&
                appState.pendingExternalReloadApplications[ObjectIdentifier(session)] != nil
        }
        XCTAssertFalse(appState.canAutosave(session: session))
        XCTAssertNil(appState.sessionAutosaveTasks[ObjectIdentifier(session)])
        XCTAssertThrowsError(try appState.save(session: session))
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), local)

        appState.editorDocumentSourceSynchronizers[installation2] = secondSynchronizer
        appState.synchronizePendingExternalReloadIfPossible(for: session)
        try await waitUntil("second coordinator converges to Y and releases the fence") {
            fixture2.textView.text == newerDisk &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }
        fixture1.textView.textSelection = NSRange(
            location: (newerDisk as NSString).length,
            length: 0
        )
        fixture1.textView.insertText("!", replacementRange: .notFound)
        XCTAssertEqual(session.text, newerDisk + "!")
    }

    // swiftlint:disable:next function_body_length
    func testKeepMineKeepsSaveAndAutosaveFencedUntilEveryCoordinatorConverges() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("post.md")
        let local = "Local source"
        let external = "External source"
        try external.write(to: documentURL, atomically: true, encoding: .utf8)
        let defaultsSuiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.set(30.0, forKey: "Plainsong.settings.autosaveIntervalSeconds")
        let reader = ControlledCoherentFileReader()
        let session = DocumentSession(
            text: local,
            url: documentURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(
            currentDocument: session,
            coherentFileReader: reader,
            shouldRestoreLastOpenedFile: false,
            userDefaults: defaults
        )
        let key = try XCTUnwrap(appState.sessionStateURL(for: session))
        appState.sessionCache[key] = session
        let binding = appState.editorDocumentBinding(for: session)
        var selection1: NSRange? = NSRange(location: (local as NSString).length, length: 0)
        var selection2 = selection1
        let view1 = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: Binding(get: { selection1 }, set: { selection1 = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: key),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let view2 = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: Binding(get: { selection2 }, set: { selection2 = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: key),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let installationsBeforeFixture1 = Set(appState.editorBindingInstallations.keys)
        let fixture1 = try makeEditorBridgeFixture(representable: view1, source: local)
        let installation1 = try XCTUnwrap(
            Set(appState.editorBindingInstallations.keys)
                .subtracting(installationsBeforeFixture1)
                .first
        )
        let fixture2 = try makeEditorBridgeFixture(representable: view2, source: local, makeKey: false)
        let installation2 = try XCTUnwrap(
            Set(appState.editorBindingInstallations.keys).subtracting([installation1]).first
        )
        defer {
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
            fixture1.window.orderOut(nil)
            fixture2.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture1.scrollView, coordinator: fixture1.coordinator)
            MarkdownTextView.dismantleNSView(fixture2.scrollView, coordinator: fixture2.coordinator)
            for task in appState.sessionAutosaveTasks.values {
                task.task.cancel()
            }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: rootURL)
        }
        let secondSynchronizer = try XCTUnwrap(
            appState.editorDocumentSourceSynchronizers[installation2]
        )
        appState.editorDocumentSourceSynchronizers[installation2] = { _ in false }

        appState.pendingExternalTexts[key] = external
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: key)
        appState.keepMineForExternallyChangedFile()
        try await waitUntil("Keep Mine read starts") { reader.requestCount == 1 }
        try reader.resolve(
            request: 0,
            with: .loaded(coherentSnapshot(
                text: external,
                identity: regularIdentity(at: documentURL)
            ))
        )
        try await waitUntil("Keep Mine remains partially converged") {
            appState.pendingExternalReloadApplications[ObjectIdentifier(session)]?
                .synchronizedInstallations == Set([installation1])
        }

        XCTAssertEqual(session.text, local)
        XCTAssertTrue(session.isDirty)
        XCTAssertFalse(appState.canAutosave(session: session))
        XCTAssertNil(appState.sessionAutosaveTasks[ObjectIdentifier(session)])
        XCTAssertThrowsError(try appState.save(session: session)) { error in
            guard case AppStateError.unresolvedExternalChange = error else {
                return XCTFail("Expected unresolved external change")
            }
        }
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), external)

        appState.editorDocumentSourceSynchronizers[installation2] = secondSynchronizer
        appState.synchronizePendingExternalReloadIfPossible(for: session)
        try await waitUntil("Keep Mine releases the fence after every coordinator converges") {
            appState.pendingExternalReloadApplications[ObjectIdentifier(session)] == nil &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }
        XCTAssertTrue(appState.canAutosave(session: session))
        XCTAssertNotNil(appState.autosaveTask)
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), external)
    }

    func testWatcherDetectsSameInodeSameSizeContentWithRestoredModificationTime() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("post.md")
        let original = "AAAA"
        let replacement = "BBBB"
        try original.write(to: documentURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let originalIdentity = try regularIdentity(at: documentURL)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: documentURL.path)
        let originalModificationDate = try XCTUnwrap(originalAttributes[.modificationDate] as? Date)
        let session = DocumentSession(text: original, url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        let key = documentURL.standardizedFileURL
        appState.sessionCache[key] = session
        appState.recordKnownDiskText(original, for: key, modificationDate: originalModificationDate)

        let handle = try FileHandle(forWritingTo: documentURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(replacement.utf8))
        try handle.synchronize()
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: originalModificationDate],
            ofItemAtPath: documentURL.path
        )
        XCTAssertEqual(try regularIdentity(at: documentURL), originalIdentity)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: documentURL.path)[.size] as? Int,
            original.utf8.count
        )

        appState.handleExternalChange(for: session)
        try await waitUntil("coherent watcher read detects restored-mtime content") {
            session.text == replacement &&
                appState.externalDiskInspectionTasks[ObjectIdentifier(session)] == nil
        }
        XCTAssertEqual(session.text, replacement)
        XCTAssertFalse(session.isDirty)
    }

    func testOwnedTreeAndEditorIdentityStayStableAfterPathComponentBecomesSymlink() async throws {
        let rootURL = try makeTemporaryDirectory()
        let directoryURL = rootURL.appendingPathComponent("notes", isDirectory: true)
        let movedDirectoryURL = rootURL.appendingPathComponent("notes-moved", isDirectory: true)
        let outsideURL = try makeTemporaryDirectory()
        let documentURL = directoryURL.appendingPathComponent("post.md")
        let outsideDocumentURL = outsideURL.appendingPathComponent("post.md")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try "Owned source".write(to: documentURL, atomically: true, encoding: .utf8)
        try "Untrusted source".write(to: outsideDocumentURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }

        let session = DocumentSession(
            text: "Owned source",
            url: documentURL,
            fileKind: .markdown
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["notes/post.md"],
            currentSession: session
        )
        appState.recordKnownDiskText("Owned source", for: documentURL)
        let ownership = try XCTUnwrap(appState.anchoredSessionFileBinding(for: session))
        let editorIdentity = appState.activeEditorDocumentIdentity
        let selectedNodeID = appState.workspaceTree?.selectedNodeID

        try FileManager.default.moveItem(at: directoryURL, to: movedDirectoryURL)
        try FileManager.default.createSymbolicLink(at: directoryURL, withDestinationURL: outsideURL)
        appState.synchronizeWorkspaceTreeSelection(for: session)

        XCTAssertEqual(appState.anchoredSessionFileBinding(for: session), ownership)
        XCTAssertEqual(appState.activeEditorDocumentIdentity, editorIdentity)
        XCTAssertEqual(appState.workspaceTree?.selectedNodeID, selectedNodeID)
        XCTAssertEqual(ownership.location.relativePath, "notes/post.md")

        appState.handleExternalChange(for: session)
        try await waitUntil("anchored watcher refuses replaced path component") {
            appState.missingFilePrompt?.fileURL == ownership.location.fileURL
        }
        XCTAssertEqual(session.text, "Owned source")
        XCTAssertNotEqual(session.text, "Untrusted source")
    }

    func testSelectionOnlyClosingDelimiterKeepsAppSourceVersionDirtyDiskAndAutosaveUnchanged() throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("post.md")
        let source = "()"
        try source.write(to: documentURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let session = DocumentSession(text: source, url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        let key = documentURL.standardizedFileURL
        appState.sessionCache[key] = session
        appState.recordKnownDiskText(source, for: key)
        let binding = appState.editorDocumentBinding(for: session)
        var selection: NSRange? = NSRange(location: 1, length: 0)
        let view = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: key),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let fixture = try makeEditorBridgeFixture(representable: view, source: source)
        defer {
            fixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
        }
        let version = session.version
        let isDirty = session.isDirty
        let diskHash = appState.lastKnownDiskHashes[key]
        let autosaveWasScheduled = appState.autosaveTask != nil

        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.textSelection = selection ?? .notFound
        fixture.textView.insertText(")", replacementRange: .notFound)

        XCTAssertEqual(fixture.textView.text, source)
        XCTAssertEqual(fixture.textView.textSelection, NSRange(location: 2, length: 0))
        XCTAssertEqual(session.text, source)
        XCTAssertEqual(session.version, version)
        XCTAssertEqual(session.isDirty, isDirty)
        XCTAssertEqual(appState.lastKnownDiskHashes[key], diskHash)
        XCTAssertEqual(appState.autosaveTask != nil, autosaveWasScheduled)
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), source)
    }

    // swiftlint:disable:next function_body_length
    func testDelayedReloadSurvivesRetirementAndReactivationButOnlyLatestLifecycleMayApply() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentAURL = rootURL.appendingPathComponent("a.md")
        let documentBURL = rootURL.appendingPathComponent("b.md")
        let sourceA = "A local source"
        let sourceB = "B source"
        let diskA = "A coherent disk source"
        try sourceA.write(to: documentAURL, atomically: true, encoding: .utf8)
        try sourceB.write(to: documentBURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let reader = ControlledCoherentFileReader()
        let sessionA = DocumentSession(
            text: sourceA,
            url: documentAURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(
            currentDocument: sessionA,
            coherentFileReader: reader,
            shouldRestoreLastOpenedFile: false
        )
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["a.md", "b.md"],
            currentSession: sessionA,
            retainSecurityScope: true
        )
        let bindingA = appState.editorDocumentBinding(for: sessionA)
        let installationA = EditorDocumentBindingInstallation(
            bindingID: bindingA.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        bindingA.onLifecycle(.installed(installationA))
        let canonicalA = documentAURL.standardizedFileURL
        appState.pendingExternalTexts[canonicalA] = "detected A conflict"
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: canonicalA)

        appState.reloadExternallyChangedFile()
        try await waitUntil("active lifecycle Reload starts") { reader.requestCount == 1 }
        let saveCopyURL = rootURL.appendingPathComponent("save-copy-during-reload.md")
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: canonicalA)
        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: saveCopyURL)) { error in
            guard case AppStateError.unresolvedExternalChange = error else {
                return XCTFail("Expected the suspended Reload to fence Save Copy")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: saveCopyURL.path))
        XCTAssertNotNil(appState.externalReloadTasks[ObjectIdentifier(sessionA)])
        appState.missingFilePrompt = nil
        try appState.open(url: documentBURL, rememberAsLastOpened: false, preserveWorkspace: false)
        try await waitUntil("retired lifecycle restarts Reload") { reader.requestCount == 2 }
        try appState.open(url: documentAURL, rememberAsLastOpened: false, preserveWorkspace: false)
        try await waitUntil("reactivated lifecycle restarts Reload") { reader.requestCount == 3 }

        let identity = try regularIdentity(at: documentAURL)
        let snapshot = coherentSnapshot(text: diskA, identity: identity)
        reader.resolve(request: 0, with: .loaded(snapshot))
        reader.resolve(request: 1, with: .loaded(snapshot))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(sessionA.text, sourceA)
        XCTAssertEqual(appState.pendingExternalTexts[canonicalA], "detected A conflict")

        reader.resolve(request: 2, with: .loaded(snapshot))
        try await waitUntil("latest lifecycle applies but waits for exact installation") {
            sessionA.text == diskA &&
                appState.pendingExternalReloadApplications[ObjectIdentifier(sessionA)] != nil
        }
        XCTAssertFalse(appState.canSave)
        bindingA.onLifecycle(.revoked(installationA))
        try await waitUntil("revocation completes lifecycle-fenced Reload") {
            appState.externalReloadTasks[ObjectIdentifier(sessionA)] == nil
        }
        XCTAssertNil(appState.pendingExternalTexts[canonicalA])
        XCTAssertNil(appState.deferredExternalChangeResolutions[canonicalA])
    }

    func testPartiallyConvergedReloadRestartsAcrossRetirementAndReactivation() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("a.md")
        let local = "A local source"
        let disk = "A accepted disk source"
        try local.write(to: documentURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let reader = ControlledCoherentFileReader()
        let session = DocumentSession(
            text: local,
            url: documentURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(
            currentDocument: session,
            coherentFileReader: reader,
            shouldRestoreLastOpenedFile: false
        )
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["a.md"],
            currentSession: session,
            retainSecurityScope: true
        )
        let key = try XCTUnwrap(appState.sessionStateURL(for: session))
        let binding = appState.editorDocumentBinding(for: session)
        let installation1 = EditorDocumentBindingInstallation(
            bindingID: binding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        let installation2 = EditorDocumentBindingInstallation(
            bindingID: binding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation1))
        binding.onLifecycle(.installed(installation2))
        let sourceContract = try XCTUnwrap(binding.sourceContract)
        sourceContract.registerSourceSynchronizer(installation1) { _ in true }
        sourceContract.registerSourceSynchronizer(installation2) { _ in false }
        appState.pendingExternalTexts[key] = disk
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: key)

        appState.reloadExternallyChangedFile()
        try await waitUntil("initial partial-convergence Reload starts") {
            reader.requestCount == 1
        }
        let snapshot = try coherentSnapshot(
            text: disk,
            identity: regularIdentity(at: documentURL)
        )
        reader.resolve(request: 0, with: .loaded(snapshot))
        try await waitUntil("only one exact installation accepts X") {
            session.text == disk &&
                appState.pendingExternalReloadApplications[ObjectIdentifier(session)]?
                .synchronizedInstallations == Set([installation1])
        }

        try appState.closeWorkspaceForReplacement()
        try await waitUntil("retirement recaptures accepted X in a new lifecycle") {
            reader.requestCount == 2
        }
        try appState.activateFileSession(url: documentURL)
        try await waitUntil("reactivation supersedes the retired lifecycle read") {
            reader.requestCount == 3
        }
        reader.resolve(request: 1, with: .loaded(snapshot))
        reader.resolve(request: 2, with: .loaded(snapshot))
        try await waitUntil("latest lifecycle remains fenced on installation two") {
            session.text == disk &&
                appState.pendingExternalReloadApplications[ObjectIdentifier(session)] != nil &&
                appState.deferredExternalChangeResolutions[key] == .reload
        }

        sourceContract.registerSourceSynchronizer(installation2) { _ in true }
        appState.synchronizePendingExternalReloadIfPossible(for: session)
        try await waitUntil("both exact installations converge in the latest lifecycle") {
            appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }

        XCTAssertEqual(session.text, disk)
        XCTAssertFalse(session.isDirty)
        XCTAssertNil(appState.pendingExternalReloadApplications[ObjectIdentifier(session)])
        XCTAssertNil(appState.pendingExternalTexts[key])
        XCTAssertNil(appState.deferredExternalChangeResolutions[key])
        XCTAssertNil(appState.externalChangePrompt)
        binding.onLifecycle(.revoked(installation1))
        binding.onLifecycle(.revoked(installation2))
    }

    func testInvalidUTF8ReloadResultPreservesLocalSourceInDetachedRecovery() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("post.md")
        let local = "Recoverable local source"
        try local.write(to: documentURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let reader = ControlledCoherentFileReader()
        let session = DocumentSession(
            text: local,
            url: documentURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(
            currentDocument: session,
            coherentFileReader: reader,
            shouldRestoreLastOpenedFile: false
        )
        let key = documentURL.standardizedFileURL
        appState.sessionCache[key] = session
        appState.pendingExternalTexts[key] = "unreadable replacement"
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: key)

        appState.reloadExternallyChangedFile()
        try await waitUntil("invalid UTF-8 Reload starts") { reader.requestCount == 1 }
        reader.resolve(request: 0, with: .invalidUTF8)
        try await waitUntil("invalid UTF-8 enters recovery") {
            appState.detachedSessionURLs.contains(key)
        }

        XCTAssertEqual(session.text, local)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(appState.missingFilePrompt?.fileURL, key)
        XCTAssertFalse(appState.canSave)
    }

    func testDeferredReloadNeverFollowsInWorkspaceOrEscapingSymlinkSubstitution() async throws {
        for race in [SaveCopySymlinkRace.leaf, .intermediate] {
            try await assertDeferredSymlinkSubstitutionDoesNotFollow(
                intent: .reload,
                race: race,
                targetOutsideWorkspace: false
            )
            try await assertDeferredSymlinkSubstitutionDoesNotFollow(
                intent: .reload,
                race: race,
                targetOutsideWorkspace: true
            )
        }
    }

    func testDeferredKeepMineNeverFollowsInWorkspaceOrEscapingSymlinkSubstitution() async throws {
        for race in [SaveCopySymlinkRace.leaf, .intermediate] {
            try await assertDeferredSymlinkSubstitutionDoesNotFollow(
                intent: .keepMine,
                race: race,
                targetOutsideWorkspace: false
            )
            try await assertDeferredSymlinkSubstitutionDoesNotFollow(
                intent: .keepMine,
                race: race,
                targetOutsideWorkspace: true
            )
        }
    }

    func testReloadSynchronizesEveryLiveMirrorBeforeOneWriterAcceptsImmediateInput() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("post.md")
        let diskX = "Disk X"
        let local = "Local discarded source"
        let diskY = "Disk Y"
        try diskX.write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(
            text: local,
            url: documentURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        let key = documentURL.standardizedFileURL
        appState.sessionCache[key] = session
        appState.recordKnownDiskText(diskX, for: key)
        let binding = appState.editorDocumentBinding(for: session)
        var selection1: NSRange? = NSRange(location: (local as NSString).length, length: 0)
        var selection2 = selection1
        let view1 = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: Binding(get: { selection1 }, set: { selection1 = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: key),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let view2 = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: Binding(get: { selection2 }, set: { selection2 = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: key),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let fixture1 = try makeEditorBridgeFixture(representable: view1, source: local)
        let fixture2 = try makeEditorBridgeFixture(
            representable: view2,
            source: local,
            makeKey: false
        )
        defer {
            fixture1.window.orderOut(nil)
            fixture2.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture1.scrollView, coordinator: fixture1.coordinator)
            MarkdownTextView.dismantleNSView(fixture2.scrollView, coordinator: fixture2.coordinator)
            try? FileManager.default.removeItem(at: rootURL)
        }

        try diskY.write(to: key, atomically: true, encoding: .utf8)
        appState.pendingExternalTexts[key] = diskY
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: key)
        appState.reloadExternallyChangedFile()
        try await waitUntil("Reload synchronizes every live mirror") {
            session.text == diskY &&
                fixture1.textView.text == diskY &&
                fixture2.textView.text == diskY &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }

        let installedSnapshot = EditorDocumentSourceSnapshot(
            source: diskY,
            revision: session.version
        )
        XCTAssertEqual(fixture1.coordinator.currentInstalledSourceSnapshot, installedSnapshot)
        XCTAssertEqual(fixture2.coordinator.currentInstalledSourceSnapshot, installedSnapshot)
        XCTAssertNil(appState.editorWriterInstallations[ObjectIdentifier(session)])

        XCTAssertTrue(fixture1.window.makeFirstResponder(fixture1.textView))
        fixture1.textView.textSelection = NSRange(location: (diskY as NSString).length, length: 0)
        fixture1.textView.insertText("!", replacementRange: .notFound)
        XCTAssertEqual(session.text, diskY + "!")
        XCTAssertEqual(fixture1.textView.text, diskY + "!")

        fixture2.textView.textSelection = NSRange(location: (diskY as NSString).length, length: 0)
        fixture2.textView.insertText("?", replacementRange: .notFound)
        XCTAssertEqual(session.text, diskY + "!")
        XCTAssertEqual(fixture2.textView.text, diskY + "!")
    }

    func testAsyncUnretirableExternalConflictBlocksWorkspaceCloseWithoutDiscardingSession() async throws {
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
        let stateURL = try XCTUnwrap(appState.sessionStateURL(for: session))
        defer {
            appState.clearExternalChangeConflict(at: stateURL)
            appState.externalChangePrompt = nil
            appState.closeWorkspace()
            try? FileManager.default.removeItem(at: rootURL)
        }
        appState.replaceDocumentText("Local dirty text", in: session)
        try "External disk text".write(to: documentURL, atomically: true, encoding: .utf8)
        appState.lastKnownDiskModificationDates[stateURL] = .distantPast
        appState.handleExternalChange(for: session)

        appState.removeEditorDocumentBindingRegistration(for: session)
        appState.editorBindingInstallations.removeAll()
        appState.closeWorkspace()

        XCTAssertEqual(appState.workspaceRootURL?.standardizedFileURL, rootURL.standardizedFileURL)
        XCTAssertTrue(appState.currentDocument === session)
        XCTAssertTrue(appState.sessionCache[stateURL] === session)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.text, "Local dirty text")
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), "External disk text")
        XCTAssertNotNil(appState.presentedError)
        try await waitUntil("blocked close retains the detected external source") {
            appState.pendingExternalTexts[stateURL] != nil
        }
    }

    func testCleanQuarantineIsProtectedFromLRUEviction() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let quarantinedURL = root.appendingPathComponent("quarantined.md").standardizedFileURL
        let otherURL = root.appendingPathComponent("other.md").standardizedFileURL
        let location = try WorkspaceFileSystemLocation(fileURL: quarantinedURL)
        let quarantinedSession = DocumentSession(
            text: "clean quarantined bytes",
            url: quarantinedURL,
            fileKind: .markdown,
            isDirty: false
        )
        let otherSession = DocumentSession(
            text: "other",
            url: otherURL,
            fileKind: .markdown,
            isDirty: false
        )
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        let quarantinedIdentity = ObjectIdentifier(quarantinedSession)
        appState.sessionCache[quarantinedURL] = quarantinedSession
        appState.indeterminateSessionWrites[quarantinedIdentity] = WorkspaceIndeterminateFileWrite(
            reason: .durabilityFailed,
            preparedMetadata: nil,
            recoveryArtifact: .none
        )
        appState.indeterminateSessionWriteContexts[quarantinedIdentity] =
            IndeterminateSessionWriteContext(
                location: location,
                preparedSHA256Digest: WorkspaceSearchContentFingerprint(
                    text: quarantinedSession.text
                ).sha256Digest
            )
        appState.sessionPolicy = WorkspaceSessionLRUPolicy(limit: 1)
        _ = appState.sessionPolicy.access(quarantinedURL, isDirty: false)
        appState.sessionCache[otherURL] = otherSession

        appState.handleSessionAccess(url: otherURL, isDirty: false)

        XCTAssertTrue(appState.sessionCache[quarantinedURL] === quarantinedSession)
        XCTAssertNotNil(appState.indeterminateSessionWrites[quarantinedIdentity])
        XCTAssertEqual(
            appState.indeterminateSessionWriteContexts[quarantinedIdentity]?.location,
            location
        )
    }

    func testCleanQuarantineSurvivesEditorRetirementAndMetadataCleanup() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let quarantinedURL = root.appendingPathComponent("quarantined.md").standardizedFileURL
        let location = try WorkspaceFileSystemLocation(fileURL: quarantinedURL)
        let session = DocumentSession(
            text: "clean quarantined bytes",
            url: quarantinedURL,
            fileKind: .markdown,
            isDirty: false
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        let sessionIdentity = ObjectIdentifier(session)
        appState.sessionCache[quarantinedURL] = session
        appState.indeterminateSessionWrites[sessionIdentity] = WorkspaceIndeterminateFileWrite(
            reason: .durabilityFailed,
            preparedMetadata: nil,
            recoveryArtifact: .none
        )
        appState.indeterminateSessionWriteContexts[sessionIdentity] = IndeterminateSessionWriteContext(
            location: location,
            preparedSHA256Digest: WorkspaceSearchContentFingerprint(text: session.text).sha256Digest
        )
        let binding = appState.editorDocumentBinding(for: session)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        appState.beginEditorDocumentSessionRetirement(
            canonicalURL: quarantinedURL,
            session: session,
            installations: [installation],
            securityScopedAuthorityOwner: nil
        )
        appState.currentDocument = DocumentSession()
        appState.sessionCache[quarantinedURL] = nil

        binding.onLifecycle(.revoked(installation))

        XCTAssertTrue(appState.retiredEditorDocumentSessions[quarantinedURL]?.session === session)
        XCTAssertNotNil(appState.indeterminateSessionWrites[sessionIdentity])
        XCTAssertEqual(
            appState.indeterminateSessionWriteContexts[sessionIdentity]?.location,
            location
        )
    }

    // swiftlint:disable:next function_body_length
    func testCleanQuarantineBlocksWorkspaceCloseAndSwitchWithoutDiscardingContext() throws {
        func makeQuarantinedWorkspace() throws -> (
            appState: AppState,
            root: URL,
            session: DocumentSession,
            location: WorkspaceFileSystemLocation
        ) {
            let root = try makeTemporaryDirectory()
            let quarantinedURL = root.appendingPathComponent("quarantined.md").standardizedFileURL
            let location = try WorkspaceFileSystemRootAuthority(rootURL: root)
                .location(relativePath: "quarantined.md")
            let session = DocumentSession(
                text: "clean quarantined bytes",
                url: quarantinedURL,
                fileKind: .markdown,
                isDirty: false
            )
            let appState = AppState(shouldRestoreLastOpenedFile: false)
            let sessionIdentity = ObjectIdentifier(session)
            appState.workspaceRootURL = root
            appState.workspaceSearchRootAuthority = location.rootAuthority
            appState.workspaceGeneration = 1
            appState.workspaceInstalledCaptureGeneration = 1
            appState.sessionCache[quarantinedURL] = session
            appState.indeterminateSessionWrites[sessionIdentity] = WorkspaceIndeterminateFileWrite(
                reason: .durabilityFailed,
                preparedMetadata: nil,
                recoveryArtifact: .none
            )
            appState.indeterminateSessionWriteContexts[sessionIdentity] =
                IndeterminateSessionWriteContext(
                    location: location,
                    preparedSHA256Digest: WorkspaceSearchContentFingerprint(
                        text: session.text
                    ).sha256Digest
                )
            return (appState, root, session, location)
        }

        let closeFixture = try makeQuarantinedWorkspace()
        defer { try? FileManager.default.removeItem(at: closeFixture.root) }
        XCTAssertThrowsError(try closeFixture.appState.closeWorkspaceForReplacement())
        XCTAssertEqual(closeFixture.appState.workspaceRootURL, closeFixture.root)
        XCTAssertTrue(
            closeFixture.appState.sessionCache[closeFixture.location.fileURL]
                === closeFixture.session
        )
        XCTAssertEqual(
            closeFixture.appState.indeterminateSessionWriteContexts[
                ObjectIdentifier(closeFixture.session)
            ]?.location,
            closeFixture.location
        )

        let switchFixture = try makeQuarantinedWorkspace()
        defer { try? FileManager.default.removeItem(at: switchFixture.root) }
        let replacementRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: replacementRoot) }
        XCTAssertThrowsError(
            try switchFixture.appState.open(
                url: replacementRoot,
                rememberAsLastOpened: false,
                preserveWorkspace: false
            )
        )
        XCTAssertEqual(switchFixture.appState.workspaceRootURL, switchFixture.root)
        XCTAssertTrue(
            switchFixture.appState.sessionCache[switchFixture.location.fileURL]
                === switchFixture.session
        )
        XCTAssertEqual(
            switchFixture.appState.indeterminateSessionWriteContexts[
                ObjectIdentifier(switchFixture.session)
            ]?.location,
            switchFixture.location
        )
    }

    func testUnretirableExternalConflictBlocksWorkspaceCloseWithoutDiscardingSession() async throws {
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
        let canonicalURL = try XCTUnwrap(appState.sessionStateURL(for: session))
        defer {
            appState.pendingExternalTexts[canonicalURL] = nil
            appState.externalChangePrompt = nil
            appState.closeWorkspace()
            try? FileManager.default.removeItem(at: rootURL)
        }
        appState.replaceDocumentText("Local dirty text", in: session)
        try "External disk text".write(to: documentURL, atomically: true, encoding: .utf8)
        appState.lastKnownDiskModificationDates[canonicalURL] = .distantPast
        appState.handleExternalChange(for: session)

        appState.removeEditorDocumentBindingRegistration(for: session)
        appState.editorBindingInstallations.removeAll()
        appState.closeWorkspace()

        XCTAssertEqual(appState.workspaceRootURL?.standardizedFileURL, rootURL.standardizedFileURL)
        XCTAssertTrue(appState.currentDocument === session)
        XCTAssertTrue(appState.sessionCache[canonicalURL] === session)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.text, "Local dirty text")
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), "External disk text")
        XCTAssertNotNil(appState.presentedError)
        try await waitUntil("blocked close retains the detected external source") {
            appState.pendingExternalTexts[canonicalURL] != nil
        }
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
        XCTAssertTrue(appState.retiredEditorDocumentSessions.isEmpty)
    }

    func testRetiredInstalledConflictStaysRecoverableAfterRevocationUntilReload() async throws {
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
        let authority = try XCTUnwrap(appState.workspaceSearchRootAuthority)
        let location = try authority.location(relativePath: "post.md")
        let loaded = try MarkdownFileStore().loadResult(at: location)
        appState.anchoredSessionFileBindings[ObjectIdentifier(session)] =
            AnchoredWorkspaceSessionFileBinding(
                location: location,
                identity: loaded.metadata.identity,
                sha256Digest: loaded.sha256Digest
            )
        defer {
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
            try? FileManager.default.removeItem(at: rootURL)
        }
        let binding = appState.editorDocumentBinding(for: session)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        let canonicalURL = try XCTUnwrap(appState.sessionStateURL(for: session))
        appState.replaceDocumentText(local, in: session)
        try external.write(to: documentURL, atomically: true, encoding: .utf8)
        appState.lastKnownDiskModificationDates[canonicalURL] = .distantPast
        appState.handleExternalChange(for: session)

        try appState.closeWorkspaceForReplacement()
        binding.onLifecycle(.revoked(installation))

        try await waitUntil("retired session records its external conflict") {
            appState.pendingExternalTexts[canonicalURL] == external &&
                appState.externalChangePrompt?.fileURL == canonicalURL &&
                appState.externalDiskInspectionTasks[ObjectIdentifier(session)] == nil
        }
        let retirement = try XCTUnwrap(appState.retiredEditorDocumentSessions[canonicalURL])
        XCTAssertTrue(retirement.awaitingInstallations.isEmpty)
        XCTAssertTrue(retirement.session === session)
        XCTAssertEqual(
            retirement.securityScopedAuthorityOwners.first?.authority.url.standardizedFileURL,
            rootURL.standardizedFileURL
        )
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.text, local)
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), external)
        XCTAssertNil(appState.editorDocumentBindingIDs[ObjectIdentifier(session)])
        XCTAssertNil(appState.editorDocumentBindingSessions[binding.id])

        XCTAssertEqual(
            appState.externalChangePrompt?.fileURL.standardizedFileURL,
            documentURL.standardizedFileURL
        )
        appState.reloadExternallyChangedFile()

        try await waitUntil("retired Reload completes before authority release") {
            session.text == external &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }

        XCTAssertEqual(session.text, external)
        XCTAssertFalse(session.isDirty)
        XCTAssertNil(appState.retiredEditorDocumentSessions[canonicalURL])
        XCTAssertNil(appState.pendingExternalTexts[canonicalURL])
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), external)
    }

    func testWorkspaceRetirementRetainsCapturedAuthorityAfterSelectedRootRetarget() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let rootA = parent.appendingPathComponent("root-a", isDirectory: true)
        let rootB = parent.appendingPathComponent("root-b", isDirectory: true)
        let selectedRoot = parent.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: selectedRoot, withDestinationURL: rootA)
        let documentA = rootA.appendingPathComponent("post.md").standardizedFileURL
        let documentB = rootB.appendingPathComponent("post.md").standardizedFileURL
        try "A source".write(to: documentA, atomically: true, encoding: .utf8)
        try "B sentinel".write(to: documentB, atomically: true, encoding: .utf8)
        let session = DocumentSession(
            text: "A source",
            url: documentA,
            fileKind: .markdown,
            isDirty: false
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        configureWorkspace(
            appState,
            rootURL: selectedRoot,
            paths: ["post.md"],
            currentSession: session,
            retainSecurityScope: true
        )
        let authorityA = try XCTUnwrap(appState.workspaceSearchRootAuthority)
        let locationA = try authorityA.canonicalizedLocation(forFileURL: documentA)
        try appState.activateAnchoredFileSession(at: locationA)
        let editorBinding = appState.editorDocumentBinding(for: session)
        let installation = EditorDocumentBindingInstallation(
            bindingID: editorBinding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        editorBinding.onLifecycle(.installed(installation))

        try FileManager.default.removeItem(at: selectedRoot)
        try FileManager.default.createSymbolicLink(at: selectedRoot, withDestinationURL: rootB)
        try appState.closeWorkspaceForReplacement()

        let stateURL = try XCTUnwrap(appState.sessionStateURL(for: session))
        let retirement = try XCTUnwrap(appState.retiredEditorDocumentSessions[stateURL])
        XCTAssertEqual(
            retirement.securityScopedAuthorityOwners.first?.authority.url.standardizedFileURL,
            selectedRoot
        )
        let baseSnapshot = editorBinding.sourceContract.snapshot()
        XCTAssertEqual(
            editorBinding.sourceContract.writer(.activate(
                installation,
                from: baseSnapshot
            )),
            .activated(baseSnapshot)
        )
        XCTAssertEqual(
            editorBinding.sourceContract.publish(EditorDocumentSourcePublication(
                installation: installation,
                base: baseSnapshot,
                source: "late editor commit"
            )),
            .accepted(
                EditorDocumentSourceSnapshot(source: "late editor commit", revision: 1),
                sourceWasReconciled: false
            )
        )
        editorBinding.onLifecycle(.revoked(installation))

        XCTAssertEqual(try String(contentsOf: documentA, encoding: .utf8), "late editor commit")
        XCTAssertEqual(try String(contentsOf: documentB, encoding: .utf8), "B sentinel")
        XCTAssertNil(appState.retiredEditorDocumentSessions[stateURL])
    }

    // swiftlint:disable:next function_body_length
    func testUnanchoredRetirementUsesCapturedWorkspaceMembershipAfterUnlinkAndReplacement() throws {
        enum Mutation: CaseIterable {
            case unlink
            case replacement
        }

        for mutation in Mutation.allCases {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let documentURL = root.appendingPathComponent("post.md").standardizedFileURL
            try "captured original".write(
                to: documentURL,
                atomically: true,
                encoding: .utf8
            )
            let session = DocumentSession(
                text: "captured original",
                url: documentURL,
                fileKind: .markdown,
                isDirty: false
            )
            let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
            configureWorkspace(
                appState,
                rootURL: root,
                paths: ["post.md"],
                currentSession: session,
                retainSecurityScope: true
            )
            appState.retainUnanchoredManagedSessionOwnership(for: session)
            let editorBinding = appState.editorDocumentBinding(for: session)
            let installation = EditorDocumentBindingInstallation(
                bindingID: editorBinding.id,
                installationID: EditorDocumentBindingInstallationID()
            )
            editorBinding.onLifecycle(.installed(installation))
            let stateURL = try XCTUnwrap(appState.sessionStateURL(for: session))

            try FileManager.default.removeItem(at: documentURL)
            if mutation == .replacement {
                try "replacement B".write(
                    to: documentURL,
                    atomically: true,
                    encoding: .utf8
                )
            }

            try appState.closeWorkspaceForReplacement()

            let retirement = try XCTUnwrap(
                appState.retiredEditorDocumentSessions[stateURL],
                "mutation: \(mutation)"
            )
            XCTAssertEqual(
                retirement.securityScopedAuthorityOwners.first?.authority.url.standardizedFileURL,
                root.standardizedFileURL,
                "mutation: \(mutation)"
            )
            editorBinding.onLifecycle(.revoked(installation))
        }
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
            onDocumentBindingLifecycle: bindingA.onLifecycle,
            documentSourceContract: bindingA.sourceContract
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
            onDocumentBindingLifecycle: bindingB.onLifecycle,
            documentSourceContract: bindingB.sourceContract
        )
        documentBView.updateRepresentedTextView(
            editorFixture.scrollView,
            coordinator: editorFixture.coordinator
        )

        let canonicalDocumentAURL = documentAURL.standardizedFileURL.resolvingSymlinksInPath()
        let retirement = try XCTUnwrap(
            appState.retiredEditorDocumentSessions[canonicalDocumentAURL]
        )
        XCTAssertTrue(retirement.session === sessionA)
        XCTAssertEqual(
            retirement.securityScopedAuthorityOwners.first?.authority.url.standardizedFileURL,
            workspaceRoot.standardizedFileURL
        )
        XCTAssertFalse(retirement.awaitingInstallations.isEmpty)
        XCTAssertTrue(appState.isEditorDocumentBindingInstalled(bindingA.id, session: sessionA))
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
        XCTAssertNil(appState.retiredEditorDocumentSessions[canonicalDocumentAURL])
        XCTAssertNil(appState.editorDocumentBindingIDs[ObjectIdentifier(sessionA)])
        XCTAssertNil(appState.editorDocumentBindingSessions[bindingA.id])
        XCTAssertTrue(appState.isEditorDocumentBindingInstalled(bindingB.id, session: sessionB))
        bindingA.onLifecycle(.revoked(EditorDocumentBindingInstallation(
            bindingID: bindingA.id,
            installationID: EditorDocumentBindingInstallationID()
        )))
        XCTAssertTrue(appState.isEditorDocumentBindingInstalled(bindingB.id, session: sessionB))
        XCTAssertNil(appState.retiredEditorDocumentSessions[canonicalDocumentAURL])
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
            onDocumentBindingLifecycle: bindingA.onLifecycle,
            documentSourceContract: bindingA.sourceContract
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
        let canonicalDocumentAURL = try XCTUnwrap(appState.sessionStateURL(for: sessionA))
        let retirement = try XCTUnwrap(
            appState.retiredEditorDocumentSessions[canonicalDocumentAURL]
        )
        XCTAssertEqual(
            retirement.securityScopedAuthorityOwners.first?.authority.url.standardizedFileURL,
            workspaceA.standardizedFileURL
        )
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: sessionA), anchoredBindingA)
        XCTAssertEqual(
            appState.anchoredSessionFileBinding(for: sessionB)?.location.rootAuthority.canonicalRootURL,
            workspaceB.standardizedFileURL
        )
        XCTAssertEqual(appState.workspaceAccess?.url.standardizedFileURL, workspaceB.standardizedFileURL)

        let bindingB = appState.editorDocumentBinding(for: sessionB)
        let documentBView = MarkdownTextView(
            text: bindingB.text,
            styledText: nil,
            selection: Binding(get: { selectionB }, set: { selectionB = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentBURL),
            documentBindingID: bindingB.id,
            onDocumentBindingLifecycle: bindingB.onLifecycle,
            documentSourceContract: bindingB.sourceContract
        )
        documentBView.updateRepresentedTextView(
            editorFixture.scrollView,
            coordinator: editorFixture.coordinator
        )
        XCTAssertTrue(appState.isEditorDocumentBindingInstalled(bindingA.id, session: sessionA))

        editorFixture.textView.insertText("臺", replacementRange: .notFound)
        documentBView.updateRepresentedTextView(
            editorFixture.scrollView,
            coordinator: editorFixture.coordinator
        )

        XCTAssertEqual(sessionA.text, sourceA + "臺")
        XCTAssertEqual(sessionA.version, 1)
        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), sourceA + "臺")
        XCTAssertEqual(sessionB.text, sourceB)
        XCTAssertNil(appState.retiredEditorDocumentSessions[canonicalDocumentAURL])
        XCTAssertTrue(appState.isEditorDocumentBindingInstalled(bindingB.id, session: sessionB))
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
            onDocumentBindingLifecycle: bindingA.onLifecycle,
            documentSourceContract: bindingA.sourceContract
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
        XCTAssertTrue(appState.isEditorDocumentBindingInstalled(bindingA.id, session: sessionA))
        let canonicalDocumentAURL = documentAURL.standardizedFileURL.resolvingSymlinksInPath()
        let retirement = try XCTUnwrap(
            appState.retiredEditorDocumentSessions[canonicalDocumentAURL]
        )
        XCTAssertEqual(
            retirement.securityScopedAuthorityOwners.first?.authority.url.standardizedFileURL,
            workspaceA.standardizedFileURL
        )
        XCTAssertFalse(retirement.awaitingInstallations.isEmpty)

        try Data([0xFF]).write(to: missingDestinationURL)
        XCTAssertThrowsError(
            try appState.open(
                url: missingDestinationURL,
                rememberAsLastOpened: false,
                preserveWorkspace: false
            )
        )
        let retirementAfterRepeatedFailure = try XCTUnwrap(
            appState.retiredEditorDocumentSessions[canonicalDocumentAURL]
        )
        XCTAssertTrue(retirementAfterRepeatedFailure.session === sessionA)
        XCTAssertEqual(
            retirementAfterRepeatedFailure.securityScopedAuthorityOwners.first?.authority.url.standardizedFileURL,
            workspaceA.standardizedFileURL
        )
        XCTAssertFalse(retirementAfterRepeatedFailure.awaitingInstallations.isEmpty)
        XCTAssertNil(appState.workspaceRootURL)

        editorFixture.textView.insertText("臺", replacementRange: .notFound)
        XCTAssertEqual(sessionA.text, sourceA + "臺")
        XCTAssertEqual(sessionA.version, 1)
        XCTAssertTrue(sessionA.isDirty)
        XCTAssertNotNil(appState.retiredEditorDocumentSessions[canonicalDocumentAURL])

        MarkdownTextView.dismantleNSView(
            editorFixture.scrollView,
            coordinator: editorFixture.coordinator
        )
        XCTAssertTrue(appState.editorBindingInstallations.isEmpty)
        XCTAssertNil(appState.retiredEditorDocumentSessions[canonicalDocumentAURL])
        XCTAssertNil(appState.editorDocumentBindingIDs[ObjectIdentifier(sessionA)])
        XCTAssertNil(appState.editorDocumentBindingSessions[bindingA.id])
        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), sourceA + "臺")
        XCTAssertFalse(sessionA.isDirty)
    }

    // swiftlint:disable:next function_body_length
    func testTwoCoordinatorsShareOneBindingWithoutConsumingEachOthersInstallation() throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("a.md")
        let source = "A composition: "
        try source.write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: source, url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["a.md"],
            currentSession: session,
            retainSecurityScope: true
        )
        appState.recordKnownDiskText(source, for: documentURL)
        let binding = appState.editorDocumentBinding(for: session)
        var selection1: NSRange? = NSRange(location: (source as NSString).length, length: 0)
        var selection2: NSRange? = NSRange(location: (source as NSString).length, length: 0)
        let view1 = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: Binding(get: { selection1 }, set: { selection1 = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentURL),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let fixture1 = try makeEditorBridgeFixture(representable: view1, source: source)
        let firstInstallation = try XCTUnwrap(
            appState.editorBindingInstallations.keys.first
        )
        binding.onLifecycle(.installed(firstInstallation))
        XCTAssertEqual(appState.editorBindingInstallations.count, 1)

        let view2 = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: Binding(get: { selection2 }, set: { selection2 = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentURL),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let fixture2 = try makeEditorBridgeFixture(
            representable: view2,
            source: source,
            makeKey: false
        )
        defer {
            fixture1.window.orderOut(nil)
            fixture2.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(
                fixture1.scrollView,
                coordinator: fixture1.coordinator
            )
            MarkdownTextView.dismantleNSView(
                fixture2.scrollView,
                coordinator: fixture2.coordinator
            )
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
            try? FileManager.default.removeItem(at: rootURL)
        }

        XCTAssertEqual(appState.editorBindingInstallations.count, 2)
        XCTAssertEqual(
            Set(appState.editorBindingInstallations.keys.map(\.bindingID)),
            [binding.id]
        )

        try appState.closeWorkspaceForReplacement()
        let canonicalURL = documentURL.standardizedFileURL.resolvingSymlinksInPath()
        let retirement = try XCTUnwrap(appState.retiredEditorDocumentSessions[canonicalURL])
        let authorityOwner = try XCTUnwrap(retirement.securityScopedAuthorityOwners.first)
        XCTAssertEqual(retirement.awaitingInstallations.count, 2)
        XCTAssertFalse(authorityOwner.hasStopped)

        MarkdownTextView.dismantleNSView(
            fixture1.scrollView,
            coordinator: fixture1.coordinator
        )
        XCTAssertEqual(appState.editorBindingInstallations.count, 1)
        XCTAssertEqual(
            appState.retiredEditorDocumentSessions[canonicalURL]?.awaitingInstallations.count,
            1
        )
        XCTAssertFalse(authorityOwner.hasStopped)
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), source)
        binding.onLifecycle(.revoked(firstInstallation))
        binding.onLifecycle(.revoked(EditorDocumentBindingInstallation(
            bindingID: binding.id,
            installationID: EditorDocumentBindingInstallationID()
        )))
        XCTAssertEqual(appState.editorBindingInstallations.count, 1)
        XCTAssertTrue(appState.isEditorDocumentBindingInstalled(binding.id, session: session))

        fixture2.window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(fixture2.window.makeFirstResponder(fixture2.textView))
        fixture2.textView.textSelection = selection2 ?? .notFound
        let committedText = "臺e\u{0301}🧪"
        fixture2.textView.insertText(committedText, replacementRange: .notFound)
        let committedSource = source + committedText

        XCTAssertEqual(Array(session.text.utf16), Array(committedSource.utf16))
        XCTAssertEqual(session.version, 1)
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(appState.isEditorDocumentBindingInstalled(binding.id, session: session))

        MarkdownTextView.dismantleNSView(
            fixture2.scrollView,
            coordinator: fixture2.coordinator
        )
        XCTAssertNil(appState.retiredEditorDocumentSessions[canonicalURL])
        XCTAssertTrue(authorityOwner.hasStopped)
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), committedSource)
        XCTAssertFalse(session.isDirty)
    }

    // swiftlint:disable:next function_body_length
    func testSeparateCoordinatorsRetireAAndBWithOneSharedAuthorityUntilFinalRevoke() throws {
        let rootURL = try makeTemporaryDirectory()
        let documentAURL = rootURL.appendingPathComponent("a.md")
        let documentBURL = rootURL.appendingPathComponent("b.md")
        let sourceA = "A composition: "
        let sourceB = "B remains unchanged"
        try sourceA.write(to: documentAURL, atomically: true, encoding: .utf8)
        try sourceB.write(to: documentBURL, atomically: true, encoding: .utf8)
        let sessionA = DocumentSession(text: sourceA, url: documentAURL, fileKind: .markdown)
        let appState = AppState(currentDocument: sessionA, shouldRestoreLastOpenedFile: false)
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["a.md", "b.md"],
            currentSession: sessionA,
            retainSecurityScope: true
        )
        appState.recordKnownDiskText(sourceA, for: documentAURL)

        var selectionA: NSRange? = NSRange(location: (sourceA as NSString).length, length: 0)
        let bindingA = appState.editorDocumentBinding(for: sessionA)
        let viewA = MarkdownTextView(
            text: bindingA.text,
            styledText: nil,
            selection: Binding(get: { selectionA }, set: { selectionA = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentAURL),
            documentBindingID: bindingA.id,
            onDocumentBindingLifecycle: bindingA.onLifecycle,
            documentSourceContract: bindingA.sourceContract
        )
        let fixtureA = try makeEditorBridgeFixture(representable: viewA, source: sourceA)
        XCTAssertTrue(fixtureA.window.makeFirstResponder(fixtureA.textView))
        fixtureA.textView.textSelection = selectionA ?? .notFound
        fixtureA.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )

        try appState.activateFileSession(url: documentBURL)
        let sessionB = appState.currentDocument
        var selectionB: NSRange? = NSRange(location: 0, length: 0)
        let bindingB = appState.editorDocumentBinding(for: sessionB)
        let viewB = MarkdownTextView(
            text: bindingB.text,
            styledText: nil,
            selection: Binding(get: { selectionB }, set: { selectionB = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentBURL),
            documentBindingID: bindingB.id,
            onDocumentBindingLifecycle: bindingB.onLifecycle,
            documentSourceContract: bindingB.sourceContract
        )
        let fixtureB = try makeEditorBridgeFixture(
            representable: viewB,
            source: sourceB,
            makeKey: false
        )
        defer {
            fixtureA.window.orderOut(nil)
            fixtureB.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(
                fixtureA.scrollView,
                coordinator: fixtureA.coordinator
            )
            MarkdownTextView.dismantleNSView(
                fixtureB.scrollView,
                coordinator: fixtureB.coordinator
            )
            for task in appState.sessionAutosaveTasks.values {
                task.task.cancel()
            }
            for task in appState.sessionStatisticsTasks.values {
                task.task.cancel()
            }
            try? FileManager.default.removeItem(at: rootURL)
        }

        XCTAssertTrue(fixtureA.textView.hasMarkedText())
        XCTAssertEqual(appState.editorBindingInstallations.count, 2)
        fixtureA.textView.insertText("臺e\u{0301}🧪", replacementRange: .notFound)
        let committedSourceA = sourceA + "臺e\u{0301}🧪"
        XCTAssertEqual(Array(sessionA.text.utf16), Array(committedSourceA.utf16))
        XCTAssertEqual(sessionB.text, sourceB)

        try appState.closeWorkspaceForReplacement()
        let canonicalA = documentAURL.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalB = documentBURL.standardizedFileURL.resolvingSymlinksInPath()
        let retirementA = try XCTUnwrap(appState.retiredEditorDocumentSessions[canonicalA])
        let retirementB = try XCTUnwrap(appState.retiredEditorDocumentSessions[canonicalB])
        let authorityOwner = try XCTUnwrap(retirementA.securityScopedAuthorityOwners.first)
        XCTAssertTrue(retirementB.securityScopedAuthorityOwners.first === authorityOwner)
        XCTAssertEqual(authorityOwner.dependentSessionCount, 2)
        XCTAssertFalse(authorityOwner.hasStopped)

        MarkdownTextView.dismantleNSView(
            fixtureA.scrollView,
            coordinator: fixtureA.coordinator
        )
        XCTAssertNil(appState.retiredEditorDocumentSessions[canonicalA])
        XCTAssertNotNil(appState.retiredEditorDocumentSessions[canonicalB])
        XCTAssertEqual(authorityOwner.dependentSessionCount, 1)
        XCTAssertFalse(authorityOwner.hasStopped)
        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), committedSourceA)
        XCTAssertEqual(sessionB.text, sourceB)

        MarkdownTextView.dismantleNSView(
            fixtureB.scrollView,
            coordinator: fixtureB.coordinator
        )
        XCTAssertNil(appState.retiredEditorDocumentSessions[canonicalB])
        XCTAssertEqual(authorityOwner.dependentSessionCount, 0)
        XCTAssertTrue(authorityOwner.hasStopped)
        XCTAssertTrue(appState.editorBindingInstallations.isEmpty)
        XCTAssertEqual(try String(contentsOf: documentBURL, encoding: .utf8), sourceB)
    }

    // swiftlint:disable:next function_body_length
    func testRetiredSessionReactivationBeforeIMECommitKeepsOneCanonicalSessionAndTasks() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentAURL = rootURL.appendingPathComponent("a.md")
        let documentBURL = rootURL.appendingPathComponent("b.md")
        let sourceA = "A source: "
        let dirtySourceA = "A dirty source: "
        let sourceB = "B source"
        try sourceA.write(to: documentAURL, atomically: true, encoding: .utf8)
        try sourceB.write(to: documentBURL, atomically: true, encoding: .utf8)
        let defaultsSuiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.set(10, forKey: "Plainsong.settings.autosaveIntervalSeconds")
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
            currentSession: sessionA,
            retainSecurityScope: true
        )
        let canonicalA = try XCTUnwrap(appState.sessionStateURL(for: sessionA))
        appState.recordKnownDiskText(sourceA, for: canonicalA)
        appState.replaceDocumentText(dirtySourceA)

        var selectionA: NSRange? = NSRange(location: (dirtySourceA as NSString).length, length: 0)
        let bindingA = appState.editorDocumentBinding(for: sessionA)
        let viewA = MarkdownTextView(
            text: bindingA.text,
            styledText: nil,
            selection: Binding(get: { selectionA }, set: { selectionA = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentAURL),
            documentBindingID: bindingA.id,
            onDocumentBindingLifecycle: bindingA.onLifecycle,
            documentSourceContract: bindingA.sourceContract
        )
        let fixtureA = try makeEditorBridgeFixture(representable: viewA, source: dirtySourceA)
        defer {
            fixtureA.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(
                fixtureA.scrollView,
                coordinator: fixtureA.coordinator
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
        XCTAssertTrue(fixtureA.window.makeFirstResponder(fixtureA.textView))
        fixtureA.textView.textSelection = selectionA ?? .notFound
        fixtureA.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )

        try appState.open(
            url: documentBURL,
            rememberAsLastOpened: false,
            preserveWorkspace: false
        )
        let sessionB = appState.currentDocument
        let retirement = try XCTUnwrap(appState.retiredEditorDocumentSessions[canonicalA])
        XCTAssertTrue(retirement.session === sessionA)
        XCTAssertTrue(appState.currentDocument === sessionB)
        XCTAssertNil(appState.sessionAutosaveTasks[ObjectIdentifier(sessionA)])
        XCTAssertNotNil(appState.sessionStatisticsTasks[ObjectIdentifier(sessionA)])
        XCTAssertTrue(fixtureA.textView.hasMarkedText())

        try appState.open(
            url: documentAURL,
            rememberAsLastOpened: false,
            preserveWorkspace: false
        )
        XCTAssertTrue(appState.currentDocument === sessionA)
        XCTAssertTrue(appState.sessionCache[canonicalA] === sessionA)
        XCTAssertTrue(appState.retiredEditorDocumentSessions[canonicalA]?.session === sessionA)
        XCTAssertNil(appState.sessionAutosaveTasks[ObjectIdentifier(sessionA)])
        XCTAssertNotNil(appState.sessionStatisticsTasks[ObjectIdentifier(sessionA)])
        XCTAssertTrue(appState.isEditorDocumentBindingInstalled(bindingA.id, session: sessionA))
        XCTAssertEqual(
            appState.editorDocumentBindingIDs[ObjectIdentifier(sessionA)],
            bindingA.id
        )
        XCTAssertEqual(sessionB.text, sourceB)

        let committedText = "臺e\u{0301}🧪"
        fixtureA.textView.insertText(committedText, replacementRange: .notFound)
        let committedSourceA = dirtySourceA + committedText
        XCTAssertEqual(Array(sessionA.text.utf16), Array(committedSourceA.utf16))
        XCTAssertTrue(appState.currentDocument === sessionA)
        XCTAssertTrue(appState.sessionCache[canonicalA] === sessionA)
        XCTAssertTrue(appState.editorDocumentBindingSessions[bindingA.id] === sessionA)
        XCTAssertEqual(
            Set(appState.editorBindingInstallations.values.map(ObjectIdentifier.init)),
            [ObjectIdentifier(sessionA)]
        )
        XCTAssertTrue(sessionA.isDirty)
        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), sourceA)

        MarkdownTextView.dismantleNSView(
            fixtureA.scrollView,
            coordinator: fixtureA.coordinator
        )
        try await waitUntil("reactivated retirement finishes after inspection and revoke") {
            appState.externalDiskInspectionTasks[ObjectIdentifier(sessionA)] == nil &&
                appState.retiredEditorDocumentSessions[canonicalA] == nil
        }
        XCTAssertNil(appState.retiredEditorDocumentSessions[canonicalA])
        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), committedSourceA)
        XCTAssertFalse(sessionA.isDirty)
    }

    // swiftlint:disable:next function_body_length
    func testSaveCopyRekeysRetiredMarkedTextSessionWithoutRevokingLiveInstallation() async throws {
        let rootURL = try makeTemporaryDirectory()
        let sourceURL = rootURL.appendingPathComponent("missing.md")
        let destinationURL = rootURL.appendingPathComponent("recovered.md")
        let source = "Local composition: "
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: source, url: sourceURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["missing.md"],
            currentSession: session,
            retainSecurityScope: true
        )
        let oldCanonicalURL = try XCTUnwrap(appState.sessionStateURL(for: session))
        appState.recordKnownDiskText(source, for: oldCanonicalURL)
        var selection: NSRange? = NSRange(location: (source as NSString).length, length: 0)
        let binding = appState.editorDocumentBinding(for: session)
        let view = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: sourceURL),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let fixture = try makeEditorBridgeFixture(representable: view, source: source)
        defer {
            fixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(
                fixture.scrollView,
                coordinator: fixture.coordinator
            )
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
            try? FileManager.default.removeItem(at: rootURL)
        }
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.textSelection = selection ?? .notFound
        let installationsBeforeSaveCopy = Set(
            appState.editorBindingInstallations.keys
        )

        fixture.textView.insertText(" ordinary", replacementRange: .notFound)
        let ordinarySource = source + " ordinary"
        XCTAssertEqual(session.text, ordinarySource)
        fixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        try appState.closeWorkspaceForReplacement()
        XCTAssertEqual(appState.sessionStateURL(for: session), oldCanonicalURL)
        let oldRetirement = try XCTUnwrap(appState.retiredEditorDocumentSessions[oldCanonicalURL])
        let authorityOwner = try XCTUnwrap(oldRetirement.securityScopedAuthorityOwners.first)

        try FileManager.default.removeItem(at: sourceURL)
        appState.handleExternalChange(for: session)
        try await waitUntil("retired missing source inspection completes before Save Copy") {
            appState.missingFilePrompt?.fileURL == oldCanonicalURL &&
                appState.externalDiskInspectionTasks[ObjectIdentifier(session)] == nil
        }
        XCTAssertEqual(
            appState.missingFilePrompt?.fileURL.standardizedFileURL,
            sourceURL.standardizedFileURL
        )

        let committedText = "臺e\u{0301}🧪"
        fixture.textView.insertText(committedText, replacementRange: .notFound)
        let committedSource = ordinarySource + committedText
        XCTAssertEqual(Array(session.text.utf16), Array(committedSource.utf16))
        XCTAssertFalse(fixture.textView.hasMarkedText())

        try appState.saveDetachedCurrentDocument(to: destinationURL)
        let newCanonicalURL = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        XCTAssertNil(appState.retiredEditorDocumentSessions[oldCanonicalURL])
        XCTAssertTrue(appState.retiredEditorDocumentSessions[newCanonicalURL]?.session === session)
        XCTAssertTrue(appState.currentDocument === session)
        XCTAssertTrue(appState.sessionCache[newCanonicalURL] === session)
        XCTAssertEqual(session.fileURL?.standardizedFileURL, newCanonicalURL)
        XCTAssertEqual(appState.sessionStateURL(for: session), newCanonicalURL)
        XCTAssertEqual(appState.activeEditorDocumentIdentity, AppState.editorDocumentIdentity(for: newCanonicalURL))
        XCTAssertEqual(
            Set(appState.editorBindingInstallations.keys),
            installationsBeforeSaveCopy
        )
        XCTAssertTrue(appState.editorDocumentBindingSessions[binding.id] === session)
        XCTAssertNil(appState.missingFilePrompt)
        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), committedSource)
        XCTAssertFalse(authorityOwner.hasStopped)

        fixture.textView.insertText(" post-copy", replacementRange: .notFound)
        let finalSource = committedSource + " post-copy"
        XCTAssertEqual(Array(session.text.utf16), Array(finalSource.utf16))
        XCTAssertTrue(appState.currentDocument === session)
        XCTAssertTrue(appState.sessionCache[newCanonicalURL] === session)
        XCTAssertTrue(appState.isEditorDocumentBindingInstalled(binding.id, session: session))

        MarkdownTextView.dismantleNSView(
            fixture.scrollView,
            coordinator: fixture.coordinator
        )
        XCTAssertNil(appState.retiredEditorDocumentSessions[newCanonicalURL])
        XCTAssertTrue(authorityOwner.hasStopped)
        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), finalSource)
        XCTAssertFalse(session.isDirty)
    }

    func testSaveCopyRejectsRetiredDestinationBeforeWritingOrRekeying() throws {
        let rootURL = try makeTemporaryDirectory()
        let sourceURL = rootURL.appendingPathComponent("missing.md")
        let destinationURL = rootURL.appendingPathComponent("owned.md")
        let source = "local recovery source"
        let destinationSource = "existing retired destination"
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        try destinationSource.write(to: destinationURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceSession = DocumentSession(
            text: source,
            url: sourceURL,
            fileKind: .markdown,
            isDirty: true
        )
        let destinationSession = DocumentSession(
            text: destinationSource,
            url: destinationURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(
            currentDocument: sourceSession,
            shouldRestoreLastOpenedFile: false
        )
        let sourceKey = try XCTUnwrap(appState.sessionStateURL(for: sourceSession))
        let destinationKey = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        appState.retainUnanchoredManagedSessionOwnership(for: destinationSession)
        try FileManager.default.removeItem(at: sourceURL)
        appState.sessionCache[sourceKey] = sourceSession
        appState.detachedSessionURLs.insert(sourceKey)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: sourceKey)
        appState.retiredEditorDocumentSessions[sourceKey] = RetiredEditorDocumentSession(
            canonicalURL: sourceKey,
            session: sourceSession,
            bindingIDs: [],
            awaitingInstallations: [],
            securityScopedAuthorityOwners: []
        )
        appState.retiredEditorDocumentSessions[destinationKey] = RetiredEditorDocumentSession(
            canonicalURL: destinationKey,
            session: destinationSession,
            bindingIDs: [],
            awaitingInstallations: [],
            securityScopedAuthorityOwners: []
        )

        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: destinationURL)) { error in
            guard case let AppStateError.invalidSessionIdentity(url) = error else {
                return XCTFail("Expected retained destination ownership rejection, got \(error)")
            }
            XCTAssertEqual(url, destinationKey)
        }
        XCTAssertEqual(
            try String(contentsOf: destinationURL, encoding: .utf8),
            destinationSource
        )
        XCTAssertTrue(appState.retiredEditorDocumentSessions[sourceKey]?.session === sourceSession)
        XCTAssertTrue(
            appState.retiredEditorDocumentSessions[destinationKey]?.session === destinationSession
        )
        XCTAssertTrue(appState.sessionCache[sourceKey] === sourceSession)
        XCTAssertEqual(sourceSession.fileURL?.standardizedFileURL, sourceKey)
        XCTAssertTrue(sourceSession.isDirty)
    }

    // swiftlint:disable:next function_body_length
    func testRetiredSaveFailureKeepsSourceReachableAndRetryReleasesAuthority() throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("a.md")
        let source = "A source"
        let localSource = "A local recovery source"
        try source.write(to: documentURL, atomically: true, encoding: .utf8)
        let fileWriter = FailingOnceWorkspaceAnchoredFileWriter()
        let session = DocumentSession(text: source, url: documentURL, fileKind: .markdown)
        let appState = AppState(
            currentDocument: session,
            shouldRestoreLastOpenedFile: false
        )
        appState.anchoredFileSaveOverride = { text, location, expectation in
            try fileWriter.save(text: text, to: location, expecting: expectation)
        }
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["a.md"],
            currentSession: session,
            retainSecurityScope: true
        )
        appState.recordKnownDiskText(source, for: documentURL)
        let binding = appState.editorDocumentBinding(for: session)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        appState.replaceDocumentText(localSource)
        defer {
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
            try? FileManager.default.removeItem(at: rootURL)
        }

        try appState.closeWorkspaceForReplacement()
        let canonicalURL = documentURL.standardizedFileURL.resolvingSymlinksInPath()
        let authorityOwner = try XCTUnwrap(
            appState.retiredEditorDocumentSessions[canonicalURL]?
                .securityScopedAuthorityOwners.first
        )
        binding.onLifecycle(.revoked(installation))

        XCTAssertEqual(fileWriter.writeAttemptCount, 1)
        XCTAssertTrue(appState.currentDocument === session)
        XCTAssertEqual(session.text, localSource)
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(appState.retiredEditorDocumentSessions[canonicalURL]?.session === session)
        XCTAssertTrue(
            appState.retiredEditorDocumentSessions[canonicalURL]?.awaitingInstallations.isEmpty == true
        )
        XCTAssertEqual(appState.presentedError?.title, "Could Not Save Retired File")
        XCTAssertFalse(authorityOwner.hasStopped)
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), source)

        appState.presentedError = nil
        appState.finishRetiredEditorDocumentSessionIfPossible(for: session)

        XCTAssertEqual(fileWriter.writeAttemptCount, 2)
        XCTAssertNil(appState.presentedError)
        XCTAssertNil(appState.retiredEditorDocumentSessions[canonicalURL])
        XCTAssertTrue(authorityOwner.hasStopped)
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), localSource)
        XCTAssertFalse(session.isDirty)
    }

    // swiftlint:disable:next function_body_length
    func testEndedMissingRetirementReopensExactSessionBeforeDiskAndSaveCopyRecoversIt() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentAURL = rootURL.appendingPathComponent("a.md")
        let documentBURL = rootURL.appendingPathComponent("b.md")
        let recoveredURL = rootURL.appendingPathComponent("recovered.md")
        let sourceA = "A source"
        let localSourceA = "A unsaved local source"
        let sourceB = "B source"
        try sourceA.write(to: documentAURL, atomically: true, encoding: .utf8)
        try sourceB.write(to: documentBURL, atomically: true, encoding: .utf8)
        let sessionA = DocumentSession(text: sourceA, url: documentAURL, fileKind: .markdown)
        let appState = AppState(currentDocument: sessionA, shouldRestoreLastOpenedFile: false)
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["a.md", "b.md"],
            currentSession: sessionA,
            retainSecurityScope: true
        )
        let canonicalA = try XCTUnwrap(appState.sessionStateURL(for: sessionA))
        appState.recordKnownDiskText(sourceA, for: canonicalA)
        let bindingA = appState.editorDocumentBinding(for: sessionA)
        let installationA = EditorDocumentBindingInstallation(
            bindingID: bindingA.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        bindingA.onLifecycle(.installed(installationA))
        appState.replaceDocumentText(localSourceA)
        defer {
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
        }

        try appState.closeWorkspaceForReplacement()
        let authorityOwner = try XCTUnwrap(
            appState.retiredEditorDocumentSessions[canonicalA]?
                .securityScopedAuthorityOwners.first
        )
        try FileManager.default.removeItem(at: documentAURL)
        appState.handleExternalChange(for: sessionA)
        bindingA.onLifecycle(.revoked(installationA))
        try await waitUntil("ended retirement records the missing source") {
            appState.missingFilePrompt?.fileURL == canonicalA &&
                appState.externalDiskInspectionTasks[ObjectIdentifier(sessionA)] == nil
        }
        XCTAssertTrue(appState.retiredEditorDocumentSessions[canonicalA]?.session === sessionA)
        XCTAssertTrue(
            appState.retiredEditorDocumentSessions[canonicalA]?.awaitingInstallations.isEmpty == true
        )
        XCTAssertEqual(
            appState.missingFilePrompt?.fileURL.standardizedFileURL,
            documentAURL.standardizedFileURL
        )
        XCTAssertEqual(sessionA.text, localSourceA)
        XCTAssertFalse(authorityOwner.hasStopped)

        try appState.open(
            url: documentBURL,
            rememberAsLastOpened: false,
            preserveWorkspace: false
        )
        let sessionB = appState.currentDocument
        XCTAssertEqual(sessionB.text, sourceB)
        XCTAssertNil(appState.missingFilePrompt)
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertTrue(appState.retiredEditorDocumentSessions[canonicalA]?.session === sessionA)

        try appState.activateFileSession(url: documentAURL)
        try await waitUntil("reactivated missing inspection completes before Save Copy") {
            appState.missingFilePrompt?.fileURL == canonicalA &&
                appState.externalDiskInspectionTasks[ObjectIdentifier(sessionA)] == nil
        }
        XCTAssertTrue(appState.currentDocument === sessionA)
        XCTAssertTrue(appState.sessionCache[canonicalA] === sessionA)
        XCTAssertEqual(sessionA.text, localSourceA)
        XCTAssertEqual(
            appState.missingFilePrompt?.fileURL.standardizedFileURL,
            documentAURL.standardizedFileURL
        )

        try appState.saveDetachedCurrentDocument(to: recoveredURL)
        let recoveredCanonicalURL = recoveredURL.standardizedFileURL.resolvingSymlinksInPath()
        XCTAssertTrue(appState.currentDocument === sessionA)
        XCTAssertTrue(appState.sessionCache[recoveredCanonicalURL] === sessionA)
        XCTAssertEqual(sessionA.fileURL?.standardizedFileURL, recoveredCanonicalURL)
        XCTAssertNil(appState.retiredEditorDocumentSessions[canonicalA])
        XCTAssertNil(appState.retiredEditorDocumentSessions[recoveredCanonicalURL])
        XCTAssertTrue(authorityOwner.hasStopped)
        XCTAssertEqual(try String(contentsOf: recoveredURL, encoding: .utf8), localSourceA)
        XCTAssertFalse(sessionA.isDirty)
    }

    func testRetiredConflictKeepMineUsesRealPromptSavesLocalSourceAndReleasesAuthority() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("a.md")
        let source = "A source"
        let localSource = "A local source"
        let externalSource = "A external source"
        try source.write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: source, url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["a.md"],
            currentSession: session,
            retainSecurityScope: true
        )
        let canonicalURL = try XCTUnwrap(appState.sessionStateURL(for: session))
        appState.recordKnownDiskText(source, for: canonicalURL)
        let binding = appState.editorDocumentBinding(for: session)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        appState.replaceDocumentText(localSource)
        try externalSource.write(to: documentURL, atomically: true, encoding: .utf8)
        appState.lastKnownDiskModificationDates[canonicalURL] = .distantPast
        appState.handleExternalChange(for: session)
        defer {
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
            try? FileManager.default.removeItem(at: rootURL)
        }

        try appState.closeWorkspaceForReplacement()
        let authorityOwner = try XCTUnwrap(
            appState.retiredEditorDocumentSessions[canonicalURL]?
                .securityScopedAuthorityOwners.first
        )
        binding.onLifecycle(.revoked(installation))
        try await waitUntil("retired external source is ready for Keep Mine") {
            appState.externalChangePrompt?.fileURL == canonicalURL &&
                appState.pendingExternalTexts[canonicalURL] == externalSource &&
                appState.externalDiskInspectionTasks[ObjectIdentifier(session)] == nil
        }
        XCTAssertEqual(
            appState.externalChangePrompt?.fileURL.standardizedFileURL,
            documentURL.standardizedFileURL
        )
        XCTAssertEqual(appState.pendingExternalTexts[canonicalURL], externalSource)

        appState.keepMineForExternallyChangedFile()

        try await waitUntil("retired Keep Mine saves and releases authority") {
            appState.retiredEditorDocumentSessions[canonicalURL] == nil
        }

        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertNil(appState.pendingExternalTexts[canonicalURL])
        XCTAssertNil(appState.retiredEditorDocumentSessions[canonicalURL])
        XCTAssertTrue(authorityOwner.hasStopped)
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), localSource)
        XCTAssertFalse(session.isDirty)
    }

    func testMissingRetirementExplicitCloseDiscardsSourceAndReleasesAuthority() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("a.md")
        let source = "A unsaved source"
        try source.write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: source, url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["a.md"],
            currentSession: session,
            retainSecurityScope: true
        )
        let canonicalURL = try XCTUnwrap(appState.sessionStateURL(for: session))
        appState.recordKnownDiskText(source, for: canonicalURL)
        let binding = appState.editorDocumentBinding(for: session)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        try FileManager.default.removeItem(at: documentURL)
        appState.handleExternalChange(for: session)
        try appState.closeWorkspaceForReplacement()
        let authorityOwner = try XCTUnwrap(
            appState.retiredEditorDocumentSessions[canonicalURL]?
                .securityScopedAuthorityOwners.first
        )
        binding.onLifecycle(.revoked(installation))
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try await waitUntil("retired missing inspection completes before explicit close") {
            appState.missingFilePrompt?.fileURL == canonicalURL &&
                appState.externalDiskInspectionTasks[ObjectIdentifier(session)] == nil
        }
        XCTAssertNotNil(appState.missingFilePrompt)
        XCTAssertTrue(appState.currentDocument === session)
        XCTAssertEqual(session.text, source)
        XCTAssertFalse(authorityOwner.hasStopped)

        appState.closeMissingFile()

        XCTAssertNil(appState.currentDocument.fileURL)
        XCTAssertNil(appState.missingFilePrompt)
        XCTAssertNil(appState.retiredEditorDocumentSessions[canonicalURL])
        XCTAssertTrue(authorityOwner.hasStopped)
        XCTAssertTrue(appState.editorBindingInstallations.isEmpty)
        XCTAssertTrue(appState.editorDocumentBindingIDs.isEmpty)
        XCTAssertTrue(appState.editorDocumentBindingSessions.isEmpty)
    }

    func testRetiredAutosaveContentFencePreservesInPlaceRewriteWithoutWatcher() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("a.md")
        let original = "AAAA"
        let local = "A retired local source"
        let external = "BBBB"
        try original.write(to: documentURL, atomically: true, encoding: .utf8)
        let defaultsSuiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.set(0.5, forKey: "Plainsong.settings.autosaveIntervalSeconds")
        let session = DocumentSession(text: original, url: documentURL, fileKind: .markdown)
        let appState = AppState(
            currentDocument: session,
            shouldRestoreLastOpenedFile: false,
            userDefaults: defaults
        )
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["a.md"],
            currentSession: session,
            retainSecurityScope: true
        )
        let key = try XCTUnwrap(appState.sessionStateURL(for: session))
        appState.recordKnownDiskText(original, for: key)
        let originalIdentity = try regularIdentity(at: documentURL)
        let binding = appState.editorDocumentBinding(for: session)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        defer {
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
            for task in appState.sessionAutosaveTasks.values {
                task.task.cancel()
            }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: rootURL)
        }

        appState.replaceDocumentText(local, in: session)
        try appState.closeWorkspaceForReplacement()
        let authorityOwner = try XCTUnwrap(
            appState.retiredEditorDocumentSessions[key]?
                .securityScopedAuthorityOwners.first
        )
        XCTAssertNotNil(appState.sessionAutosaveTasks[ObjectIdentifier(session)])
        let handle = try FileHandle(forWritingTo: documentURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(external.utf8))
        try handle.synchronize()
        try handle.close()
        XCTAssertEqual(try regularIdentity(at: documentURL), originalIdentity)

        try await waitUntil("retired autosave detects exact disk content mismatch") {
            appState.pendingExternalTexts[key] == external &&
                appState.externalDiskInspectionTasks[ObjectIdentifier(session)] == nil
        }

        XCTAssertEqual(session.text, local)
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(appState.retiredEditorDocumentSessions[key]?.session === session)
        XCTAssertFalse(appState.canAutosave(session: session))
        XCTAssertNil(appState.sessionAutosaveTasks[ObjectIdentifier(session)])
        XCTAssertEqual(appState.presentedError?.title, "Autosave Failed")
        XCTAssertFalse(authorityOwner.hasStopped)
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), external)
        binding.onLifecycle(.revoked(installation))
        XCTAssertNotNil(appState.retiredEditorDocumentSessions[key])
    }

    // swiftlint:disable:next function_body_length
    func testSuccessfulTreeSelectionTransfersPendingAutosaveStatisticsAndTerminationFlush() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentAURL = rootURL.appendingPathComponent("a.md")
        let documentBURL = rootURL.appendingPathComponent("b.md")
        let sourceA = "A source"
        let dirtySourceA = "A exact dirty source e\u{0301}🧪"
        let sourceB = "B independent source"
        try sourceA.write(to: documentAURL, atomically: true, encoding: .utf8)
        try sourceB.write(to: documentBURL, atomically: true, encoding: .utf8)
        let defaultsSuiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.set(0.15, forKey: "Plainsong.settings.autosaveIntervalSeconds")
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
        appState.recordKnownDiskText(sourceA, for: documentAURL)
        defer {
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

        appState.replaceDocumentText(dirtySourceA)
        XCTAssertNotNil(appState.autosaveTask)
        XCTAssertNotNil(appState.statisticsTask)
        let tree = try XCTUnwrap(appState.workspaceTree)
        let nodeB = try XCTUnwrap(
            appState.firstNode(in: tree.root, relativePath: "b.md")
        )

        appState.selectWorkspaceNode(id: nodeB.id)

        let sessionB = appState.currentDocument
        XCTAssertEqual(sessionB.fileURL?.standardizedFileURL, documentBURL.standardizedFileURL)
        XCTAssertEqual(sessionB.text, sourceB)
        XCTAssertNotNil(appState.sessionAutosaveTasks[ObjectIdentifier(sessionA)])
        XCTAssertNotNil(appState.sessionStatisticsTasks[ObjectIdentifier(sessionA)])
        XCTAssertNil(appState.autosaveTask)
        XCTAssertNil(appState.statisticsTask)
        XCTAssertNil(appState.sessionAutosaveTasks[ObjectIdentifier(sessionB)])
        XCTAssertNil(appState.sessionStatisticsTasks[ObjectIdentifier(sessionB)])

        try await waitUntil("tree-switch A autosave and statistics finish") {
            !sessionA.isDirty &&
                sessionA.statistics == TextStatistics(text: dirtySourceA) &&
                (try? String(contentsOf: documentAURL, encoding: .utf8)) == dirtySourceA
        }
        XCTAssertEqual(sessionB.text, sourceB)
        XCTAssertNil(appState.sessionAutosaveTasks[ObjectIdentifier(sessionA)])
        XCTAssertNil(appState.sessionStatisticsTasks[ObjectIdentifier(sessionA)])

        let terminationSourceA = dirtySourceA + "\ntermination flush"
        appState.applyDocumentText(terminationSourceA, to: sessionA)
        XCTAssertTrue(sessionA.isDirty)
        XCTAssertNotNil(appState.sessionAutosaveTasks[ObjectIdentifier(sessionA)])
        appState.cancelBackgroundAutosave(for: sessionA)
        appState.flushAutosaveIfNeeded()

        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), terminationSourceA)
        XCTAssertFalse(sessionA.isDirty)
        XCTAssertTrue(appState.currentDocument === sessionB)
        XCTAssertEqual(sessionB.text, sourceB)
    }

    // swiftlint:disable:next function_body_length
    func testSuccessfulSearchActivationTransfersPendingAWorkAndNavigatesBExactly() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let defaultsSuiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.set(0.15, forKey: "Plainsong.settings.autosaveIntervalSeconds")
        let sourceA = "alpha source"
        let dirtySourceA = "alpha exact dirty e\u{0301}🧪"
        let sourceB = "# B\nbeta source"
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": sourceA, "b.md": sourceB],
            currentPath: "a.md",
            userDefaults: defaults
        )
        defer {
            cleanUp(fixture)
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        let appState = fixture.appState
        let sessionA = appState.currentDocument
        let documentAURL = fixture.rootURL.appendingPathComponent("a.md")
        let documentBURL = fixture.rootURL.appendingPathComponent("b.md")
        appState.recordKnownDiskText(sourceA, for: documentAURL)
        appState.replaceDocumentText(dirtySourceA)
        appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "beta"))
        try await waitUntil("search-switch request starts") { provider.requests.count == 1 }
        let request = provider.requests[0]
        let activeContext = context(for: request)
        let fileResult = result(
            path: "b.md",
            text: sourceB,
            needle: "beta",
            rootURL: fixture.rootURL
        )
        let match = try XCTUnwrap(fileResult.matches.first)
        provider.yield(.fileResult(activeContext, fileResult), to: 0)
        try await waitUntil("search-switch result applies") {
            appState.workspaceSearchState.fileResults == [fileResult]
        }

        appState.activateWorkspaceSearchResult(
            context: activeContext,
            fileResult: fileResult,
            match: match
        )

        let sessionB = appState.currentDocument
        XCTAssertEqual(sessionB.fileURL?.standardizedFileURL, documentBURL.standardizedFileURL)
        XCTAssertEqual(sessionB.text, sourceB)
        XCTAssertNotNil(appState.sessionAutosaveTasks[ObjectIdentifier(sessionA)])
        XCTAssertNotNil(appState.sessionStatisticsTasks[ObjectIdentifier(sessionA)])
        XCTAssertNil(appState.autosaveTask)
        XCTAssertNil(appState.statisticsTask)
        let navigation = try navigationRequest(from: appState.editorNavigationCommand)
        XCTAssertEqual(navigation.documentIdentity, AppState.editorDocumentIdentity(for: documentBURL))
        XCTAssertEqual(navigation.selection, match.range)

        try await waitUntil("search-switch A work and B completion finish") {
            !sessionA.isDirty &&
                sessionA.statistics == TextStatistics(text: dirtySourceA) &&
                appState.completionWorkspace.currentFilePath == "b.md" &&
                (try? String(contentsOf: documentAURL, encoding: .utf8)) == dirtySourceA
        }
        XCTAssertEqual(appState.completionWorkspace.currentFileHeadingAnchors, ["#b"])
        XCTAssertEqual(sessionB.text, sourceB)
        XCTAssertNil(appState.sessionAutosaveTasks[ObjectIdentifier(sessionB)])
        XCTAssertNil(appState.sessionStatisticsTasks[ObjectIdentifier(sessionB)])
        XCTAssertNil(appState.sessionAutosaveTasks[ObjectIdentifier(sessionA)])
        XCTAssertNil(appState.sessionStatisticsTasks[ObjectIdentifier(sessionA)])
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

    func testSidebarModeSwitchDoesNotMutateFilesTreeSelectionOrDirectoryExpansion() throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "alpha", "nested/b.md": "beta"],
            currentPath: "a.md"
        )
        defer { cleanUp(fixture) }

        // makeFixture's path-only snapshot omits directory entries; install an explicit tree
        // that includes the nested folder so selection/expansion are meaningful.
        let hierarchicalSnapshot = WorkspaceFileSnapshot(entries: [
            WorkspaceFileSnapshot.Entry(
                relativePath: "a.md",
                kind: .markdown,
                identity: "id:a.md",
                contentModificationDate: nil
            ),
            WorkspaceFileSnapshot.Entry(
                relativePath: "nested",
                kind: .directory,
                identity: "id:nested",
                contentModificationDate: nil
            ),
            WorkspaceFileSnapshot.Entry(
                relativePath: "nested/b.md",
                kind: .markdown,
                identity: "id:nested/b.md",
                contentModificationDate: nil
            ),
        ])
        fixture.appState.workspaceSnapshot = hierarchicalSnapshot
        fixture.appState.workspaceTree = WorkspaceFileTree.reconcile(
            previous: fixture.appState.workspaceTree,
            snapshot: hierarchicalSnapshot,
            options: .init(showAllFiles: false)
        )

        let treeBefore = try XCTUnwrap(fixture.appState.workspaceTree)
        let nestedDirectory = try XCTUnwrap(
            treeBefore.root.children.first { $0.isDirectory && $0.relativePath == "nested" }
        )
        let nestedFile = try XCTUnwrap(
            nestedDirectory.children.first {
                $0.isEditableMarkdown && $0.relativePath == "nested/b.md"
            }
        )
        XCTAssertNotEqual(nestedDirectory.id, nestedFile.id)
        XCTAssertNotEqual(treeBefore.selectedNodeID, nestedFile.id)

        fixture.appState.setWorkspaceNodeExpanded(true, id: nestedDirectory.id)
        fixture.appState.selectWorkspaceNode(id: nestedFile.id)

        let treeAfterSelect = try XCTUnwrap(fixture.appState.workspaceTree)
        XCTAssertEqual(treeAfterSelect.selectedNodeID, nestedFile.id)
        XCTAssertTrue(treeAfterSelect.isExpanded(nestedDirectory.id))
        XCTAssertEqual(fixture.appState.currentDocument.fileURL?.lastPathComponent, "b.md")

        fixture.appState.selectWorkspaceSidebarMode(.search)
        XCTAssertEqual(fixture.appState.workspaceSearchUI.mode, .search)

        fixture.appState.selectWorkspaceSidebarMode(.files)
        XCTAssertEqual(fixture.appState.workspaceSearchUI.mode, .files)

        let treeAfterModeCycle = try XCTUnwrap(fixture.appState.workspaceTree)
        XCTAssertEqual(treeAfterModeCycle.selectedNodeID, nestedFile.id)
        XCTAssertTrue(treeAfterModeCycle.isExpanded(nestedDirectory.id))
        XCTAssertEqual(
            Set(treeAfterModeCycle.root.children.map(\.relativePath)),
            Set(["a.md", "nested"])
        )
        XCTAssertEqual(fixture.appState.currentDocument.fileURL?.lastPathComponent, "b.md")
    }

    func testRepeatedFocusWorkspaceSearchIncrementsTokenAndConsumedTokenDoesNotReplay() throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "alpha"]
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState

        XCTAssertEqual(appState.workspaceSearchUI.mode, .files)
        XCTAssertEqual(appState.workspaceSearchUI.focusRequestID, 0)
        XCTAssertEqual(appState.workspaceSearchUI.focusAppliedID, 0)
        XCTAssertFalse(
            WorkspaceSearchFocusArbitration.shouldApplyFocus(
                requestID: 0,
                appliedID: 0,
                isKeyWindow: true
            )
        )
        // Background windows must never apply, even for a fresh token.
        XCTAssertFalse(
            WorkspaceSearchFocusArbitration.shouldApplyFocus(
                requestID: 1,
                appliedID: 0,
                isKeyWindow: false
            )
        )

        appState.focusWorkspaceSearch()
        XCTAssertEqual(appState.workspaceSearchUI.mode, .search)
        XCTAssertEqual(appState.workspaceSearchUI.focusRequestID, 1)
        XCTAssertEqual(appState.workspaceSearchUI.focusAppliedID, 0)
        XCTAssertTrue(
            WorkspaceSearchFocusArbitration.shouldApplyFocus(
                requestID: 1,
                appliedID: 0,
                isKeyWindow: true
            )
        )

        // Only a key-window success marks the global receipt (background must not consume).
        appState.markWorkspaceSearchFocusApplied(1)
        XCTAssertEqual(appState.workspaceSearchUI.focusAppliedID, 1)
        XCTAssertFalse(
            WorkspaceSearchFocusArbitration.shouldApplyFocus(
                requestID: 1,
                appliedID: 1,
                isKeyWindow: true
            )
        )
        XCTAssertFalse(
            WorkspaceSearchFocusArbitration.shouldApplyFocus(
                requestID: 1,
                appliedID: 1,
                isKeyWindow: false
            )
        )

        // Files → Search via picker must not replay the spent token.
        appState.selectWorkspaceSidebarMode(.files)
        appState.selectWorkspaceSidebarMode(.search)
        XCTAssertEqual(appState.workspaceSearchUI.focusRequestID, 1)
        XCTAssertEqual(appState.workspaceSearchUI.focusAppliedID, 1)
        XCTAssertFalse(
            WorkspaceSearchFocusArbitration.shouldApplyFocus(
                requestID: appState.workspaceSearchUI.focusRequestID,
                appliedID: appState.workspaceSearchUI.focusAppliedID,
                isKeyWindow: true
            )
        )

        // Workspace reset keeps the request id but marks it fully applied (no replay after reopen).
        appState.resetWorkspaceSearchUIState()
        XCTAssertEqual(appState.workspaceSearchUI.mode, .files)
        XCTAssertEqual(appState.workspaceSearchUI.focusRequestID, 1)
        XCTAssertEqual(appState.workspaceSearchUI.focusAppliedID, 1)
        XCTAssertFalse(
            WorkspaceSearchFocusArbitration.shouldApplyFocus(
                requestID: appState.workspaceSearchUI.focusRequestID,
                appliedID: appState.workspaceSearchUI.focusAppliedID,
                isKeyWindow: true
            )
        )

        // A new shortcut request after re-enabling search focus is required.
        appState.workspaceRootURL = fixture.rootURL
        appState.focusWorkspaceSearch()
        XCTAssertEqual(appState.workspaceSearchUI.focusRequestID, 2)
        XCTAssertEqual(appState.workspaceSearchUI.focusAppliedID, 1)
        XCTAssertTrue(
            WorkspaceSearchFocusArbitration.shouldApplyFocus(
                requestID: 2,
                appliedID: 1,
                isKeyWindow: true
            )
        )
        // Non-key windows still must not treat the new token as theirs to consume.
        XCTAssertFalse(
            WorkspaceSearchFocusArbitration.shouldApplyFocus(
                requestID: 2,
                appliedID: 1,
                isKeyWindow: false
            )
        )

        appState.focusWorkspaceSearch()
        XCTAssertEqual(appState.workspaceSearchUI.focusRequestID, 3)
    }

    func testSearchFieldIdentityIsIdentifierOnlyNotLabelOrPlaceholder() {
        // Same human-facing strings as Search, but a different accessibility identifier.
        let decoy = NSTextField(string: "")
        decoy.isEditable = true
        decoy.placeholderString = WorkspaceSearchFieldFocus.placeholder
        decoy.setAccessibilityLabel(WorkspaceSearchFieldFocus.accessibilityLabel)
        decoy.setAccessibilityIdentifier("plainsong.frontmatter.title")

        // Unlabeled sibling: old binder path would have stamped this as Search.
        let unlabeled = NSTextField(string: "")
        unlabeled.isEditable = true
        unlabeled.placeholderString = WorkspaceSearchFieldFocus.placeholder
        unlabeled.setAccessibilityLabel(WorkspaceSearchFieldFocus.accessibilityLabel)
        // Intentionally no accessibility identifier.

        let search = NSTextField(string: "")
        search.isEditable = true
        search.placeholderString = WorkspaceSearchFieldFocus.placeholder
        search.setAccessibilityLabel(WorkspaceSearchFieldFocus.accessibilityLabel)
        search.setAccessibilityIdentifier(WorkspaceSearchFieldFocus.accessibilityIdentifier)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        // Decys first so a non-identifier matcher would wrongly prefer them.
        root.addSubview(unlabeled)
        root.addSubview(decoy)
        root.addSubview(search)

        XCTAssertTrue(WorkspaceSearchFieldFocus.matchesSearchField(search))
        XCTAssertFalse(WorkspaceSearchFieldFocus.matchesSearchField(decoy))
        XCTAssertFalse(WorkspaceSearchFieldFocus.matchesSearchField(unlabeled))
        XCTAssertTrue(WorkspaceSearchFieldFocus.findSearchTextField(in: root) === search)
        XCTAssertNil(
            [decoy, unlabeled].first { WorkspaceSearchFieldFocus.findSearchTextField(in: root) === $0 }
        )
    }

    func testHostedSearchFieldHasStableIdentifierAndAdjacentUnlabeledDecoyIsUntouched() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "alpha"]
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        appState.selectWorkspaceSidebarMode(.search)

        // Container holds an unstamped decoy *outside* the SwiftUI Search TextField host, so a
        // scoped binder must not see it, while a recursive sibling-subtree scan would.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
        let decoy = NSTextField(string: "")
        decoy.isEditable = true
        decoy.isBezeled = true
        decoy.placeholderString = WorkspaceSearchFieldFocus.placeholder
        decoy.setAccessibilityLabel(WorkspaceSearchFieldFocus.accessibilityLabel)
        decoy.frame = NSRect(x: 8, y: 360, width: 264, height: 24)
        // No accessibility identifier — the forbidden binder path would stamp this.

        let searchRoot = WorkspaceSearchSidebar()
            .environmentObject(appState)
            .frame(width: 280, height: 340)
        let hostingView = NSHostingView(rootView: AnyView(searchRoot))
        hostingView.frame = NSRect(x: 0, y: 0, width: 280, height: 340)

        container.addSubview(decoy)
        container.addSubview(hostingView)

        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 280, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer {
            appState.workspaceSearchFocusKeyWindowCheck = nil
            window.orderOut(nil)
        }

        try await waitUntil("Search field is discoverable by identifier") {
            WorkspaceSearchFieldFocus.findSearchTextField(in: window.contentView) != nil
        }

        let searchField = try XCTUnwrap(
            WorkspaceSearchFieldFocus.findSearchTextField(in: window.contentView)
        )
        XCTAssertEqual(
            searchField.accessibilityIdentifier(),
            WorkspaceSearchFieldFocus.accessibilityIdentifier
        )
        XCTAssertFalse(searchField === decoy)

        // Decoy remains unstamped before and after focus.
        XCTAssertEqual(decoy.accessibilityIdentifier() ?? "", "")
        XCTAssertFalse(WorkspaceSearchFieldFocus.matchesSearchField(decoy))

        installDesignatedKeyWindowRouting(on: appState, designatedKeyWindow: window)
        appState.focusWorkspaceSearch()
        let requestID = appState.workspaceSearchUI.focusRequestID

        try await waitUntil("Search field receives focus receipt") {
            appState.workspaceSearchUI.focusAppliedID == requestID
                && WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: window)
        }

        XCTAssertEqual(decoy.accessibilityIdentifier() ?? "", "")
        XCTAssertFalse(WorkspaceSearchFieldFocus.matchesSearchField(decoy))
        XCTAssertFalse(window.firstResponder === decoy)
        if let fieldEditor = window.firstResponder as? NSTextView, fieldEditor.isFieldEditor {
            XCTAssertFalse(decoy.currentEditor() === fieldEditor)
        }
        XCTAssertTrue(
            WorkspaceSearchFieldFocus.findSearchTextField(in: window.contentView) === searchField
        )
    }

    func testHostedSearchFocusFromFilesModeMountsFieldAndAppliesFirstCommandShiftF() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "alpha"]
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        // Product path: start on Files; ⌘⇧F flips mode and focus token together.
        XCTAssertEqual(appState.workspaceSearchUI.mode, .files)

        let host = try await makeWorkspaceSidebarHost(appState: appState, makeKey: true)
        defer {
            appState.workspaceSearchFocusKeyWindowCheck = nil
            host.window.orderOut(nil)
        }
        installDesignatedKeyWindowRouting(on: appState, designatedKeyWindow: host.window)

        // Search field must not exist yet while Files mode is showing.
        XCTAssertNil(WorkspaceSearchFieldFocus.findSearchTextField(in: host.window.contentView))

        appState.focusWorkspaceSearch()
        let requestID = appState.workspaceSearchUI.focusRequestID
        XCTAssertEqual(appState.workspaceSearchUI.mode, .search)
        XCTAssertGreaterThan(requestID, 0)

        try await waitUntil("first ⌘⇧F mounts Search field and applies key-window focus") {
            appState.workspaceSearchUI.focusAppliedID == requestID
                && WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: host.window)
        }
        XCTAssertNotNil(WorkspaceSearchFieldFocus.findSearchTextField(in: host.window.contentView))
    }

    func testHostedSearchFocusOnlyKeyWindowBecomesFirstResponder() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "alpha"]
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState

        // Mount both hosts while still on Files, then fire focus so Search mounts under load.
        XCTAssertEqual(appState.workspaceSearchUI.mode, .files)
        let hostA = try await makeWorkspaceSidebarHost(appState: appState, makeKey: true)
        let hostB = try await makeWorkspaceSidebarHost(appState: appState, makeKey: false)
        defer {
            appState.workspaceSearchFocusKeyWindowCheck = nil
            hostA.window.orderOut(nil)
            hostB.window.orderOut(nil)
        }

        installDesignatedKeyWindowRouting(on: appState, designatedKeyWindow: hostA.window)

        appState.focusWorkspaceSearch()
        let requestID = appState.workspaceSearchUI.focusRequestID
        XCTAssertGreaterThan(requestID, 0)
        XCTAssertEqual(appState.workspaceSearchUI.mode, .search)

        try await waitUntil("key window search field is first responder and receipt advances") {
            appState.workspaceSearchUI.focusAppliedID == requestID
                && WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: hostA.window)
        }
        XCTAssertFalse(
            WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: hostB.window)
        )
        XCTAssertEqual(appState.workspaceSearchUI.focusAppliedID, requestID)
    }

    func testHostedSearchFocusDoesNotMarkAppliedAfterLosingKeyBeforeReceipt() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "alpha"]
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        appState.selectWorkspaceSidebarMode(.search)

        let hostA = try await makeSearchSidebarHost(appState: appState, makeKey: true)
        let hostB = try await makeSearchSidebarHost(appState: appState, makeKey: false)
        defer {
            appState.workspaceSearchFocusKeyWindowCheck = nil
            hostA.window.orderOut(nil)
            hostB.window.orderOut(nil)
        }

        installDesignatedKeyWindowRouting(on: appState, designatedKeyWindow: hostA.window)

        appState.focusWorkspaceSearch()
        let requestID = appState.workspaceSearchUI.focusRequestID

        // Immediately transfer designated key so any delayed task from A must re-read live
        // eligibility and refuse to mark the global receipt after losing key routing.
        installDesignatedKeyWindowRouting(on: appState, designatedKeyWindow: hostB.window)

        // Give A's delayed focus task time to run post-await checks against the new routing.
        try await Task.sleep(nanoseconds: 50_000_000)

        if appState.workspaceSearchUI.focusAppliedID == requestID {
            // B became designated key and legitimately finished the pending request.
            XCTAssertTrue(
                WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: hostB.window)
            )
            XCTAssertFalse(
                WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: hostA.window)
            )
        } else {
            // Receipt still open: A must not have stolen it after losing key routing.
            XCTAssertLessThan(appState.workspaceSearchUI.focusAppliedID, requestID)
            XCTAssertFalse(
                WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: hostA.window)
            )
            // B is designated key with an open receipt — key-routing refresh should let B claim it.
            appState.refreshWorkspaceSearchFocusKeyRouting()
            try await waitUntil("new key window claims the still-open focus receipt") {
                appState.workspaceSearchUI.focusAppliedID == requestID
                    && WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: hostB.window)
            }
        }
        XCTAssertEqual(appState.workspaceSearchUI.focusAppliedID, requestID)
        XCTAssertFalse(
            WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: hostA.window)
        )
    }

    func testHostedSearchFocusNewRequestGoesToNewlyKeyWindow() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "alpha"]
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        appState.selectWorkspaceSidebarMode(.search)

        let hostA = try await makeSearchSidebarHost(appState: appState, makeKey: true)
        let hostB = try await makeSearchSidebarHost(appState: appState, makeKey: false)
        defer {
            appState.workspaceSearchFocusKeyWindowCheck = nil
            hostA.window.orderOut(nil)
            hostB.window.orderOut(nil)
        }

        installDesignatedKeyWindowRouting(on: appState, designatedKeyWindow: hostA.window)

        appState.focusWorkspaceSearch()
        let firstRequest = appState.workspaceSearchUI.focusRequestID
        try await waitUntil("first key window applies focus") {
            appState.workspaceSearchUI.focusAppliedID == firstRequest
                && WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: hostA.window)
        }

        installDesignatedKeyWindowRouting(on: appState, designatedKeyWindow: hostB.window)
        appState.focusWorkspaceSearch()
        let secondRequest = appState.workspaceSearchUI.focusRequestID
        XCTAssertGreaterThan(secondRequest, firstRequest)

        try await waitUntil("new key window applies the newer focus request") {
            appState.workspaceSearchUI.focusAppliedID == secondRequest
                && WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: hostB.window)
        }
        // Receipt belongs to the second request (B). Non-key window firstResponder can be stale
        // under XCTest; the key guarantee is B is first responder with the latest receipt.
        XCTAssertEqual(appState.workspaceSearchUI.focusAppliedID, secondRequest)
        XCTAssertTrue(
            WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: hostB.window)
        )
    }

    /// Owner keyboard smoke (WS3C PR C merge gate), hosted on a real `NSWindow` and driven by
    /// **real `NSEvent`s** through `window.sendEvent`: field ↓/Escape route through the field
    /// editor's `doCommandBy`, ↑/↓/Return/Escape route through the results key responder,
    /// and the click scenario clicks a real backing table row — so silent native-table fallback
    /// or a broken focus handoff fails this test instead of passing synthetically.
    ///
    /// Covers: field ↓ into list, ↑/↓ without wrap, Return activation, real-click claim +
    /// activation with click-then-↑ via the pure reducer, Escape results→field and
    /// field→editor (query/results retained).
    func testHostedOwnerKeyboardSmokeFiveScenarios() async throws {
        #if !DEBUG
            throw XCTSkip("Keyboard smoke probe is Debug-only")
        #else
            WorkspaceSearchKeyboardSmokeProbe.reset()

            let provider = ControlledWorkspaceSearchStreamProvider()
            let fixture = try makeFixture(
                provider: provider,
                files: [
                    "a.md": "needle one\nneedle two",
                    "b.md": "needle three",
                ],
                currentPath: "a.md",
                debounceNanoseconds: 0
            )
            defer {
                WorkspaceSearchKeyboardSmokeProbe.reset()
                cleanUp(fixture)
            }
            let appState = fixture.appState
            appState.selectWorkspaceSidebarMode(.search)

            let host = try await makeSearchSidebarHost(appState: appState, makeKey: true)
            defer {
                appState.workspaceSearchFocusKeyWindowCheck = nil
                host.window.orderOut(nil)
            }
            installDesignatedKeyWindowRouting(on: appState, designatedKeyWindow: host.window)

            // Seed a completed multi-match search with authority-backed results.
            appState.updateWorkspaceSearchQueryText("needle")
            try await waitUntil("search starts") { provider.requests.count == 1 }
            let request = provider.requests[0]
            let searchContext = context(for: request)
            let resultA = multiMatchResult(
                path: "a.md",
                text: "needle one\nneedle two",
                needle: "needle",
                rootURL: fixture.rootURL
            )
            let resultB = multiMatchResult(
                path: "b.md",
                text: "needle three",
                needle: "needle",
                rootURL: fixture.rootURL
            )
            XCTAssertNotNil(resultA.fileAuthority)
            XCTAssertNotNil(resultB.fileAuthority)
            provider.yield(.fileResult(searchContext, resultA), to: 0)
            provider.yield(.fileResult(searchContext, resultB), to: 0)
            provider.yield(
                .completed(
                    searchContext,
                    summary(candidateFileCount: 2, searchedFileCount: 2, totalMatchCount: 3)
                ),
                to: 0
            )
            try await waitUntil("three matches apply") {
                appState.workspaceSearchState.phase == .completed
                    && appState.workspaceSearchState.fileResults.count == 2
                    && appState.workspaceSearchState.fileResults.reduce(0) { $0 + $1.matches.count } == 3
            }

            let presentation = WorkspaceSearchResultsPresenter.make(
                searchState: appState.workspaceSearchState,
                queryText: appState.workspaceSearchUI.queryText,
                canUseWorkspaceSearch: true,
                isWorkspaceSearchReady: true
            )
            let ordered = WorkspaceSearchSelectionNavigation.orderedRowIDs(in: presentation)
            XCTAssertEqual(ordered.count, 3)

            appState.focusWorkspaceSearch()
            let focusRequest = appState.workspaceSearchUI.focusRequestID
            try await waitUntil("search field focused for smoke") {
                appState.workspaceSearchUI.focusAppliedID == focusRequest
                    && WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: host.window)
            }

            // (1) Real ↓ in the field: field editor `doCommandBy` → first result selected,
            // results focus claimed, field editor released.
            sendSmokeDownArrow(to: host.window)
            try await waitUntil("real field ↓ selects first and claims results focus") {
                WorkspaceSearchKeyboardSmokeProbe.selectedRowID == ordered[0]
                    && WorkspaceSearchKeyboardSmokeProbe.isResultsFocused
            }
            XCTAssertFalse(
                WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: host.window),
                "field editor must release first responder after ↓ handoff"
            )
            try await waitUntil("SwiftUI claims key delivery after handoff") {
                let firstResponder = host.window.firstResponder
                return firstResponder !== host.window
                    && !WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: host.window)
            }

            try await verifyHostedNoWrapKeyboardSelection(
                window: host.window,
                ordered: ordered
            )

            // (3) Real Return activates the authority-backed current-state match.
            appState.editorNavigationCommand = nil
            sendSmokeReturn(to: host.window)
            try await waitUntil("real Return activates search result navigation") {
                if case .navigate = appState.editorNavigationCommand { return true }
                return false
            }
            try await waitUntil("results focus returns after Return activation") {
                WorkspaceSearchKeyboardSmokeProbe.isResultsFocused
            }

            // (4a) Real Escape on the List → query field first responder; query/results kept.
            sendSmokeEscape(to: host.window)
            var stableQueryFocusConfirmations = 0
            try await waitUntil("real Escape stably returns to search field") {
                if WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: host.window),
                   WorkspaceSearchKeyboardSmokeProbe.isResultsFocused == false
                {
                    stableQueryFocusConfirmations += 1
                } else {
                    stableQueryFocusConfirmations = 0
                }
                return stableQueryFocusConfirmations >= 3
            }
            XCTAssertEqual(appState.workspaceSearchUI.queryText, "needle")
            XCTAssertEqual(appState.workspaceSearchState.phase, .completed)
            XCTAssertEqual(appState.workspaceSearchState.fileResults.count, 2)

            // (4b) Real Escape in the field → editor focus request; query/results kept.
            let editorFocusBefore = appState.editorFocusRequestID
            sendSmokeEscape(to: host.window)
            try await waitUntil("real Escape in field requests editor focus") {
                appState.editorFocusRequestID == editorFocusBefore + 1
            }
            XCTAssertEqual(appState.workspaceSearchUI.queryText, "needle")
            XCTAssertEqual(appState.workspaceSearchState.fileResults.count, 2)
            XCTAssertEqual(appState.workspaceSearchState.phase, .completed)

            // (5) Real click on the last backing table row while results focus is lowered:
            // the selection binding must claim the concrete results responder, activation flows
            // through retained authority, and click-then-↑ routes through the selection surface.
            let tableView = try XCTUnwrap(
                findSubview(ofType: NSTableView.self, in: host.window.contentView),
                "results List must be backed by an NSTableView"
            )
            XCTAssertGreaterThan(tableView.numberOfRows, 0)
            appState.editorNavigationCommand = nil
            let lastRowRect = tableView.rect(ofRow: tableView.numberOfRows - 1)
            let clickPoint = tableView.convert(
                NSPoint(x: lastRowRect.midX, y: lastRowRect.midY),
                to: nil
            )
            sendSmokeClick(at: clickPoint, to: host.window)
            try await waitUntil("real click claims last result and results focus") {
                WorkspaceSearchKeyboardSmokeProbe.selectedRowID == ordered[2]
                    && WorkspaceSearchKeyboardSmokeProbe.isResultsFocused
            }
            try await waitUntil("real click activates through retained authority") {
                if case .navigate = appState.editorNavigationCommand { return true }
                return false
            }
            try await waitUntil("results focus returns after click activation") {
                WorkspaceSearchKeyboardSmokeProbe.isResultsFocused
            }
            sendSmokeUpArrow(to: host.window)
            try await waitUntil(
                "click-then-↑ routes through the selection surface",
                timeoutNanoseconds: 10_000_000_000
            ) {
                WorkspaceSearchKeyboardSmokeProbe.selectedRowID == ordered[1]
            }

            // Down after the first forced query confirmation is a newer results intent. It
            // must cancel the still-running loop instead of letting its next turn reclaim query.
            sendSmokeEscape(to: host.window)
            try await waitUntil("forced query loop reaches first Down-race confirmation") {
                WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: host.window)
                    && WorkspaceSearchKeyboardSmokeProbe.isResultsFocused == false
            }
            sendSmokeDownArrow(to: host.window)
            try await waitUntil("Down supersedes forced query loop") {
                WorkspaceSearchKeyboardSmokeProbe.isResultsFocused
                    && WorkspaceSearchKeyboardSmokeProbe.selectedRowID == ordered[0]
            }
            var stableDownResultsConfirmations = 0
            try await waitUntil("forced loop cannot reclaim query after Down") {
                if !WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: host.window),
                   WorkspaceSearchKeyboardSmokeProbe.isResultsFocused
                {
                    stableDownResultsConfirmations += 1
                } else {
                    stableDownResultsConfirmations = 0
                }
                return stableDownResultsConfirmations >= 6
            }

            // A row click during the same confirmation window is also a newer results intent.
            sendSmokeEscape(to: host.window)
            try await waitUntil("forced query loop reaches first click-race confirmation") {
                WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: host.window)
                    && WorkspaceSearchKeyboardSmokeProbe.isResultsFocused == false
            }
            let raceClickRowRect = tableView.rect(ofRow: tableView.numberOfRows - 1)
            let raceClickPoint = tableView.convert(
                NSPoint(x: raceClickRowRect.midX, y: raceClickRowRect.midY),
                to: nil
            )
            sendSmokeClick(at: raceClickPoint, to: host.window)
            try await waitUntil("click supersedes forced query loop") {
                WorkspaceSearchKeyboardSmokeProbe.isResultsFocused
            }
            var stableClickResultsConfirmations = 0
            try await waitUntil("forced loop cannot reclaim query after click") {
                if !WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: host.window),
                   WorkspaceSearchKeyboardSmokeProbe.isResultsFocused
                {
                    stableClickResultsConfirmations += 1
                } else {
                    stableClickResultsConfirmations = 0
                }
                return stableClickResultsConfirmations >= 6
            }

            // A stale authority/generation rejects activation synchronously. Results routing
            // must remain live; there is no editor handoff and no delayed fallback focus write.
            appState.editorNavigationCommand = nil
            let acceptedWorkspaceGeneration = appState.workspaceGeneration
            appState.workspaceGeneration &+= 1
            sendSmokeReturn(to: host.window)
            XCTAssertNil(appState.editorNavigationCommand)
            try await waitUntil(
                "rejected activation preserves results routing",
                timeoutNanoseconds: 500_000_000
            ) {
                WorkspaceSearchKeyboardSmokeProbe.isResultsFocused
            }
            sendSmokeUpArrow(to: host.window)
            try await waitUntil("rejected activation keeps arrow routing live") {
                WorkspaceSearchKeyboardSmokeProbe.selectedRowID == ordered[1]
            }
            appState.workspaceGeneration = acceptedWorkspaceGeneration

            // Two Escape events delivered synchronously, without yielding to the scheduled
            // results→query task, must still complete results→query→editor.
            let rapidEditorFocusBefore = appState.editorFocusRequestID
            sendSmokeEscape(to: host.window)
            sendSmokeEscape(to: host.window)
            try await waitUntil("second rapid Escape requests editor focus") {
                appState.editorFocusRequestID == rapidEditorFocusBefore + 1
            }
            host.window.makeFirstResponder(nil)
            var stableNonQueryConfirmations = 0
            try await waitUntil("cancelled forced loop does not reclaim query focus") {
                if !WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: host.window) {
                    stableNonQueryConfirmations += 1
                } else {
                    stableNonQueryConfirmations = 0
                }
                return stableNonQueryConfirmations >= 6
            }

            // The invisible results responder participates in the normal key-view loop.
            // Real Tab / Shift-Tab events must leave it instead of being swallowed by
            // `interpretKeyEvents`.
            let keyRouter = try XCTUnwrap(
                findSubview(ofType: WorkspaceSearchKeyRouterView.self, in: host.window.contentView)
            )
            let searchField = try XCTUnwrap(
                WorkspaceSearchFieldFocus.findSearchTextField(in: host.window.contentView)
            )
            try await verifyResultsRouterTraversal(
                host: host,
                appState: appState,
                keyRouter: keyRouter,
                searchField: searchField
            )

        #endif
    }

    @MainActor
    private func verifyHostedNoWrapKeyboardSelection(
        window: NSWindow,
        ordered: [WorkspaceSearchResultRowID]
    ) async throws {
        sendSmokeDownArrow(to: window)
        try await waitUntil("real ↓ moves to second") {
            WorkspaceSearchKeyboardSmokeProbe.selectedRowID == ordered[1]
        }
        sendSmokeDownArrow(to: window)
        try await waitUntil("real ↓ moves to third") {
            WorkspaceSearchKeyboardSmokeProbe.selectedRowID == ordered[2]
        }
        sendSmokeDownArrow(to: window)
        try await waitUntil("real boundary ↓ reaches reducer receipt 4") {
            WorkspaceSearchKeyboardSmokeProbe.reducerSequence == 4
                && WorkspaceSearchKeyboardSmokeProbe.lastReducerAction == .moveDown
        }
        XCTAssertEqual(
            WorkspaceSearchKeyboardSmokeProbe.selectedRowID,
            ordered[2],
            "real ↓ at end must not wrap"
        )

        sendSmokeUpArrow(to: window)
        try await waitUntil("real ↑ moves up from last") {
            WorkspaceSearchKeyboardSmokeProbe.selectedRowID == ordered[1]
        }
        sendSmokeUpArrow(to: window)
        try await waitUntil("real ↑ moves to first") {
            WorkspaceSearchKeyboardSmokeProbe.selectedRowID == ordered[0]
        }
        sendSmokeUpArrow(to: window)
        try await waitUntil("real boundary ↑ reaches reducer receipt 7") {
            WorkspaceSearchKeyboardSmokeProbe.reducerSequence == 7
                && WorkspaceSearchKeyboardSmokeProbe.lastReducerAction == .moveUp
        }
        XCTAssertEqual(
            WorkspaceSearchKeyboardSmokeProbe.selectedRowID,
            ordered[0],
            "real ↑ at start must not wrap"
        )
    }

    @MainActor
    private func verifyResultsRouterTraversal(
        host: SearchSidebarHost,
        appState: AppState,
        keyRouter: WorkspaceSearchKeyRouterView,
        searchField: NSTextField
    ) async throws {
        let container = NSView(frame: host.hostingView.frame)
        host.window.contentView = container
        host.hostingView.frame = container.bounds
        host.hostingView.autoresizingMask = [.width, .height]
        container.addSubview(host.hostingView)

        let backwardResponder = WorkspaceSearchSmokeKeyView(
            frame: NSRect(x: 4, y: 4, width: 40, height: 20)
        )
        let forwardResponder = WorkspaceSearchSmokeKeyView(
            frame: NSRect(x: 48, y: 4, width: 40, height: 20)
        )
        container.addSubview(backwardResponder)
        container.addSubview(forwardResponder)
        let autorecalculatesKeyViewLoop = host.window.autorecalculatesKeyViewLoop
        defer {
            host.window.autorecalculatesKeyViewLoop = autorecalculatesKeyViewLoop
            backwardResponder.removeFromSuperview()
            forwardResponder.removeFromSuperview()
        }
        host.window.autorecalculatesKeyViewLoop = false
        backwardResponder.nextKeyView = keyRouter
        keyRouter.nextKeyView = forwardResponder
        forwardResponder.nextKeyView = backwardResponder

        XCTAssertTrue(host.window.makeFirstResponder(keyRouter))
        sendSmokeTab(to: host.window)
        XCTAssertTrue(
            host.window.firstResponder === forwardResponder,
            "Tab must advance out of the invisible results responder"
        )

        XCTAssertTrue(host.window.makeFirstResponder(keyRouter))
        sendSmokeBacktab(to: host.window)
        XCTAssertTrue(
            host.window.firstResponder === backwardResponder,
            "Shift-Tab must move backward out of the invisible results responder"
        )

        try await verifyTraversalCancelsForcedHandoff(
            host: host,
            keyRouter: keyRouter,
            searchField: searchField,
            forwardResponder: forwardResponder,
            backwardResponder: backwardResponder
        )
        try await verifyQueryFieldTraversalCancelsConfirmedHandoff(
            host: host,
            keyRouter: keyRouter,
            searchField: searchField,
            forwardResponder: forwardResponder,
            backwardResponder: backwardResponder
        )
        backwardResponder.nextKeyView = keyRouter
        keyRouter.nextKeyView = forwardResponder
        forwardResponder.nextKeyView = backwardResponder
        try await verifyExhaustedHandoffRetiresPending(
            host: host,
            appState: appState,
            keyRouter: keyRouter,
            searchField: searchField
        )
        try await verifyQueryChangeRetiresPendingHandoff(
            host: host,
            appState: appState,
            keyRouter: keyRouter,
            searchField: searchField
        )
    }

    @MainActor
    private func verifyTraversalCancelsForcedHandoff(
        host: SearchSidebarHost,
        keyRouter: WorkspaceSearchKeyRouterView,
        searchField: NSTextField,
        forwardResponder: WorkspaceSearchSmokeKeyView,
        backwardResponder: WorkspaceSearchSmokeKeyView
    ) async throws {
        XCTAssertTrue(host.window.makeFirstResponder(keyRouter))
        sendSmokeEscape(to: host.window)
        sendSmokeTab(to: host.window)
        var stableForwardConfirmations = 0
        try await waitUntil("Tab traversal cannot be reclaimed by forced query focus") {
            if host.window.firstResponder === forwardResponder,
               !WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(
                   in: host.window,
                   expectedField: searchField
               )
            {
                stableForwardConfirmations += 1
            } else {
                stableForwardConfirmations = 0
            }
            return stableForwardConfirmations >= 6
        }

        XCTAssertTrue(host.window.makeFirstResponder(keyRouter))
        sendSmokeEscape(to: host.window)
        sendSmokeBacktab(to: host.window)
        var stableBackwardConfirmations = 0
        try await waitUntil("Shift-Tab traversal cannot be reclaimed by forced query focus") {
            if host.window.firstResponder === backwardResponder,
               !WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(
                   in: host.window,
                   expectedField: searchField
               )
            {
                stableBackwardConfirmations += 1
            } else {
                stableBackwardConfirmations = 0
            }
            return stableBackwardConfirmations >= 6
        }
    }

    @MainActor
    private func verifyQueryFieldTraversalCancelsConfirmedHandoff(
        host: SearchSidebarHost,
        keyRouter: WorkspaceSearchKeyRouterView,
        searchField: NSTextField,
        forwardResponder: WorkspaceSearchSmokeKeyView,
        backwardResponder: WorkspaceSearchSmokeKeyView
    ) async throws {
        backwardResponder.nextKeyView = searchField
        searchField.nextKeyView = forwardResponder
        forwardResponder.nextKeyView = backwardResponder

        XCTAssertTrue(host.window.makeFirstResponder(keyRouter))
        sendSmokeEscape(to: host.window)
        try await waitUntil("forced handoff reaches first query confirmation before Tab") {
            WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(
                in: host.window,
                expectedField: searchField
            ) && WorkspaceSearchKeyboardSmokeProbe.isResultsToQueryHandoffPending
        }
        sendSmokeTab(to: host.window)
        try await requireStableFirstResponder(
            forwardResponder,
            excluding: searchField,
            in: host.window,
            description: "Tab after query confirmation cannot be reclaimed"
        )

        XCTAssertTrue(host.window.makeFirstResponder(keyRouter))
        sendSmokeEscape(to: host.window)
        try await waitUntil("forced handoff reaches first query confirmation before Shift-Tab") {
            WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(
                in: host.window,
                expectedField: searchField
            ) && WorkspaceSearchKeyboardSmokeProbe.isResultsToQueryHandoffPending
        }
        sendSmokeBacktab(to: host.window)
        try await requireStableFirstResponder(
            backwardResponder,
            excluding: searchField,
            in: host.window,
            description: "Shift-Tab after query confirmation cannot be reclaimed"
        )
    }

    @MainActor
    private func requireStableFirstResponder(
        _ expectedResponder: NSResponder,
        excluding searchField: NSTextField,
        in window: NSWindow,
        description: String
    ) async throws {
        var stableConfirmations = 0
        try await waitUntil(description) {
            if window.firstResponder === expectedResponder,
               !WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(
                   in: window,
                   expectedField: searchField
               )
            {
                stableConfirmations += 1
            } else {
                stableConfirmations = 0
            }
            return stableConfirmations >= 6
        }
    }

    @MainActor
    private func verifyQueryChangeRetiresPendingHandoff(
        host: SearchSidebarHost,
        appState: AppState,
        keyRouter: WorkspaceSearchKeyRouterView,
        searchField: NSTextField
    ) async throws {
        appState.workspaceSearchFocusKeyWindowCheck = { _ in false }
        appState.refreshWorkspaceSearchFocusKeyRouting()
        XCTAssertTrue(host.window.makeFirstResponder(keyRouter))
        sendSmokeEscape(to: host.window)
        try await waitUntil("generation race forced handoff becomes pending") {
            WorkspaceSearchKeyboardSmokeProbe.isResultsToQueryHandoffPending
        }

        let previousGeneration = appState.workspaceSearchState.queryGeneration
        let cancellationCheckBeforeGeneration =
            WorkspaceSearchKeyboardSmokeProbe.handoffCancellationCheckSequence
        let cancellationBeforeGeneration =
            WorkspaceSearchKeyboardSmokeProbe.handoffCancellationSequence
        appState.updateWorkspaceSearchQueryText("needle updated")
        try await waitUntil(
            "query generation causally cancels pending forced handoff",
            timeoutNanoseconds: 500_000_000
        ) {
            appState.workspaceSearchState.queryGeneration > previousGeneration
                && WorkspaceSearchKeyboardSmokeProbe.handoffCancellationCheckSequence
                == cancellationCheckBeforeGeneration + 1
                && WorkspaceSearchKeyboardSmokeProbe.handoffCancellationSequence
                == cancellationBeforeGeneration + 1
                && !WorkspaceSearchKeyboardSmokeProbe.isResultsToQueryHandoffPending
        }

        installDesignatedKeyWindowRouting(on: appState, designatedKeyWindow: host.window)
        XCTAssertTrue(host.window.makeFirstResponder(keyRouter))
        let editorFocusBeforeRetry = appState.editorFocusRequestID
        sendSmokeEscape(to: host.window)
        try await waitUntil("post-generation Escape returns to Search") {
            WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(
                in: host.window,
                expectedField: searchField
            )
        }
        try await waitUntil("post-generation replacement handoff completes") {
            !WorkspaceSearchKeyboardSmokeProbe.isResultsToQueryHandoffPending
        }
        XCTAssertEqual(appState.editorFocusRequestID, editorFocusBeforeRetry)

        try await verifyQueryGenerationPreservesRequestedFocus(
            host: host,
            appState: appState,
            searchField: searchField
        )

        appState.workspaceSearchFocusKeyWindowCheck = { _ in false }
        appState.refreshWorkspaceSearchFocusKeyRouting()
        XCTAssertTrue(host.window.makeFirstResponder(keyRouter))
        sendSmokeEscape(to: host.window)
        try await waitUntil("clear-query race forced handoff becomes pending") {
            WorkspaceSearchKeyboardSmokeProbe.isResultsToQueryHandoffPending
        }
        let cancellationCheckBeforeClear =
            WorkspaceSearchKeyboardSmokeProbe.handoffCancellationCheckSequence
        let cancellationBeforeClear =
            WorkspaceSearchKeyboardSmokeProbe.handoffCancellationSequence
        appState.updateWorkspaceSearchQueryText("")
        try await waitUntil(
            "clear query causally cancels pending forced handoff",
            timeoutNanoseconds: 500_000_000
        ) {
            appState.workspaceSearchUI.queryText.isEmpty
                && WorkspaceSearchKeyboardSmokeProbe.handoffCancellationCheckSequence
                == cancellationCheckBeforeClear + 1
                && WorkspaceSearchKeyboardSmokeProbe.handoffCancellationSequence
                == cancellationBeforeClear + 1
                && !WorkspaceSearchKeyboardSmokeProbe.isResultsToQueryHandoffPending
        }
    }

    @MainActor
    private func verifyQueryGenerationPreservesRequestedFocus(
        host: SearchSidebarHost,
        appState: AppState,
        searchField: NSTextField
    ) async throws {
        appState.workspaceSearchFocusKeyWindowCheck = { _ in false }
        appState.refreshWorkspaceSearchFocusKeyRouting()
        host.window.makeFirstResponder(nil)

        let focusAttemptBefore =
            WorkspaceSearchKeyboardSmokeProbe.requestedFocusAttemptSequence
        appState.focusWorkspaceSearch()
        let focusRequest = appState.workspaceSearchUI.focusRequestID
        try await waitUntil("ineligible shortcut installs requested focus retry") {
            WorkspaceSearchKeyboardSmokeProbe.requestedFocusAttemptSequence > focusAttemptBefore
                && appState.workspaceSearchUI.focusAppliedID != focusRequest
        }

        let cancellationCheckBeforeGeneration =
            WorkspaceSearchKeyboardSmokeProbe.handoffCancellationCheckSequence
        let cancellationBeforeGeneration =
            WorkspaceSearchKeyboardSmokeProbe.handoffCancellationSequence
        let previousGeneration = appState.workspaceSearchState.queryGeneration
        appState.updateWorkspaceSearchQueryText("needle shortcut")
        try await waitUntil(
            "shortcut-time generation does not cancel requested retry",
            timeoutNanoseconds: 500_000_000
        ) {
            appState.workspaceSearchState.queryGeneration > previousGeneration
                && WorkspaceSearchKeyboardSmokeProbe.handoffCancellationCheckSequence
                == cancellationCheckBeforeGeneration + 1
                && WorkspaceSearchKeyboardSmokeProbe.handoffCancellationSequence
                == cancellationBeforeGeneration
        }

        // Do not publish a key-routing epoch: the already-running requested retry must observe
        // eligibility live and finish without a replacement schedule.
        appState.workspaceSearchFocusKeyWindowCheck = { $0 === host.window }
        try await waitUntil(
            "requested shortcut retry survives query generation",
            timeoutNanoseconds: 1_000_000_000
        ) {
            appState.workspaceSearchUI.focusAppliedID == focusRequest
                && WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(
                    in: host.window,
                    expectedField: searchField
                )
        }
    }

    @MainActor
    private func verifyExhaustedHandoffRetiresPending(
        host: SearchSidebarHost,
        appState: AppState,
        keyRouter: WorkspaceSearchKeyRouterView,
        searchField: NSTextField
    ) async throws {
        appState.workspaceSearchFocusKeyWindowCheck = { _ in false }
        appState.refreshWorkspaceSearchFocusKeyRouting()
        XCTAssertTrue(host.window.makeFirstResponder(keyRouter))
        sendSmokeEscape(to: host.window)
        try await waitUntil("ineligible forced handoff becomes pending") {
            WorkspaceSearchKeyboardSmokeProbe.isResultsToQueryHandoffPending
        }
        try await waitUntil(
            "exhausted forced handoff retires pending intent",
            timeoutNanoseconds: 5_000_000_000
        ) {
            !WorkspaceSearchKeyboardSmokeProbe.isResultsToQueryHandoffPending
        }

        installDesignatedKeyWindowRouting(on: appState, designatedKeyWindow: host.window)
        XCTAssertTrue(host.window.makeFirstResponder(keyRouter))
        let editorFocusBeforeRetry = appState.editorFocusRequestID
        sendSmokeEscape(to: host.window)
        try await waitUntil("post-exhaustion Escape returns to Search") {
            WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(
                in: host.window,
                expectedField: searchField
            )
        }
        try await waitUntil("post-exhaustion replacement handoff completes") {
            !WorkspaceSearchKeyboardSmokeProbe.isResultsToQueryHandoffPending
        }
        XCTAssertEqual(appState.editorFocusRequestID, editorFocusBeforeRetry)
    }

    @MainActor
    private func sendSmokeDownArrow(to window: NSWindow) {
        sendSmokeKeyEvent(keyCode: 125, characters: String(UnicodeScalar(0xF701)!), to: window)
    }

    @MainActor
    private func sendSmokeUpArrow(to window: NSWindow) {
        sendSmokeKeyEvent(keyCode: 126, characters: String(UnicodeScalar(0xF700)!), to: window)
    }

    @MainActor
    private func sendSmokeReturn(to window: NSWindow) {
        sendSmokeKeyEvent(keyCode: 36, characters: "\r", to: window)
    }

    @MainActor
    private func sendSmokeEscape(to window: NSWindow) {
        sendSmokeKeyEvent(keyCode: 53, characters: "\u{1B}", to: window)
    }

    @MainActor
    private func sendSmokeTab(to window: NSWindow) {
        sendSmokeKeyEvent(keyCode: 48, characters: "\t", to: window)
    }

    @MainActor
    private func sendSmokeBacktab(to window: NSWindow) {
        sendSmokeKeyEvent(
            keyCode: 48,
            characters: "\u{19}",
            charactersIgnoringModifiers: "\u{19}",
            modifierFlags: .shift,
            to: window
        )
    }

    /// Sends a synthesized keyDown + keyUp pair through `window.sendEvent`, exactly as the
    /// responder chain would receive a physical key press.
    @MainActor
    private func sendSmokeKeyEvent(
        keyCode: UInt16,
        characters: String,
        charactersIgnoringModifiers: String? = nil,
        modifierFlags: NSEvent.ModifierFlags = [],
        to window: NSWindow
    ) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: NSPoint(x: 5, y: 5),
                modifierFlags: modifierFlags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
                isARepeat: false,
                keyCode: keyCode
            ) else {
                XCTFail("Could not synthesize key event for keyCode \(keyCode)")
                return
            }
            window.sendEvent(event)
        }
    }

    @MainActor
    private func sendSmokeClick(at windowPoint: NSPoint, to window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else {
                XCTFail("Could not synthesize mouse event")
                return
            }
            window.sendEvent(event)
        }
    }

    @MainActor
    private func findSubview<ViewType: NSView>(
        ofType type: ViewType.Type,
        in root: NSView?
    ) -> ViewType? {
        guard let root else { return nil }
        if let match = root as? ViewType { return match }
        for subview in root.subviews {
            if let found = findSubview(ofType: type, in: subview) {
                return found
            }
        }
        return nil
    }

    func testFocusWorkspaceSearchDisabledWithoutFolderWorkspace() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        XCTAssertFalse(appState.canUseWorkspaceSearch)
        XCTAssertEqual(appState.workspaceSearchUI.mode, .files)
        XCTAssertEqual(appState.workspaceSearchUI.focusRequestID, 0)

        appState.focusWorkspaceSearch()
        XCTAssertEqual(appState.workspaceSearchUI.mode, .files)
        XCTAssertEqual(appState.workspaceSearchUI.focusRequestID, 0)

        appState.selectWorkspaceSidebarMode(.search)
        XCTAssertEqual(appState.workspaceSearchUI.mode, .files)
    }

    func testSingleFileModeCannotStartWorkspaceSearchFromUI() throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsong-single-\(UUID().uuidString).md")
        try "needle body".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let session = DocumentSession(text: "needle body", url: fileURL, fileKind: .markdown)
        let appState = AppState(
            currentDocument: session,
            workspaceSearchStreamProvider: provider,
            workspaceSearchDebounceNanoseconds: 0,
            shouldRestoreLastOpenedFile: false
        )
        XCTAssertNil(appState.workspaceRootURL)
        XCTAssertFalse(appState.canUseWorkspaceSearch)
        XCTAssertFalse(appState.isWorkspaceSearchReady)

        appState.updateWorkspaceSearchQueryText("needle")
        XCTAssertEqual(appState.workspaceSearchUI.queryText, "needle")
        XCTAssertNil(appState.workspaceSearchUI.pendingResumeGeneration)
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertEqual(appState.workspaceSearchState.phase, .idle)
        XCTAssertNil(appState.workspaceSearchState.activeQuery)
    }

    func testQueryTypedDuringOpenScanResumesOnceWhenScanCompletes() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try "needle body".write(
            to: rootURL.appendingPathComponent("a.md"),
            atomically: true,
            encoding: .utf8
        )

        let scanner = ControlledWorkspaceDirectoryScanner()
        let provider = ControlledWorkspaceSearchStreamProvider()
        let appState = AppState(
            directoryScanner: scanner,
            workspaceSearchStreamProvider: provider,
            workspaceSearchDebounceNanoseconds: 0,
            shouldRestoreLastOpenedFile: false
        )

        appState.openExternalFile(rootURL)
        await scanner.waitForRequestCount(1)
        XCTAssertTrue(appState.canUseWorkspaceSearch)
        XCTAssertFalse(appState.isWorkspaceSearchReady)
        let pendingGeneration = appState.workspaceGeneration
        XCTAssertGreaterThan(pendingGeneration, 0)

        appState.updateWorkspaceSearchQueryText("needle")
        XCTAssertEqual(appState.workspaceSearchUI.queryText, "needle")
        XCTAssertEqual(appState.workspaceSearchUI.pendingResumeGeneration, pendingGeneration)
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertEqual(appState.workspaceSearchState.phase, .idle)
        XCTAssertNil(appState.workspaceSearchState.activeQuery)

        await scanner.completeRequest(at: 0, with: WorkspaceFileSnapshot(entries: [
            WorkspaceFileSnapshot.Entry(
                relativePath: "a.md",
                kind: .markdown,
                identity: "id:a.md",
                contentModificationDate: nil
            ),
        ]))
        try await waitUntil("pending open-scan query starts exactly once after install") {
            provider.requests.count == 1 && appState.isWorkspaceSearchReady
        }
        XCTAssertEqual(provider.requests[0].query.pattern, "needle")
        XCTAssertEqual(provider.requests[0].query.caseSensitivity, .smart)
        XCTAssertNil(appState.workspaceSearchUI.pendingResumeGeneration)
        XCTAssertEqual(appState.workspaceSearchState.activeQuery?.pattern, "needle")

        // A later ordinary reload (FSEvent-style) refreshes the query that actually ran, but
        // only after the replacement snapshot and authority install.
        let requestCountAfterPendingResume = provider.requests.count
        appState.refreshWorkspaceAfterFileSystemChange()
        await scanner.waitForRequestCount(2)
        XCTAssertEqual(provider.requests.count, requestCountAfterPendingResume)
        await scanner.completeRequest(at: 1, with: WorkspaceFileSnapshot(entries: [
            WorkspaceFileSnapshot.Entry(
                relativePath: "a.md",
                kind: .markdown,
                identity: "id:a.md",
                contentModificationDate: nil
            ),
        ]))
        try await waitUntil("second snapshot installs") {
            appState.workspaceInstalledCaptureGeneration == appState.workspaceGeneration
                && appState.isWorkspaceSearchReady
        }
        try await waitUntil("active query refreshes after second snapshot install") {
            provider.requests.count == requestCountAfterPendingResume + 1
        }
        XCTAssertEqual(provider.requests.last?.query.pattern, "needle")
        XCTAssertNil(appState.workspaceSearchUI.pendingResumeGeneration)
        XCTAssertEqual(appState.workspaceSearchState.activeQuery?.pattern, "needle")
        XCTAssertEqual(appState.workspaceSearchUI.queryText, "needle")

        // Clearing the active search while leaving a non-empty field proves UI text alone does
        // not arm another automatic refresh.
        appState.clearWorkspaceSearch()
        let requestCountAfterClear = provider.requests.count
        appState.refreshWorkspaceAfterFileSystemChange()
        await scanner.waitForRequestCount(3)
        await scanner.completeRequest(at: 2, with: WorkspaceFileSnapshot(entries: [
            WorkspaceFileSnapshot.Entry(
                relativePath: "a.md",
                kind: .markdown,
                identity: "id:a.md",
                contentModificationDate: nil
            ),
        ]))
        try await waitUntil("inactive-query snapshot installs") {
            appState.workspaceInstalledCaptureGeneration == appState.workspaceGeneration
                && appState.isWorkspaceSearchReady
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(provider.requests.count, requestCountAfterClear)
        XCTAssertNil(appState.workspaceSearchState.activeQuery)
        XCTAssertEqual(appState.workspaceSearchUI.queryText, "needle")
    }

    func testSearchUIMapsCaseAndWholeWordOntoTextSearchQuery() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "Hello hello"],
            debounceNanoseconds: 0
        )
        defer { cleanUp(fixture) }

        // Default smart case + no whole word
        fixture.appState.updateWorkspaceSearchQueryText("hello")
        try await waitUntil("smart-case request starts") { provider.requests.count == 1 }
        XCTAssertEqual(provider.requests[0].query.pattern, "hello")
        XCTAssertEqual(provider.requests[0].query.caseSensitivity, .smart)
        XCTAssertFalse(provider.requests[0].query.wholeWord)

        // Aa forces sensitive
        fixture.appState.setWorkspaceSearchMatchCase(true)
        try await waitUntil("match-case request starts") { provider.requests.count == 2 }
        XCTAssertEqual(provider.requests[1].query.caseSensitivity, .sensitive)
        XCTAssertEqual(provider.requests[1].query.pattern, "hello")
        XCTAssertFalse(provider.requests[1].query.wholeWord)

        // Whole word independent toggle
        fixture.appState.setWorkspaceSearchWholeWord(true)
        try await waitUntil("whole-word request starts") { provider.requests.count == 3 }
        XCTAssertEqual(provider.requests[2].query.caseSensitivity, .sensitive)
        XCTAssertTrue(provider.requests[2].query.wholeWord)

        // Turning Aa off restores smart case while keeping whole word
        fixture.appState.setWorkspaceSearchMatchCase(false)
        try await waitUntil("smart-case restore request starts") { provider.requests.count == 4 }
        XCTAssertEqual(provider.requests[3].query.caseSensitivity, .smart)
        XCTAssertTrue(provider.requests[3].query.wholeWord)

        var ui = WorkspaceSearchUIState(queryText: "AbC", matchCase: false, wholeWord: true)
        XCTAssertEqual(
            ui.makeTextSearchQuery(),
            TextSearchQuery(pattern: "AbC", caseSensitivity: .smart, wholeWord: true)
        )
        ui.matchCase = true
        XCTAssertEqual(
            ui.makeTextSearchQuery(),
            TextSearchQuery(pattern: "AbC", caseSensitivity: .sensitive, wholeWord: true)
        )
    }

    func testEmptySearchUIQueryClearsActiveSearchWithoutDestroyingMode() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "alpha"],
            debounceNanoseconds: 0
        )
        defer { cleanUp(fixture) }

        fixture.appState.focusWorkspaceSearch()
        fixture.appState.updateWorkspaceSearchQueryText("alpha")
        try await waitUntil("search starts") { provider.requests.count == 1 }
        XCTAssertEqual(fixture.appState.workspaceSearchUI.mode, .search)

        fixture.appState.updateWorkspaceSearchQueryText("")
        XCTAssertEqual(fixture.appState.workspaceSearchUI.queryText, "")
        XCTAssertEqual(fixture.appState.workspaceSearchUI.mode, .search)
        XCTAssertEqual(fixture.appState.workspaceSearchState.phase, .idle)
        XCTAssertNil(fixture.appState.workspaceSearchState.activeQuery)
        XCTAssertTrue(fixture.appState.workspaceSearchState.fileResults.isEmpty)
    }

    func testSwitchingToFilesKeepsValidSearchResultsAndQuery() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "alpha"],
            debounceNanoseconds: 0
        )
        defer { cleanUp(fixture) }

        fixture.appState.focusWorkspaceSearch()
        fixture.appState.updateWorkspaceSearchQueryText("alpha")
        try await waitUntil("search starts") { provider.requests.count == 1 }
        let request = provider.requests[0]
        provider.yield(
            .fileResult(context(for: request), result(path: "a.md", text: "alpha", needle: "alpha")),
            to: 0
        )
        provider.yield(
            .completed(
                context(for: request),
                summary(candidateFileCount: 1, searchedFileCount: 1, totalMatchCount: 1)
            ),
            to: 0
        )
        try await waitUntil("result applies") {
            fixture.appState.workspaceSearchState.phase == .completed
                && fixture.appState.workspaceSearchState.fileResults.count == 1
        }

        fixture.appState.selectWorkspaceSidebarMode(.files)
        XCTAssertEqual(fixture.appState.workspaceSearchUI.mode, .files)
        XCTAssertEqual(fixture.appState.workspaceSearchUI.queryText, "alpha")
        XCTAssertEqual(fixture.appState.workspaceSearchState.phase, .completed)
        XCTAssertEqual(fixture.appState.workspaceSearchState.fileResults.map(\.relativePath), ["a.md"])
    }

    func testWorkspaceCloseClearsSearchUIQueryResultsAndMode() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "alpha"],
            debounceNanoseconds: 0
        )
        defer { cleanUp(fixture) }

        fixture.appState.focusWorkspaceSearch()
        let focusBeforeClose = fixture.appState.workspaceSearchUI.focusRequestID
        fixture.appState.markWorkspaceSearchFocusApplied(focusBeforeClose)
        fixture.appState.updateWorkspaceSearchQueryText("alpha")
        fixture.appState.setWorkspaceSearchMatchCase(true)
        fixture.appState.setWorkspaceSearchWholeWord(true)
        try await waitUntil("search starts") { provider.requests.count == 1 }

        fixture.appState.closeWorkspace()

        XCTAssertNil(fixture.appState.workspaceRootURL)
        XCTAssertFalse(fixture.appState.canUseWorkspaceSearch)
        XCTAssertEqual(fixture.appState.workspaceSearchUI.mode, .files)
        XCTAssertEqual(fixture.appState.workspaceSearchUI.queryText, "")
        XCTAssertFalse(fixture.appState.workspaceSearchUI.matchCase)
        XCTAssertFalse(fixture.appState.workspaceSearchUI.wholeWord)
        // Request id is preserved but marked applied so picker/reopen cannot replay it.
        XCTAssertEqual(fixture.appState.workspaceSearchUI.focusRequestID, focusBeforeClose)
        XCTAssertEqual(fixture.appState.workspaceSearchUI.focusAppliedID, focusBeforeClose)
        XCTAssertNil(fixture.appState.workspaceSearchUI.pendingResumeGeneration)
        XCTAssertEqual(fixture.appState.workspaceSearchState.phase, .idle)
        XCTAssertTrue(fixture.appState.workspaceSearchState.fileResults.isEmpty)
    }

    func testRapidUIQueryChangesStillUseDebounceAndLatestQueryContract() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "first second third"],
            debounceNanoseconds: 50_000_000
        )
        defer { cleanUp(fixture) }

        fixture.appState.updateWorkspaceSearchQueryText("first")
        fixture.appState.updateWorkspaceSearchQueryText("second")
        fixture.appState.setWorkspaceSearchWholeWord(true)
        fixture.appState.updateWorkspaceSearchQueryText("third")

        try await waitUntil("latest debounced UI query starts") { provider.requests.count == 1 }
        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(request.query.pattern, "third")
        XCTAssertEqual(request.query.caseSensitivity, .smart)
        XCTAssertTrue(request.query.wholeWord)
        // first → second → whole-word retarget of second → third
        XCTAssertEqual(request.queryGeneration, 4)
        XCTAssertEqual(fixture.appState.workspaceSearchState.activeQuery?.pattern, "third")
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
        appState.retainUnanchoredManagedSessionOwnership(for: warm)

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
        let fileResult = result(
            path: "b.md",
            text: "before needle after",
            needle: "needle",
            rootURL: fixture.rootURL
        )
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

    // swiftlint:disable:next function_body_length
    func testDirtyOverlaySearchActivationArbitratesSameInodeRewriteBeforeAdoptingProof() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let diskA = "disk A"
        let localOverlay = "local needle"
        let diskB = "disk B"
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": diskA],
            currentPath: "a.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let session = appState.currentDocument
        let sessionIdentity = ObjectIdentifier(session)
        let documentURL = fixture.rootURL.appendingPathComponent("a.md")
        let originalBinding = try XCTUnwrap(appState.anchoredSessionFileBinding(for: session))

        appState.replaceDocumentText(localOverlay, in: session)
        let pendingAutosave = try XCTUnwrap(appState.autosaveTask)
        appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "needle"))
        try await waitUntil("dirty-overlay search starts") { provider.requests.count == 1 }
        let request = provider.requests[0]

        let handle = try FileHandle(forWritingTo: documentURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(diskB.utf8))
        try handle.synchronize()
        try handle.close()
        let rewrittenIdentity = try regularIdentity(at: documentURL)
        XCTAssertEqual(rewrittenIdentity, originalBinding.identity, "test setup must retain the inode")

        let fileResult = result(
            path: "a.md",
            text: localOverlay,
            needle: "needle",
            rootURL: fixture.rootURL
        )
        let match = try XCTUnwrap(fileResult.matches.first)
        provider.yield(.fileResult(context(for: request), fileResult), to: 0)
        try await waitUntil("dirty-overlay result applies") {
            appState.workspaceSearchState.fileResults == [fileResult]
        }
        let olderNavigation = seedOlderPendingNavigation(in: appState)

        appState.activateWorkspaceSearchResult(
            context: context(for: request),
            fileResult: fileResult,
            match: match
        )

        XCTAssertTrue(appState.currentDocument === session)
        XCTAssertEqual(session.text, localOverlay)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: session), originalBinding)
        XCTAssertEqual(appState.pendingExternalTexts[documentURL], diskB)
        let observedB = try XCTUnwrap(appState.pendingExternalFileVersions[documentURL])
        XCTAssertEqual(observedB.location, originalBinding.location)
        XCTAssertEqual(observedB.identity, originalBinding.identity)
        XCTAssertEqual(observedB.file.text, diskB)
        XCTAssertNotEqual(observedB.sha256Digest, originalBinding.sha256Digest)
        XCTAssertEqual(appState.externalChangePrompt?.fileURL, documentURL)
        XCTAssertEqual(appState.editorNavigationCommand, .navigate(olderNavigation))
        XCTAssertTrue(pendingAutosave.isCancelled)
        XCTAssertNil(appState.autosaveTask)
        XCTAssertNil(appState.sessionAutosaveTasks[sessionIdentity])
        XCTAssertFalse(appState.canAutosave(session: session))
        XCTAssertThrowsError(try appState.save(session: session))
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), diskB)
    }

    // swiftlint:disable:next function_body_length
    func testPendingEditorSourceSearchActivationPreservesSourceAndAProofOnSameInodeRewrite() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let sourceA = "alpha needle"
        let diskB = "disk B"
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": sourceA],
            currentPath: "a.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let session = appState.currentDocument
        let documentURL = fixture.rootURL.appendingPathComponent("a.md")
        let originalBinding = try XCTUnwrap(appState.anchoredSessionFileBinding(for: session))
        let binding = appState.editorDocumentBinding(for: session)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        let sourceSnapshot = binding.sourceContract.snapshot()
        XCTAssertEqual(
            binding.sourceContract.writer(.activate(installation, from: sourceSnapshot)),
            .activated(sourceSnapshot)
        )
        binding.sourceContract.pendingSource(.began(installation))
        defer {
            binding.sourceContract.pendingSource(.abandoned(installation))
            binding.onLifecycle(.revoked(installation))
        }
        XCTAssertFalse(session.isDirty)
        XCTAssertTrue(appState.hasPendingEditorSource(for: session))

        appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "needle"))
        try await waitUntil("pending-source search starts") { provider.requests.count == 1 }
        let request = provider.requests[0]
        let fileResult = result(
            path: "a.md",
            text: sourceA,
            needle: "needle",
            rootURL: fixture.rootURL
        )
        let match = try XCTUnwrap(fileResult.matches.first)
        provider.yield(.fileResult(context(for: request), fileResult), to: 0)
        try await waitUntil("pending-source result applies") {
            appState.workspaceSearchState.fileResults == [fileResult]
        }

        let handle = try FileHandle(forWritingTo: documentURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(diskB.utf8))
        try handle.synchronize()
        try handle.close()
        XCTAssertEqual(try regularIdentity(at: documentURL), originalBinding.identity)
        let olderNavigation = seedOlderPendingNavigation(in: appState)

        appState.activateWorkspaceSearchResult(
            context: context(for: request),
            fileResult: fileResult,
            match: match
        )

        XCTAssertEqual(session.text, sourceA)
        XCTAssertFalse(session.isDirty)
        XCTAssertTrue(appState.hasPendingEditorSource(for: session))
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: session), originalBinding)
        XCTAssertEqual(appState.pendingExternalTexts[documentURL], diskB)
        XCTAssertEqual(appState.pendingExternalFileVersions[documentURL]?.file.text, diskB)
        XCTAssertEqual(appState.externalChangePrompt?.fileURL, documentURL)
        XCTAssertEqual(appState.editorNavigationCommand, .navigate(olderNavigation))
        XCTAssertFalse(appState.canAutosave(session: session))
        XCTAssertThrowsError(try appState.save(session: session))
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), diskB)
    }

    // swiftlint:disable:next function_body_length
    func testSearchObservationEvictsOlderDiskInspectionBeforeAdoptingNewerVersion() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let reader = ControlledCoherentFileReader()
        let sourceA = "source A"
        let sourceB = "source B needle"
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": sourceA],
            currentPath: "a.md",
            coherentFileReader: reader
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let session = appState.currentDocument
        let sessionIdentity = ObjectIdentifier(session)
        let documentURL = fixture.rootURL.appendingPathComponent("a.md")
        let originalIdentity = try regularIdentity(at: documentURL)

        appState.handleExternalChange(for: session)
        try await waitUntil("older disk inspection starts") { reader.requestCount == 1 }
        let olderInspection = try XCTUnwrap(
            appState.externalDiskInspectionTasks[sessionIdentity]
        )
        let olderGeneration = olderInspection.diskEventGeneration

        let handle = try FileHandle(forWritingTo: documentURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(sourceB.utf8))
        try handle.synchronize()
        try handle.close()
        XCTAssertEqual(try regularIdentity(at: documentURL), originalIdentity)

        appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "needle"))
        try await waitUntil("newer-version search starts") { provider.requests.count == 1 }
        let request = provider.requests[0]
        let fileResult = result(
            path: "a.md",
            text: sourceB,
            needle: "needle",
            rootURL: fixture.rootURL
        )
        let match = try XCTUnwrap(fileResult.matches.first)
        provider.yield(.fileResult(context(for: request), fileResult), to: 0)
        try await waitUntil("newer-version result applies") {
            appState.workspaceSearchState.fileResults == [fileResult]
        }

        appState.activateWorkspaceSearchResult(
            context: context(for: request),
            fileResult: fileResult,
            match: match
        )

        XCTAssertEqual(session.text, sourceB)
        XCTAssertFalse(session.isDirty)
        XCTAssertNil(appState.externalDiskInspectionTasks[sessionIdentity])
        XCTAssertEqual(
            appState.currentExternalDiskEventGeneration(for: session),
            olderGeneration + 1,
            "one coherent search observation must advance the generation exactly once"
        )
        reader.resolve(
            request: 0,
            with: .loaded(coherentSnapshot(text: sourceA, identity: originalIdentity))
        )
        await olderInspection.task.value

        XCTAssertEqual(session.text, sourceB)
        XCTAssertNil(appState.pendingExternalTexts[documentURL])
        XCTAssertNil(appState.pendingExternalFileVersions[documentURL])
        XCTAssertEqual(
            appState.anchoredSessionFileBinding(for: session)?.sha256Digest,
            WorkspaceSearchContentFingerprint(text: sourceB).sha256Digest
        )
        XCTAssertEqual(appState.lastKnownDiskHashes[documentURL], AppState.contentHash(sourceB))
    }

    // swiftlint:disable:next function_body_length
    func testFingerprintMismatchSearchObservationAdoptsNewestCleanVersionAndEvictsOlderInspection() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let reader = ControlledCoherentFileReader()
        let resultSource = "source B needle"
        let observedSource = "source C"
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": resultSource],
            currentPath: "a.md",
            coherentFileReader: reader
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let session = appState.currentDocument
        let sessionIdentity = ObjectIdentifier(session)
        let documentURL = fixture.rootURL.appendingPathComponent("a.md")
        let originalBinding = try XCTUnwrap(appState.anchoredSessionFileBinding(for: session))

        appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "needle"))
        try await waitUntil("fingerprint-mismatch search starts") { provider.requests.count == 1 }
        let request = provider.requests[0]
        let fileResult = result(
            path: "a.md",
            text: resultSource,
            needle: "needle",
            rootURL: fixture.rootURL
        )
        let match = try XCTUnwrap(fileResult.matches.first)
        provider.yield(.fileResult(context(for: request), fileResult), to: 0)
        try await waitUntil("fingerprint-mismatch result applies") {
            appState.workspaceSearchState.fileResults == [fileResult]
        }

        appState.handleExternalChange(for: session)
        try await waitUntil("older fingerprint-mismatch inspection starts") {
            reader.requestCount == 1
        }
        let olderInspection = try XCTUnwrap(
            appState.externalDiskInspectionTasks[sessionIdentity]
        )
        let olderGeneration = olderInspection.diskEventGeneration

        let handle = try FileHandle(forWritingTo: documentURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(observedSource.utf8))
        try handle.synchronize()
        try handle.close()
        XCTAssertEqual(try regularIdentity(at: documentURL), originalBinding.identity)
        let olderNavigation = seedOlderPendingNavigation(in: appState)

        appState.activateWorkspaceSearchResult(
            context: context(for: request),
            fileResult: fileResult,
            match: match
        )

        XCTAssertEqual(session.text, observedSource)
        XCTAssertFalse(session.isDirty)
        let observedBinding = try XCTUnwrap(appState.anchoredSessionFileBinding(for: session))
        XCTAssertEqual(observedBinding.location, originalBinding.location)
        XCTAssertEqual(observedBinding.identity, originalBinding.identity)
        XCTAssertEqual(
            observedBinding.sha256Digest,
            WorkspaceSearchContentFingerprint(text: observedSource).sha256Digest
        )
        XCTAssertNil(appState.externalDiskInspectionTasks[sessionIdentity])
        XCTAssertEqual(
            appState.currentExternalDiskEventGeneration(for: session),
            olderGeneration + 1
        )
        XCTAssertNil(appState.pendingExternalTexts[documentURL])
        XCTAssertNil(appState.pendingExternalFileVersions[documentURL])
        XCTAssertEqual(appState.editorNavigationCommand, .navigate(olderNavigation))
        XCTAssertEqual(
            appState.lastKnownDiskHashes[documentURL],
            AppState.contentHash(observedSource)
        )

        reader.resolve(
            request: 0,
            with: .loaded(coherentSnapshot(
                text: "stale inspection",
                identity: originalBinding.identity
            ))
        )
        await olderInspection.task.value

        XCTAssertEqual(session.text, observedSource)
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: session), observedBinding)
        XCTAssertNil(appState.pendingExternalTexts[documentURL])
        XCTAssertNil(appState.pendingExternalFileVersions[documentURL])
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), observedSource)
    }

    // swiftlint:disable:next function_body_length
    func testInvalidRangeSearchObservationAdoptsNewestCleanVersionBeforeRejectingNavigation() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let reader = ControlledCoherentFileReader()
        let sourceA = "source A"
        let observedSource = "source C needle"
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": sourceA],
            currentPath: "a.md",
            coherentFileReader: reader
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let session = appState.currentDocument
        let sessionIdentity = ObjectIdentifier(session)
        let documentURL = fixture.rootURL.appendingPathComponent("a.md")
        let originalBinding = try XCTUnwrap(appState.anchoredSessionFileBinding(for: session))

        appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "needle"))
        try await waitUntil("invalid-range search starts") { provider.requests.count == 1 }
        let request = provider.requests[0]
        let validResult = result(
            path: "a.md",
            text: observedSource,
            needle: "needle",
            rootURL: fixture.rootURL
        )
        let previewRange = (observedSource as NSString).range(of: "needle")
        let invalidMatch = TextSearchMatch(
            range: NSRange(location: 999, length: 1),
            line: 1,
            preview: observedSource,
            previewMatchRange: previewRange
        )
        let fileResult = WorkspaceSearchFileResult(
            relativePath: validResult.relativePath,
            contentFingerprint: validResult.contentFingerprint,
            matches: [invalidMatch],
            isTruncated: validResult.isTruncated,
            fileAuthority: validResult.fileAuthority
        )
        provider.yield(.fileResult(context(for: request), fileResult), to: 0)
        try await waitUntil("invalid-range result applies") {
            appState.workspaceSearchState.fileResults == [fileResult]
        }

        appState.handleExternalChange(for: session)
        try await waitUntil("older invalid-range inspection starts") {
            reader.requestCount == 1
        }
        let olderInspection = try XCTUnwrap(
            appState.externalDiskInspectionTasks[sessionIdentity]
        )
        let olderGeneration = olderInspection.diskEventGeneration

        let handle = try FileHandle(forWritingTo: documentURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(observedSource.utf8))
        try handle.synchronize()
        try handle.close()
        XCTAssertEqual(try regularIdentity(at: documentURL), originalBinding.identity)
        let olderNavigation = seedOlderPendingNavigation(in: appState)

        appState.activateWorkspaceSearchResult(
            context: context(for: request),
            fileResult: fileResult,
            match: invalidMatch
        )

        XCTAssertEqual(session.text, observedSource)
        XCTAssertFalse(session.isDirty)
        let observedBinding = try XCTUnwrap(appState.anchoredSessionFileBinding(for: session))
        XCTAssertEqual(observedBinding.location, originalBinding.location)
        XCTAssertEqual(observedBinding.identity, originalBinding.identity)
        XCTAssertEqual(
            observedBinding.sha256Digest,
            WorkspaceSearchContentFingerprint(text: observedSource).sha256Digest
        )
        XCTAssertEqual(
            appState.currentExternalDiskEventGeneration(for: session),
            olderGeneration + 1
        )
        XCTAssertNil(appState.externalDiskInspectionTasks[sessionIdentity])
        XCTAssertEqual(appState.editorNavigationCommand, .navigate(olderNavigation))

        reader.resolve(
            request: 0,
            with: .loaded(coherentSnapshot(text: sourceA, identity: originalBinding.identity))
        )
        await olderInspection.task.value

        XCTAssertEqual(session.text, observedSource)
        XCTAssertEqual(appState.anchoredSessionFileBinding(for: session), observedBinding)
        XCTAssertNil(appState.pendingExternalTexts[documentURL])
        XCTAssertNil(appState.pendingExternalFileVersions[documentURL])
        XCTAssertNil(appState.externalChangePrompt)
    }

    // swiftlint:disable:next function_body_length
    func testRejectedSearchObservationLetsCleanReusableRetirementFinishAfterSupersession() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let reader = ControlledCoherentFileReader()
        let sourceA = "current source"
        let resultSource = "retired B needle"
        let observedSource = "retired C"
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": sourceA, "b.md": resultSource],
            currentPath: "a.md",
            coherentFileReader: reader
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let currentSession = appState.currentDocument
        let retiredURL = fixture.rootURL.appendingPathComponent("b.md")
        let rootAuthority = try XCTUnwrap(appState.workspaceSearchRootAuthority)
        let retiredLocation = try rootAuthority.canonicalizedLocation(forFileURL: retiredURL)
        let retiredRead = try MarkdownFileStore().loadResult(at: retiredLocation)
        let retiredSession = DocumentSession(
            text: resultSource,
            url: retiredLocation.fileURL,
            fileKind: .markdown
        )
        let retiredIdentity = ObjectIdentifier(retiredSession)
        let originalBinding = AnchoredWorkspaceSessionFileBinding(
            location: retiredLocation,
            identity: retiredRead.metadata.identity,
            sha256Digest: retiredRead.sha256Digest
        )
        appState.adoptAnchoredFileBinding(originalBinding, for: retiredSession)
        appState.retiredEditorDocumentSessions[retiredLocation.fileURL] =
            RetiredEditorDocumentSession(
                canonicalURL: retiredLocation.fileURL,
                session: retiredSession,
                bindingIDs: [],
                awaitingInstallations: [],
                securityScopedAuthorityOwners: []
            )

        appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "needle"))
        try await waitUntil("retired search starts") { provider.requests.count == 1 }
        let request = provider.requests[0]
        let fileResult = result(
            path: "b.md",
            text: resultSource,
            needle: "needle",
            rootURL: fixture.rootURL
        )
        let match = try XCTUnwrap(fileResult.matches.first)
        provider.yield(.fileResult(context(for: request), fileResult), to: 0)
        try await waitUntil("retired search result applies") {
            appState.workspaceSearchState.fileResults == [fileResult]
        }

        appState.handleExternalChange(for: retiredSession)
        try await waitUntil("older retired inspection starts") { reader.requestCount == 1 }
        let olderInspection = try XCTUnwrap(
            appState.externalDiskInspectionTasks[retiredIdentity]
        )
        let olderGeneration = olderInspection.diskEventGeneration

        let handle = try FileHandle(forWritingTo: retiredURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(observedSource.utf8))
        try handle.synchronize()
        try handle.close()
        XCTAssertEqual(try regularIdentity(at: retiredURL), originalBinding.identity)
        let olderNavigation = seedOlderPendingNavigation(in: appState)

        appState.activateWorkspaceSearchResult(
            context: context(for: request),
            fileResult: fileResult,
            match: match
        )

        XCTAssertTrue(appState.currentDocument === currentSession)
        XCTAssertEqual(retiredSession.text, observedSource)
        XCTAssertFalse(retiredSession.isDirty)
        XCTAssertNil(appState.externalDiskInspectionTasks[retiredIdentity])
        XCTAssertEqual(
            appState.currentExternalDiskEventGeneration(for: retiredSession),
            olderGeneration + 1
        )
        XCTAssertNil(appState.retiredEditorDocumentSessions[retiredLocation.fileURL])
        XCTAssertNil(appState.anchoredSessionFileBinding(for: retiredSession))
        XCTAssertEqual(appState.editorNavigationCommand, .navigate(olderNavigation))

        reader.resolve(
            request: 0,
            with: .loaded(coherentSnapshot(
                text: resultSource,
                identity: originalBinding.identity
            ))
        )
        await olderInspection.task.value

        XCTAssertTrue(appState.currentDocument === currentSession)
        XCTAssertEqual(retiredSession.text, observedSource)
        XCTAssertNil(appState.retiredEditorDocumentSessions[retiredLocation.fileURL])
        XCTAssertNil(appState.anchoredSessionFileBinding(for: retiredSession))
        XCTAssertNil(appState.pendingExternalTexts[retiredLocation.fileURL])
        XCTAssertNil(appState.pendingExternalFileVersions[retiredLocation.fileURL])
    }

    func testCachedSearchHardLinkCollisionDetachesBeforeEvictingOlderInspection() async throws {
        try await assertReusableSearchHardLinkCollisionIsAccountedFor(.cached)
    }

    func testRetiredSearchHardLinkCollisionDetachesBeforeEvictingOlderInspection() async throws {
        try await assertReusableSearchHardLinkCollisionIsAccountedFor(.retired)
    }

    func testSearchObservationRestartsReloadAndKeepMineAgainstNewerConflictVersion() async throws {
        for intent in [DeferredExternalChangeResolution.reload, .keepMine] {
            try await assertSearchObservationSupersedesOlderExternalResolution(intent: intent)
        }
    }

    func testSearchObservationSupersedesPartiallyAppliedReloadAndKeepMine() async throws {
        for intent in [DeferredExternalChangeResolution.reload, .keepMine] {
            try await assertSearchObservationSupersedesPendingExternalApplication(intent: intent)
        }
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
        let staleResult = result(
            path: "post.md",
            text: diskText,
            needle: "needle",
            rootURL: fixture.rootURL
        )
        let staleMatch = try XCTUnwrap(staleResult.matches.first)
        provider.yield(.fileResult(context(for: firstRequest), staleResult), to: 0)
        try await waitUntil("stale result applies") {
            fixture.appState.workspaceSearchState.fileResults == [staleResult]
        }

        let olderNavigation = seedOlderPendingNavigation(in: fixture.appState)
        let searchTask = try XCTUnwrap(fixture.appState.workspaceSearchTask)
        let searchToken = fixture.appState.workspaceSearchTaskToken
        fixture.appState.activateWorkspaceSearchResult(
            context: context(for: firstRequest),
            fileResult: staleResult,
            match: staleMatch
        )

        XCTAssertEqual(fixture.appState.editorNavigationCommand, .navigate(olderNavigation))
        XCTAssertEqual(fixture.appState.workspaceSearchTaskToken, searchToken)
        XCTAssertNotNil(fixture.appState.workspaceSearchTask)
        XCTAssertFalse(searchTask.isCancelled)
        XCTAssertEqual(provider.requests.count, 1)
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

    func testAcceptedActivationMissingNodePreservesOlderNavigation() async throws {
        let scenario = try await makeAcceptedActivationScenario()
        defer { cleanUp(scenario.fixture) }
        let olderNavigation = seedOlderPendingNavigation(in: scenario.fixture.appState)
        let currentOnly = snapshot(paths: ["a.md"], rootURL: scenario.fixture.rootURL)
        scenario.fixture.appState.workspaceTree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: currentOnly,
            options: .init(showAllFiles: false)
        )

        activateAndAssertNavigationUnchanged(scenario, olderNavigation: olderNavigation)
    }

    func testAcceptedActivationOpenFailurePreservesOlderNavigation() async throws {
        let scenario = try await makeAcceptedActivationScenario()
        defer { cleanUp(scenario.fixture) }
        let olderNavigation = seedOlderPendingNavigation(in: scenario.fixture.appState)
        try FileManager.default.removeItem(
            at: scenario.fixture.rootURL.appendingPathComponent("b.md")
        )

        activateAndAssertNavigationUnchanged(scenario, olderNavigation: olderNavigation)
    }

    func testAcceptedActivationDetachedTargetPreservesOlderNavigation() async throws {
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

        activateAndAssertNavigationUnchanged(scenario, olderNavigation: olderNavigation)
    }

    func testAcceptedActivationIdentityMismatchPreservesOlderNavigation() async throws {
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

        activateAndAssertNavigationUnchanged(scenario, olderNavigation: olderNavigation)
    }

    func testAcceptedActivationFingerprintMismatchPreservesEntirePreviousTransaction() async throws {
        let scenario = try await makeAcceptedActivationScenario()
        defer { cleanUp(scenario.fixture) }
        let appState = scenario.fixture.appState
        let previousSession = appState.currentDocument
        appState.replaceDocumentText("alpha dirty", in: previousSession)
        let olderNavigation = seedOlderPendingNavigation(in: appState)
        let autosave = try XCTUnwrap(appState.autosaveTask)
        let statistics = try XCTUnwrap(appState.statisticsTask)
        let completion = try XCTUnwrap(appState.completionWorkspaceTask)
        let search = try XCTUnwrap(appState.workspaceSearchTask)
        let searchToken = appState.workspaceSearchTaskToken
        let previousTree = appState.workspaceTree
        try "changed beta".write(
            to: scenario.fixture.rootURL.appendingPathComponent("b.md"),
            atomically: true,
            encoding: .utf8
        )

        activateAndAssertNavigationUnchanged(scenario, olderNavigation: olderNavigation)
        XCTAssertTrue(appState.currentDocument === previousSession)
        XCTAssertEqual(appState.workspaceTree, previousTree)
        XCTAssertNotNil(appState.autosaveTask)
        XCTAssertNotNil(appState.statisticsTask)
        XCTAssertNotNil(appState.completionWorkspaceTask)
        XCTAssertNotNil(appState.workspaceSearchTask)
        XCTAssertEqual(appState.workspaceSearchTaskToken, searchToken)
        XCTAssertFalse(autosave.isCancelled)
        XCTAssertFalse(statistics.isCancelled)
        XCTAssertFalse(completion.isCancelled)
        XCTAssertFalse(search.isCancelled)
    }

    func testAcceptedActivationIntermediateSymlinkSwapPreservesEntirePreviousTransaction() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "alpha", "safe/b.md": "beta"],
            currentPath: "a.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "beta"))
        try await waitUntil("nested activation search starts") { provider.requests.count == 1 }
        let request = provider.requests[0]
        let fileResult = result(
            path: "safe/b.md",
            text: "beta",
            needle: "beta",
            rootURL: fixture.rootURL
        )
        let match = try XCTUnwrap(fileResult.matches.first)
        provider.yield(.fileResult(context(for: request), fileResult), to: 0)
        try await waitUntil("nested activation result applies") {
            appState.workspaceSearchState.fileResults == [fileResult]
        }

        let previousSession = appState.currentDocument
        appState.replaceDocumentText("alpha dirty", in: previousSession)
        let olderNavigation = seedOlderPendingNavigation(in: appState)
        let autosave = try XCTUnwrap(appState.autosaveTask)
        let statistics = try XCTUnwrap(appState.statisticsTask)
        let completion = try XCTUnwrap(appState.completionWorkspaceTask)
        let search = try XCTUnwrap(appState.workspaceSearchTask)
        let searchToken = appState.workspaceSearchTaskToken
        let previousTree = appState.workspaceTree

        let originalParent = fixture.rootURL.appendingPathComponent("safe", isDirectory: true)
        let retainedParent = fixture.rootURL.appendingPathComponent(
            "safe-original",
            isDirectory: true
        )
        let replacementParent = fixture.rootURL.appendingPathComponent(
            "replacement",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: replacementParent,
            withIntermediateDirectories: true
        )
        try "beta".write(
            to: replacementParent.appendingPathComponent("b.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.moveItem(at: originalParent, to: retainedParent)
        try FileManager.default.createSymbolicLink(
            at: originalParent,
            withDestinationURL: replacementParent
        )

        appState.activateWorkspaceSearchResult(
            context: context(for: request),
            fileResult: fileResult,
            match: match
        )

        XCTAssertTrue(appState.currentDocument === previousSession)
        XCTAssertEqual(appState.currentDocument.text, "alpha dirty")
        XCTAssertEqual(appState.workspaceTree, previousTree)
        XCTAssertEqual(appState.editorNavigationCommand, .navigate(olderNavigation))
        XCTAssertEqual(appState.workspaceSearchTaskToken, searchToken)
        XCTAssertNotNil(appState.workspaceSearchTask)
        XCTAssertFalse(autosave.isCancelled)
        XCTAssertFalse(statistics.isCancelled)
        XCTAssertFalse(completion.isCancelled)
        XCTAssertFalse(search.isCancelled)
        XCTAssertNil(appState.sessionCache[originalParent.appendingPathComponent("b.md")])
    }

    func testAcceptedActivationHardLinkCollisionPreservesEntirePreviousTransaction() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "alpha", "b.md": "temporary"],
            currentPath: "a.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let documentAURL = fixture.rootURL.appendingPathComponent("a.md")
        let documentBURL = fixture.rootURL.appendingPathComponent("b.md")
        try FileManager.default.removeItem(at: documentBURL)
        try FileManager.default.linkItem(at: documentAURL, to: documentBURL)

        appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "alpha"))
        try await waitUntil("hard-link activation search starts") {
            provider.requests.count == 1
        }
        let request = provider.requests[0]
        let fileResult = result(
            path: "b.md",
            text: "alpha",
            needle: "alpha",
            rootURL: fixture.rootURL
        )
        let match = try XCTUnwrap(fileResult.matches.first)
        provider.yield(.fileResult(context(for: request), fileResult), to: 0)
        try await waitUntil("hard-link search result applies") {
            appState.workspaceSearchState.fileResults == [fileResult]
        }

        let previousSession = appState.currentDocument
        appState.replaceDocumentText("alpha dirty", in: previousSession)
        let olderNavigation = seedOlderPendingNavigation(in: appState)
        let autosave = try XCTUnwrap(appState.autosaveTask)
        let statistics = try XCTUnwrap(appState.statisticsTask)
        let completion = try XCTUnwrap(appState.completionWorkspaceTask)
        let search = try XCTUnwrap(appState.workspaceSearchTask)
        let searchToken = appState.workspaceSearchTaskToken
        let previousTree = appState.workspaceTree
        let previousBindings = appState.anchoredSessionFileBindings

        appState.activateWorkspaceSearchResult(
            context: context(for: request),
            fileResult: fileResult,
            match: match
        )

        XCTAssertTrue(appState.currentDocument === previousSession)
        XCTAssertEqual(appState.currentDocument.text, "alpha dirty")
        XCTAssertEqual(appState.workspaceTree, previousTree)
        XCTAssertEqual(appState.editorNavigationCommand, .navigate(olderNavigation))
        XCTAssertEqual(appState.workspaceSearchTaskToken, searchToken)
        XCTAssertNotNil(appState.workspaceSearchTask)
        XCTAssertFalse(autosave.isCancelled)
        XCTAssertFalse(statistics.isCancelled)
        XCTAssertFalse(completion.isCancelled)
        XCTAssertFalse(search.isCancelled)
        XCTAssertEqual(appState.anchoredSessionFileBindings, previousBindings)
        XCTAssertNil(appState.sessionCache[documentBURL.standardizedFileURL])
    }

    func testAcceptedActivationUnownedHardLinkTreeCollisionPreservesEntirePreviousTransaction() async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": "alpha", "b.md": "temporary", "c.md": "charlie"],
            currentPath: "c.md"
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let documentAURL = fixture.rootURL.appendingPathComponent("a.md")
        let documentBURL = fixture.rootURL.appendingPathComponent("b.md")
        try FileManager.default.removeItem(at: documentBURL)
        try FileManager.default.linkItem(at: documentAURL, to: documentBURL)

        let hardLinkSnapshot = try await WorkspaceDirectoryScanner().snapshot(root: fixture.rootURL)
        appState.workspaceSnapshot = hardLinkSnapshot
        appState.workspaceTree = WorkspaceFileTree.reconcile(
            previous: nil,
            snapshot: hardLinkSnapshot,
            options: .init(showAllFiles: false)
        )

        appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "alpha"))
        try await waitUntil("unowned hard-link activation search starts") {
            provider.requests.count == 1
        }
        let request = provider.requests[0]
        let fileResult = result(
            path: "b.md",
            text: "alpha",
            needle: "alpha",
            rootURL: fixture.rootURL
        )
        let match = try XCTUnwrap(fileResult.matches.first)
        provider.yield(.fileResult(context(for: request), fileResult), to: 0)
        try await waitUntil("unowned hard-link search result applies") {
            appState.workspaceSearchState.fileResults == [fileResult]
        }

        let previousSession = appState.currentDocument
        appState.replaceDocumentText("charlie dirty", in: previousSession)
        let olderNavigation = seedOlderPendingNavigation(in: appState)
        let autosave = try XCTUnwrap(appState.autosaveTask)
        let statistics = try XCTUnwrap(appState.statisticsTask)
        let completion = try XCTUnwrap(appState.completionWorkspaceTask)
        let search = try XCTUnwrap(appState.workspaceSearchTask)
        let searchToken = appState.workspaceSearchTaskToken
        let previousTree = appState.workspaceTree
        let previousBindings = appState.anchoredSessionFileBindings

        appState.activateWorkspaceSearchResult(
            context: context(for: request),
            fileResult: fileResult,
            match: match
        )

        XCTAssertTrue(appState.currentDocument === previousSession)
        XCTAssertEqual(appState.currentDocument.text, "charlie dirty")
        XCTAssertEqual(appState.workspaceTree, previousTree)
        XCTAssertEqual(appState.editorNavigationCommand, .navigate(olderNavigation))
        XCTAssertEqual(appState.workspaceSearchTaskToken, searchToken)
        XCTAssertNotNil(appState.workspaceSearchTask)
        XCTAssertFalse(autosave.isCancelled)
        XCTAssertFalse(statistics.isCancelled)
        XCTAssertFalse(completion.isCancelled)
        XCTAssertFalse(search.isCancelled)
        XCTAssertEqual(appState.anchoredSessionFileBindings, previousBindings)
        XCTAssertNil(appState.sessionCache[documentBURL.standardizedFileURL])
    }

    func testAcceptedActivationInvalidRangePreservesEntirePreviousTransaction() async throws {
        var scenario = try await makeAcceptedActivationScenario()
        defer { cleanUp(scenario.fixture) }
        let appState = scenario.fixture.appState
        let previousSession = appState.currentDocument
        appState.replaceDocumentText("alpha dirty", in: previousSession)
        let olderNavigation = seedOlderPendingNavigation(in: appState)
        let autosave = try XCTUnwrap(appState.autosaveTask)
        let statistics = try XCTUnwrap(appState.statisticsTask)
        let completion = try XCTUnwrap(appState.completionWorkspaceTask)
        let search = try XCTUnwrap(appState.workspaceSearchTask)
        let searchToken = appState.workspaceSearchTaskToken
        let previousTree = appState.workspaceTree
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
            isTruncated: false,
            fileAuthority: scenario.fileResult.fileAuthority
        )
        scenario.match = invalidMatch
        scenario.fixture.appState.workspaceSearchState.fileResults = [scenario.fileResult]

        activateAndAssertNavigationUnchanged(scenario, olderNavigation: olderNavigation)
        XCTAssertTrue(appState.currentDocument === previousSession)
        XCTAssertEqual(appState.workspaceTree, previousTree)
        XCTAssertNotNil(appState.autosaveTask)
        XCTAssertNotNil(appState.statisticsTask)
        XCTAssertNotNil(appState.completionWorkspaceTask)
        XCTAssertNotNil(appState.workspaceSearchTask)
        XCTAssertEqual(appState.workspaceSearchTaskToken, searchToken)
        XCTAssertFalse(autosave.isCancelled)
        XCTAssertFalse(statistics.isCancelled)
        XCTAssertFalse(completion.isCancelled)
        XCTAssertFalse(search.isCancelled)
    }

    func testUnreadableAcceptedActivationPreservesCurrentWorkAndNavigation() async throws {
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
        XCTAssertEqual(appState.editorNavigationCommand, .navigate(olderNavigation))
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
        let fileResult = result(
            path: "a.md",
            text: dirtyText,
            needle: "alpha",
            rootURL: fixture.rootURL
        )
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
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let editorFixture = try makeEditorBridgeFixture(representable: representable, source: source)
        defer {
            editorFixture.window.orderOut(nil)
            try? FileManager.default.removeItem(at: rootURL)
        }
        XCTAssertTrue(appState.isEditorDocumentBindingInstalled(binding.id, session: session))
        let installation = try XCTUnwrap(appState.editorBindingInstallations.keys.first)

        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: documentURL)
        appState.closeMissingFile()

        XCTAssertNil(appState.editorDocumentBindingIDs[ObjectIdentifier(session)])
        XCTAssertNil(appState.editorDocumentBindingSessions[binding.id])
        XCTAssertTrue(appState.editorBindingInstallations.isEmpty)
        let rejected = binding.sourceContract.publish(EditorDocumentSourcePublication(
            installation: installation,
            base: EditorDocumentSourceSnapshot(source: source, revision: session.version),
            source: source + " rejected"
        ))
        XCTAssertEqual(
            rejected,
            .rejected(EditorDocumentSourceSnapshot(source: source, revision: session.version))
        )
        XCTAssertEqual(session.text, source)
        binding.onLifecycle(.revoked(EditorDocumentBindingInstallation(
            bindingID: EditorDocumentBindingID(),
            installationID: EditorDocumentBindingInstallationID()
        )))
        XCTAssertTrue(appState.editorBindingInstallations.isEmpty)

        MarkdownTextView.dismantleNSView(
            editorFixture.scrollView,
            coordinator: editorFixture.coordinator
        )
        XCTAssertTrue(appState.editorBindingInstallations.isEmpty)
        MarkdownTextView.dismantleNSView(
            editorFixture.scrollView,
            coordinator: editorFixture.coordinator
        )
        XCTAssertTrue(appState.editorBindingInstallations.isEmpty)
        XCTAssertTrue(appState.editorDocumentBindingIDs.isEmpty)
        XCTAssertTrue(appState.editorDocumentBindingSessions.isEmpty)
    }

    // swiftlint:disable:next function_body_length
    func testStaleSecondCoordinatorIsSnapshotFencedBeforeOverlappingNativeEditAndCanRetry() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("a.md")
        let source = "prefix target suffix"
        let targetRange = (source as NSString).range(of: "target")
        try source.write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: source, url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["a.md"],
            currentSession: session
        )
        appState.recordKnownDiskText(source, for: documentURL)
        let binding = appState.editorDocumentBinding(for: session)
        var selection1: NSRange? = targetRange
        var selection2: NSRange? = targetRange
        let view1 = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: Binding(get: { selection1 }, set: { selection1 = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentURL),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let fixture1 = try makeEditorBridgeFixture(representable: view1, source: source)
        let installation1 = try XCTUnwrap(appState.editorBindingInstallations.keys.first)
        let view2 = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: Binding(get: { selection2 }, set: { selection2 = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentURL),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let fixture2 = try makeEditorBridgeFixture(
            representable: view2,
            source: source,
            makeKey: false
        )
        let installation2 = try XCTUnwrap(
            Set(appState.editorBindingInstallations.keys).subtracting([installation1]).first
        )
        defer {
            fixture1.window.orderOut(nil)
            fixture2.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture1.scrollView, coordinator: fixture1.coordinator)
            MarkdownTextView.dismantleNSView(fixture2.scrollView, coordinator: fixture2.coordinator)
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
            try? FileManager.default.removeItem(at: rootURL)
        }

        fixture1.window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(fixture1.window.makeFirstResponder(fixture1.textView))
        fixture1.textView.textSelection = targetRange
        fixture1.textView.insertText("first1", replacementRange: .notFound)
        let firstSource = "prefix first1 suffix"
        XCTAssertEqual(session.text, firstSource)
        XCTAssertEqual(session.version, 1)
        XCTAssertEqual(fixture1.textView.text, firstSource)
        XCTAssertEqual(fixture2.textView.text, source, "second coordinator must still be stale")

        fixture2.textView.insertText("second", replacementRange: .notFound)

        XCTAssertEqual(session.text, firstSource)
        XCTAssertEqual(session.version, 1)
        XCTAssertEqual(fixture1.textView.text, firstSource)
        XCTAssertEqual(fixture2.textView.text, firstSource)
        XCTAssertEqual(
            appState.editorWriterInstallations[ObjectIdentifier(session)],
            installation1,
            "a fenced stale attempt must not steal writer ownership"
        )
        XCTAssertTrue(appState.pendingEditorSourceInstallations.isEmpty)
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(appState.canAutosave(session: session))
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertNil(appState.missingFilePrompt)
        let firstOverlayTexts = try await appState.workspaceSearchDirtyOverlays(
            rootAuthority: XCTUnwrap(appState.workspaceSearchRootAuthority)
        ).overlays.map(\.text)
        XCTAssertEqual(firstOverlayTexts, [firstSource])

        let retryRange = (firstSource as NSString).range(of: "first1")
        fixture2.textView.textSelection = retryRange
        fixture2.textView.insertText("second", replacementRange: .notFound)
        let retriedSource = "prefix second suffix"
        XCTAssertEqual(session.text, retriedSource)
        XCTAssertEqual(session.version, 2)
        XCTAssertEqual(
            appState.editorWriterInstallations[ObjectIdentifier(session)],
            installation2
        )
        XCTAssertTrue(appState.pendingEditorSourceInstallations.isEmpty)
        XCTAssertTrue(appState.canAutosave(session: session))

        view1.updateRepresentedTextView(fixture1.scrollView, coordinator: fixture1.coordinator)
        XCTAssertEqual(fixture1.textView.text, retriedSource)
        XCTAssertEqual(fixture2.textView.text, retriedSource)
        let retriedOverlayTexts = try await appState.workspaceSearchDirtyOverlays(
            rootAuthority: XCTUnwrap(appState.workspaceSearchRootAuthority)
        ).overlays.map(\.text)
        XCTAssertEqual(retriedOverlayTexts, [retriedSource])
    }

    // swiftlint:disable:next function_body_length
    func testOverlappingPendingPublicationRestoresCurrentSnapshotAndReleasesWriterForRetry() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("a.md")
        let source = "prefix target suffix"
        try source.write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: source, url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: ["a.md"],
            currentSession: session
        )
        appState.recordKnownDiskText(source, for: documentURL)
        let binding = appState.editorDocumentBinding(for: session)
        var selection: NSRange? = (source as NSString).range(of: "target")
        let view = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentURL),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let fixture = try makeEditorBridgeFixture(representable: view, source: source)
        let installation = try XCTUnwrap(appState.editorBindingInstallations.keys.first)
        defer {
            fixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            appState.completionWorkspaceTask?.cancel()
            try? FileManager.default.removeItem(at: rootURL)
        }

        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.textSelection = selection ?? .notFound
        fixture.textView.setMarkedText(
            "draft",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: .notFound
        )
        XCTAssertTrue(appState.pendingEditorSourceInstallations[installation] === session)

        let currentSource = "prefix current suffix"
        appState.replaceDocumentText(currentSource, in: session)
        XCTAssertEqual(session.version, 1)
        fixture.textView.insertText("proposed", replacementRange: .notFound)

        XCTAssertEqual(session.text, currentSource)
        XCTAssertEqual(session.version, 1)
        XCTAssertEqual(fixture.textView.text, currentSource)
        XCTAssertTrue(appState.pendingEditorSourceInstallations.isEmpty)
        XCTAssertNil(appState.editorWriterInstallations[ObjectIdentifier(session)])
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(appState.canAutosave(session: session))
        let currentOverlayTexts = try await appState.workspaceSearchDirtyOverlays(
            rootAuthority: XCTUnwrap(appState.workspaceSearchRootAuthority)
        ).overlays.map(\.text)
        XCTAssertEqual(currentOverlayTexts, [currentSource])

        let retryRange = (currentSource as NSString).range(of: "current")
        fixture.textView.textSelection = retryRange
        fixture.textView.insertText("retry", replacementRange: .notFound)
        let retriedSource = "prefix retry suffix"
        XCTAssertEqual(session.text, retriedSource)
        XCTAssertEqual(session.version, 2)
        XCTAssertEqual(
            appState.editorWriterInstallations[ObjectIdentifier(session)],
            installation
        )
        XCTAssertTrue(appState.pendingEditorSourceInstallations.isEmpty)
    }

    // swiftlint:disable:next function_body_length
    func testTwoCoordinatorPendingCommitReconcilesMirroredAdvanceAndRevokedWritersStayRejected() throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("a.md")
        let source = "A composition: "
        try source.write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: source, url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        let canonicalURL = try XCTUnwrap(appState.sessionStateURL(for: session))
        appState.sessionCache[canonicalURL] = session
        appState.recordKnownDiskText(source, for: canonicalURL)
        let binding = appState.editorDocumentBinding(for: session)
        var selection1: NSRange? = NSRange(location: (source as NSString).length, length: 0)
        var selection2: NSRange? = selection1
        let view1 = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: Binding(get: { selection1 }, set: { selection1 = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentURL),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let fixture1 = try makeEditorBridgeFixture(representable: view1, source: source)
        let installation1 = try XCTUnwrap(appState.editorBindingInstallations.keys.first)
        let view2 = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: Binding(get: { selection2 }, set: { selection2 = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentURL),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let fixture2 = try makeEditorBridgeFixture(representable: view2, source: source, makeKey: false)
        let installation2 = try XCTUnwrap(
            Set(appState.editorBindingInstallations.keys).subtracting([installation1]).first
        )
        defer {
            fixture1.window.orderOut(nil)
            fixture2.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture1.scrollView, coordinator: fixture1.coordinator)
            MarkdownTextView.dismantleNSView(fixture2.scrollView, coordinator: fixture2.coordinator)
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            try? FileManager.default.removeItem(at: rootURL)
        }

        XCTAssertEqual(appState.editorWriterInstallations[ObjectIdentifier(session)], installation1)
        XCTAssertTrue(fixture1.window.makeFirstResponder(fixture1.textView))
        fixture1.textView.textSelection = selection1 ?? .notFound
        fixture1.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        XCTAssertTrue(appState.pendingEditorSourceInstallations[installation1] === session)
        XCTAssertEqual(
            binding.sourceContract.writer(.activate(
                installation2,
                from: binding.sourceContract.snapshot()
            )),
            .rejected(binding.sourceContract.snapshot())
        )
        fixture2.textView.textSelection = selection2 ?? .notFound
        fixture2.textView.insertText(" blocked", replacementRange: .notFound)
        XCTAssertEqual(fixture2.textView.text, source)
        XCTAssertEqual(session.text, source)

        let mirroredAdvance = "remote " + source
        appState.replaceDocumentText(mirroredAdvance, in: session)
        view2.updateRepresentedTextView(fixture2.scrollView, coordinator: fixture2.coordinator)
        XCTAssertEqual(fixture2.textView.text, mirroredAdvance)
        XCTAssertEqual(session.version, 1)

        let committedText = "臺e\u{0301}🧪"
        fixture1.textView.insertText(committedText, replacementRange: .notFound)
        let reconciledSource = mirroredAdvance + committedText
        XCTAssertEqual(Array(session.text.utf16), Array(reconciledSource.utf16))
        XCTAssertEqual(session.version, 2)
        XCTAssertTrue(appState.pendingEditorSourceInstallations.isEmpty)
        try appState.save(session: session)
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), reconciledSource)

        MarkdownTextView.dismantleNSView(fixture1.scrollView, coordinator: fixture1.coordinator)
        let staleWhileMirrorLives = binding.sourceContract.publish(EditorDocumentSourcePublication(
            installation: installation1,
            base: EditorDocumentSourceSnapshot(source: reconciledSource, revision: session.version),
            source: reconciledSource + " stale"
        ))
        XCTAssertEqual(
            staleWhileMirrorLives,
            .rejected(EditorDocumentSourceSnapshot(source: reconciledSource, revision: session.version))
        )
        XCTAssertTrue(appState.editorBindingInstallations[installation2] === session)

        MarkdownTextView.dismantleNSView(fixture2.scrollView, coordinator: fixture2.coordinator)
        XCTAssertEqual(
            binding.sourceContract.writer(.activate(
                installation1,
                from: binding.sourceContract.snapshot()
            )),
            .rejected(binding.sourceContract.snapshot())
        )
        XCTAssertEqual(
            binding.sourceContract.writer(.release(installation2)),
            .releaseRejected
        )
        let staleAfterBothRevoke = binding.sourceContract.publish(EditorDocumentSourcePublication(
            installation: installation2,
            base: EditorDocumentSourceSnapshot(source: reconciledSource, revision: session.version),
            source: reconciledSource + " rejected"
        ))
        XCTAssertEqual(
            staleAfterBothRevoke,
            .rejected(EditorDocumentSourceSnapshot(source: reconciledSource, revision: session.version))
        )
        XCTAssertEqual(session.text, reconciledSource)
    }

    // swiftlint:disable:next function_body_length
    func testDeferredReloadRereadsXToYCoherentlyAndLaterWatcherDetectsZ() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("a.md")
        let source = "Local: "
        let externalX = "External version X"
        let externalY = "External version Y"
        let externalZ = "External version Z"
        let modificationDateX = Date(timeIntervalSince1970: 1_700_000_100)
        let modificationDateY = Date(timeIntervalSince1970: 1_700_000_200)
        let modificationDateZ = Date(timeIntervalSince1970: 1_700_000_300)
        try source.write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: source, url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        let canonicalURL = try XCTUnwrap(appState.sessionStateURL(for: session))
        appState.sessionCache[canonicalURL] = session
        appState.recordKnownDiskText(source, for: canonicalURL)
        let binding = appState.editorDocumentBinding(for: session)
        var selection: NSRange? = NSRange(location: (source as NSString).length, length: 0)
        let view = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentURL),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let fixture = try makeEditorBridgeFixture(representable: view, source: source)
        defer {
            fixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            try? FileManager.default.removeItem(at: rootURL)
        }

        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.textSelection = selection ?? .notFound
        fixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        let installation = try XCTUnwrap(appState.pendingEditorSourceInstallations.keys.first)
        try externalX.write(to: documentURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDateX],
            ofItemAtPath: documentURL.path
        )
        appState.lastKnownDiskModificationDates[canonicalURL] = .distantPast
        appState.handleExternalChange(for: session)

        try await waitUntil("external X conflict is detected while composition is pending") {
            appState.pendingExternalTexts[canonicalURL] == externalX &&
                appState.externalChangePrompt != nil
        }
        XCTAssertTrue(appState.pendingEditorSourceInstallations[installation] === session)
        XCTAssertEqual(session.text, source)
        XCTAssertEqual(session.version, 0)
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(appState.pendingExternalTexts[canonicalURL], externalX)
        XCTAssertNotNil(appState.externalChangePrompt)
        XCTAssertFalse(appState.canAutosave(session: session))

        appState.reloadExternallyChangedFile()
        XCTAssertNotNil(appState.deferredExternalChangeResolutions[canonicalURL])
        XCTAssertEqual(session.text, source)
        try externalY.write(to: documentURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDateY],
            ofItemAtPath: documentURL.path
        )
        fixture.textView.insertText("臺", replacementRange: .notFound)

        let committedLocal = source + "臺"
        try await waitUntil("selection-time Reload stale-drops after the accepted IME commit") {
            session.text == committedLocal &&
                appState.deferredExternalChangeResolutions[canonicalURL] == nil &&
                appState.externalChangePrompt != nil
        }
        XCTAssertEqual(session.text, committedLocal)
        XCTAssertEqual(fixture.textView.text, committedLocal)
        XCTAssertEqual(session.version, 1)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(appState.pendingExternalTexts[canonicalURL], externalX)

        appState.reloadExternallyChangedFile()
        try await waitUntil("fresh Reload selection rereads Y and synchronizes the live editor") {
            session.text == externalY &&
                fixture.textView.text == externalY &&
                appState.externalReloadTasks[ObjectIdentifier(session)] == nil
        }

        XCTAssertEqual(session.text, externalY)
        XCTAssertEqual(fixture.textView.text, externalY)
        XCTAssertEqual(
            fixture.coordinator.currentInstalledSourceSnapshot,
            EditorDocumentSourceSnapshot(source: externalY, revision: session.version)
        )
        XCTAssertEqual(session.version, 2)
        XCTAssertFalse(session.isDirty)
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertNil(appState.pendingExternalTexts[canonicalURL])
        XCTAssertTrue(appState.pendingEditorSourceInstallations.isEmpty)
        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), externalY)
        XCTAssertEqual(
            appState.lastKnownDiskHashes[canonicalURL],
            AppState.contentHash(externalY)
        )
        XCTAssertEqual(
            appState.lastKnownDiskModificationDates[canonicalURL],
            modificationDateY
        )

        fixture.textView.textSelection = NSRange(
            location: (externalY as NSString).length,
            length: 0
        )
        fixture.textView.insertText("!", replacementRange: .notFound)
        let editedY = externalY + "!"
        XCTAssertEqual(session.text, editedY)
        XCTAssertEqual(fixture.textView.text, editedY)
        XCTAssertEqual(session.version, 3)
        XCTAssertTrue(session.isDirty)

        try externalZ.write(to: documentURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDateZ],
            ofItemAtPath: documentURL.path
        )
        appState.handleExternalChange(for: session)

        try await waitUntil("later watcher detects Z") {
            appState.pendingExternalTexts[canonicalURL] == externalZ &&
                appState.externalChangePrompt?.fileURL == canonicalURL
        }
        XCTAssertEqual(session.text, editedY)
        XCTAssertEqual(session.version, 3)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(appState.pendingExternalTexts[canonicalURL], externalZ)
        XCTAssertEqual(appState.externalChangePrompt?.fileURL, canonicalURL)
    }

    func testDeferredReloadMissingAtExecutionPreservesEditorSourceInRecoveryFlow() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("a.md")
        let source = "Retained editor source"
        let externalX = "External version X"
        try source.write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: source, url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        let canonicalURL = try XCTUnwrap(appState.sessionStateURL(for: session))
        appState.sessionCache[canonicalURL] = session
        appState.recordKnownDiskText(source, for: canonicalURL)
        let binding = appState.editorDocumentBinding(for: session)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        binding.sourceContract.pendingSource(.began(installation))
        defer {
            binding.onLifecycle(.revoked(installation))
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            try? FileManager.default.removeItem(at: rootURL)
        }

        try externalX.write(to: documentURL, atomically: true, encoding: .utf8)
        appState.lastKnownDiskModificationDates[canonicalURL] = .distantPast
        appState.handleExternalChange(for: session)
        try await waitUntil("external X is ready for deferred Reload") {
            appState.pendingExternalTexts[canonicalURL] == externalX &&
                appState.externalChangePrompt?.fileURL == canonicalURL
        }
        appState.reloadExternallyChangedFile()
        XCTAssertNotNil(appState.deferredExternalChangeResolutions[canonicalURL])

        try FileManager.default.removeItem(at: documentURL)
        binding.sourceContract.pendingSource(.synchronized(installation))

        try await waitUntil("missing deferred Reload enters recovery") {
            appState.detachedSessionURLs.contains(canonicalURL)
        }

        XCTAssertEqual(session.text, source)
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(appState.detachedSessionURLs.contains(canonicalURL))
        XCTAssertEqual(appState.missingFilePrompt?.fileURL, canonicalURL)
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertNil(appState.pendingExternalTexts[canonicalURL])
        XCTAssertNil(appState.deferredExternalChangeResolutions[canonicalURL])
        XCTAssertFalse(appState.canAutosave(session: session))
    }

    // swiftlint:disable:next function_body_length
    func testPendingCompositionExternalChangeKeepMineSavesNewestCommittedSource() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentURL = rootURL.appendingPathComponent("a.md")
        let source = "Local: "
        let diskSource = "External disk source"
        try source.write(to: documentURL, atomically: true, encoding: .utf8)
        let session = DocumentSession(text: source, url: documentURL, fileKind: .markdown)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        let canonicalURL = try XCTUnwrap(appState.sessionStateURL(for: session))
        appState.sessionCache[canonicalURL] = session
        appState.recordKnownDiskText(source, for: canonicalURL)
        let binding = appState.editorDocumentBinding(for: session)
        var selection: NSRange? = NSRange(location: (source as NSString).length, length: 0)
        let view = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentURL),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let fixture = try makeEditorBridgeFixture(representable: view, source: source)
        defer {
            fixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            try? FileManager.default.removeItem(at: rootURL)
        }

        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.textSelection = selection ?? .notFound
        fixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        try diskSource.write(to: documentURL, atomically: true, encoding: .utf8)
        appState.lastKnownDiskModificationDates[canonicalURL] = .distantPast
        appState.handleExternalChange(for: session)
        fixture.textView.insertText("臺e\u{0301}🧪", replacementRange: .notFound)
        let localSource = source + "臺e\u{0301}🧪"

        XCTAssertEqual(Array(session.text.utf16), Array(localSource.utf16))
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.version, 1)
        try await waitUntil("external disk source is ready for Keep Mine") {
            appState.pendingExternalTexts[canonicalURL] == diskSource &&
                appState.externalChangePrompt?.fileURL == canonicalURL
        }
        appState.keepMineForExternallyChangedFile()
        try await waitUntil("Keep Mine records the disk baseline") {
            appState.externalReloadTasks[ObjectIdentifier(session)] == nil &&
                appState.externalChangePrompt == nil
        }
        XCTAssertNil(appState.externalChangePrompt)
        try appState.save(session: session)

        XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), localSource)
        XCTAssertFalse(session.isDirty)
        XCTAssertNil(appState.pendingExternalTexts[canonicalURL])
    }

    // swiftlint:disable:next function_body_length
    func testRetiredPendingReloadStaleDropsAfterLateCommitAndPreservesItOnReactivation() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentAURL = rootURL.appendingPathComponent("a.md")
        let documentBURL = rootURL.appendingPathComponent("b.md")
        let sourceA = "A composition: "
        let sourceB = "B remains unchanged"
        let externalA = "A external source"
        try sourceA.write(to: documentAURL, atomically: true, encoding: .utf8)
        try sourceB.write(to: documentBURL, atomically: true, encoding: .utf8)
        let sessionA = DocumentSession(text: sourceA, url: documentAURL, fileKind: .markdown)
        let appState = AppState(currentDocument: sessionA, shouldRestoreLastOpenedFile: false)
        let canonicalA = try XCTUnwrap(appState.sessionStateURL(for: sessionA))
        appState.sessionCache[canonicalA] = sessionA
        appState.recordKnownDiskText(sourceA, for: canonicalA)
        let bindingA = appState.editorDocumentBinding(for: sessionA)
        let installationA = EditorDocumentBindingInstallation(
            bindingID: bindingA.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        bindingA.onLifecycle(.installed(installationA))
        let selectedSourceSnapshot = bindingA.sourceContract.snapshot()
        XCTAssertEqual(
            bindingA.sourceContract.writer(.activate(
                installationA,
                from: selectedSourceSnapshot
            )),
            .activated(selectedSourceSnapshot)
        )
        bindingA.sourceContract.pendingSource(.began(installationA))
        defer {
            bindingA.onLifecycle(.revoked(installationA))
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            for task in appState.sessionAutosaveTasks.values {
                task.task.cancel()
            }
            for task in appState.sessionStatisticsTasks.values {
                task.task.cancel()
            }
            try? FileManager.default.removeItem(at: rootURL)
        }

        try externalA.write(to: documentAURL, atomically: true, encoding: .utf8)
        appState.lastKnownDiskModificationDates[canonicalA] = .distantPast
        appState.handleExternalChange(for: sessionA)
        try await waitUntil("external conflict is detected before selecting Reload") {
            appState.externalChangePrompt?.fileURL.standardizedFileURL ==
                documentAURL.standardizedFileURL
        }
        appState.reloadExternallyChangedFile()

        XCTAssertNotNil(appState.deferredExternalChangeResolutions[canonicalA])
        XCTAssertFalse(appState.canAutosave(session: sessionA))

        let committedA = sourceA + "臺e\u{0301}🧪"
        XCTAssertEqual(
            bindingA.sourceContract.publish(EditorDocumentSourcePublication(
                installation: installationA,
                base: selectedSourceSnapshot,
                source: committedA
            )),
            .accepted(
                EditorDocumentSourceSnapshot(source: committedA, revision: 1),
                sourceWasReconciled: false
            )
        )
        bindingA.sourceContract.pendingSource(.synchronized(installationA))
        XCTAssertEqual(Array(sessionA.text.utf16), Array(committedA.utf16))
        XCTAssertEqual(sessionA.version, 1)
        XCTAssertTrue(sessionA.isDirty)
        XCTAssertTrue(appState.pendingEditorSourceInstallations.isEmpty)
        XCTAssertEqual(appState.pendingExternalTexts[canonicalA], externalA)
        XCTAssertNil(appState.deferredExternalChangeResolutions[canonicalA])
        XCTAssertNil(appState.externalResolutionIntentCaptures[canonicalA])
        XCTAssertFalse(appState.canAutosave(session: sessionA))
        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), externalA)

        try appState.open(url: documentBURL, rememberAsLastOpened: false, preserveWorkspace: false)
        let sessionB = appState.currentDocument
        XCTAssertEqual(sessionB.text, sourceB)
        XCTAssertNotNil(appState.retiredEditorDocumentSessions[canonicalA])

        try appState.open(url: documentAURL, rememberAsLastOpened: false, preserveWorkspace: false)
        try await waitUntil("reactivated stale Reload restores the conflict prompt") {
            appState.externalChangePrompt?.fileURL == canonicalA
        }
        XCTAssertTrue(appState.currentDocument === sessionA)
        XCTAssertEqual(Array(sessionA.text.utf16), Array(committedA.utf16))
        XCTAssertEqual(sessionA.version, 1)
        XCTAssertTrue(sessionA.isDirty)
        XCTAssertEqual(sessionB.text, sourceB)
        XCTAssertEqual(appState.pendingExternalTexts[canonicalA], externalA)
        XCTAssertNil(appState.deferredExternalChangeResolutions[canonicalA])
        XCTAssertEqual(appState.externalChangePrompt?.fileURL, canonicalA)
        XCTAssertNil(appState.missingFilePrompt)

        let reactivatedRetirement = try XCTUnwrap(
            appState.retiredEditorDocumentSessions[canonicalA]
        )
        XCTAssertTrue(reactivatedRetirement.session === sessionA)
        XCTAssertTrue(reactivatedRetirement.awaitingInstallations.contains(installationA))
        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), externalA)
    }

    // swiftlint:disable:next function_body_length
    func testStandaloneReplacementRetiresTwoCoordinatorsReactivatesConflictAndKeepsBIsolated() async throws {
        let rootURL = try makeTemporaryDirectory()
        let documentAURL = rootURL.appendingPathComponent("a.md")
        let documentBURL = rootURL.appendingPathComponent("b.md")
        let sourceA = "A composition: "
        let sourceB = "B remains unchanged"
        let externalA = "A changed on disk"
        try sourceA.write(to: documentAURL, atomically: true, encoding: .utf8)
        try sourceB.write(to: documentBURL, atomically: true, encoding: .utf8)
        let sessionA = DocumentSession(text: sourceA, url: documentAURL, fileKind: .markdown)
        let appState = AppState(currentDocument: sessionA, shouldRestoreLastOpenedFile: false)
        let canonicalA = try XCTUnwrap(appState.sessionStateURL(for: sessionA))
        appState.sessionCache[canonicalA] = sessionA
        appState.recordKnownDiskText(sourceA, for: canonicalA)
        let bindingA = appState.editorDocumentBinding(for: sessionA)
        var selectionA1: NSRange? = NSRange(location: (sourceA as NSString).length, length: 0)
        var selectionA2: NSRange? = selectionA1
        let viewA1 = MarkdownTextView(
            text: bindingA.text,
            styledText: nil,
            selection: Binding(get: { selectionA1 }, set: { selectionA1 = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentAURL),
            documentBindingID: bindingA.id,
            onDocumentBindingLifecycle: bindingA.onLifecycle,
            documentSourceContract: bindingA.sourceContract
        )
        let fixtureA1 = try makeEditorBridgeFixture(representable: viewA1, source: sourceA)
        let installationA1 = try XCTUnwrap(appState.editorBindingInstallations.keys.first)
        let viewA2 = MarkdownTextView(
            text: bindingA.text,
            styledText: nil,
            selection: Binding(get: { selectionA2 }, set: { selectionA2 = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentAURL),
            documentBindingID: bindingA.id,
            onDocumentBindingLifecycle: bindingA.onLifecycle,
            documentSourceContract: bindingA.sourceContract
        )
        let fixtureA2 = try makeEditorBridgeFixture(representable: viewA2, source: sourceA, makeKey: false)
        defer {
            fixtureA1.window.orderOut(nil)
            fixtureA2.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixtureA1.scrollView, coordinator: fixtureA1.coordinator)
            MarkdownTextView.dismantleNSView(fixtureA2.scrollView, coordinator: fixtureA2.coordinator)
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            try? FileManager.default.removeItem(at: rootURL)
        }

        XCTAssertTrue(fixtureA1.window.makeFirstResponder(fixtureA1.textView))
        fixtureA1.textView.textSelection = selectionA1 ?? .notFound
        fixtureA1.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        try externalA.write(to: documentAURL, atomically: true, encoding: .utf8)
        appState.lastKnownDiskModificationDates[canonicalA] = .distantPast
        appState.handleExternalChange(for: sessionA)

        try appState.open(url: documentBURL, rememberAsLastOpened: false, preserveWorkspace: false)
        let sessionB = appState.currentDocument
        XCTAssertNil(appState.workspaceRootURL)
        XCTAssertEqual(appState.retiredEditorDocumentSessions[canonicalA]?.awaitingInstallations.count, 2)
        var selectionB: NSRange? = NSRange(location: 0, length: 0)
        let bindingB = appState.editorDocumentBinding(for: sessionB)
        let viewB = MarkdownTextView(
            text: bindingB.text,
            styledText: nil,
            selection: Binding(get: { selectionB }, set: { selectionB = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentBURL),
            documentBindingID: bindingB.id,
            onDocumentBindingLifecycle: bindingB.onLifecycle,
            documentSourceContract: bindingB.sourceContract
        )
        let fixtureB = try makeEditorBridgeFixture(representable: viewB, source: sourceB, makeKey: false)
        defer {
            fixtureB.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixtureB.scrollView, coordinator: fixtureB.coordinator)
        }
        let installationB = try XCTUnwrap(
            appState.editorBindingInstallations.first(where: { $0.value === sessionB })?.key
        )
        bindingA.onLifecycle(.revoked(EditorDocumentBindingInstallation(
            bindingID: bindingA.id,
            installationID: EditorDocumentBindingInstallationID()
        )))
        XCTAssertTrue(appState.editorBindingInstallations[installationB] === sessionB)

        try appState.open(url: documentAURL, rememberAsLastOpened: false, preserveWorkspace: false)
        try await waitUntil("reactivated A conflict is ready for Keep Mine") {
            appState.pendingExternalTexts[canonicalA] == externalA &&
                appState.externalChangePrompt?.fileURL == canonicalA &&
                appState.externalDiskInspectionTasks[ObjectIdentifier(sessionA)] == nil
        }
        XCTAssertTrue(appState.currentDocument === sessionA)
        XCTAssertNotNil(appState.externalChangePrompt)
        fixtureA1.textView.insertText("臺", replacementRange: .notFound)
        let localA = sourceA + "臺"
        XCTAssertEqual(sessionA.text, localA)
        XCTAssertEqual(sessionB.text, sourceB)
        appState.keepMineForExternallyChangedFile()
        try await waitUntil("reactivated Keep Mine clears A conflict") {
            appState.externalReloadTasks[ObjectIdentifier(sessionA)] == nil &&
                appState.pendingExternalReloadApplications[ObjectIdentifier(sessionA)] == nil &&
                appState.deferredExternalChangeResolutions[canonicalA] == nil &&
                appState.pendingExternalTexts[canonicalA] == nil &&
                appState.externalChangePrompt == nil
        }
        try appState.save(session: sessionA)
        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), localA)

        MarkdownTextView.dismantleNSView(fixtureA1.scrollView, coordinator: fixtureA1.coordinator)
        bindingA.onLifecycle(.revoked(installationA1))
        MarkdownTextView.dismantleNSView(fixtureA2.scrollView, coordinator: fixtureA2.coordinator)
        XCTAssertNil(appState.retiredEditorDocumentSessions[canonicalA])
        XCTAssertTrue(appState.editorBindingInstallations[installationB] === sessionB)
        XCTAssertEqual(sessionB.text, sourceB)
    }

    func testFailedStandaloneDestinationOpenKeepsMarkedSourceWritableUntilFinalRevoke() throws {
        let rootURL = try makeTemporaryDirectory()
        let documentAURL = rootURL.appendingPathComponent("a.md")
        let invalidBURL = rootURL.appendingPathComponent("b.md")
        let sourceA = "A composition: "
        try sourceA.write(to: documentAURL, atomically: true, encoding: .utf8)
        try Data([0xFF]).write(to: invalidBURL)
        let sessionA = DocumentSession(text: sourceA, url: documentAURL, fileKind: .markdown)
        let appState = AppState(currentDocument: sessionA, shouldRestoreLastOpenedFile: false)
        appState.sessionCache[documentAURL.standardizedFileURL] = sessionA
        let binding = appState.editorDocumentBinding(for: sessionA)
        var selection: NSRange? = NSRange(location: (sourceA as NSString).length, length: 0)
        let view = MarkdownTextView(
            text: binding.text,
            styledText: nil,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: documentAURL),
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let fixture = try makeEditorBridgeFixture(representable: view, source: sourceA)
        defer {
            fixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            try? FileManager.default.removeItem(at: rootURL)
        }

        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.textSelection = selection ?? .notFound
        fixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        XCTAssertThrowsError(
            try appState.open(url: invalidBURL, rememberAsLastOpened: false, preserveWorkspace: false)
        )
        let canonicalA = documentAURL.standardizedFileURL.resolvingSymlinksInPath()
        XCTAssertTrue(appState.currentDocument === sessionA)
        XCTAssertNotNil(appState.retiredEditorDocumentSessions[canonicalA])
        fixture.textView.insertText("臺", replacementRange: .notFound)
        let committedA = sourceA + "臺"
        XCTAssertEqual(sessionA.text, committedA)

        MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
        XCTAssertNil(appState.retiredEditorDocumentSessions[canonicalA])
        XCTAssertEqual(try String(contentsOf: documentAURL, encoding: .utf8), committedA)
    }

    func testSaveCopySourceRetirementMismatchIsSideEffectFreeBeforeDestinationWrite() throws {
        let rootURL = try makeTemporaryDirectory()
        let sourceURL = rootURL.appendingPathComponent("missing.md")
        let destinationURL = rootURL.appendingPathComponent("sentinel.md")
        let source = "new local source"
        let sentinel = "destination sentinel"
        try sentinel.write(to: destinationURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let session = DocumentSession(text: source, url: sourceURL, fileKind: .markdown, isDirty: true)
        let wrongOwner = DocumentSession(text: "wrong", url: sourceURL, fileKind: .markdown, isDirty: true)
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        let sourceKey = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let destinationKey = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        appState.sessionCache[sourceKey] = session
        appState.detachedSessionURLs.insert(sourceKey)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: sourceKey)
        appState.lastKnownDiskHashes[sourceKey] = "retained-hash"
        appState.pendingExternalTexts[destinationKey] = "retained metadata"
        let binding = appState.editorDocumentBinding(for: session)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        appState.retiredEditorDocumentSessions[sourceKey] = RetiredEditorDocumentSession(
            canonicalURL: sourceKey,
            session: wrongOwner,
            bindingIDs: [],
            awaitingInstallations: [],
            securityScopedAuthorityOwners: []
        )
        let prompt = appState.missingFilePrompt
        let installations = appState.editorBindingInstallations
        let bindingIDs = appState.editorDocumentBindingIDs
        let bindingSessions = appState.editorDocumentBindingSessions

        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: destinationURL)) { error in
            guard case let AppStateError.duplicateSessionOwnership(url) = error else {
                return XCTFail("Expected conflicting source retirement ownership")
            }
            XCTAssertEqual(url, sourceKey)
        }

        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), sentinel)
        XCTAssertTrue(appState.currentDocument === session)
        XCTAssertEqual(session.fileURL?.standardizedFileURL, sourceKey)
        XCTAssertTrue(appState.sessionCache[sourceKey] === session)
        XCTAssertTrue(appState.retiredEditorDocumentSessions[sourceKey]?.session === wrongOwner)
        XCTAssertNil(appState.retiredEditorDocumentSessions[destinationKey])
        XCTAssertEqual(Set(appState.editorBindingInstallations.keys), Set(installations.keys))
        XCTAssertEqual(appState.editorDocumentBindingIDs, bindingIDs)
        XCTAssertEqual(Set(appState.editorDocumentBindingSessions.keys), Set(bindingSessions.keys))
        XCTAssertEqual(appState.missingFilePrompt, prompt)
        XCTAssertTrue(appState.detachedSessionURLs.contains(sourceKey))
        XCTAssertEqual(appState.lastKnownDiskHashes[sourceKey], "retained-hash")
        XCTAssertEqual(appState.pendingExternalTexts[destinationKey], "retained metadata")
    }

    private struct AcceptedActivationScenario {
        let fixture: Fixture
        let context: WorkspaceSearchContext
        var fileResult: WorkspaceSearchFileResult
        var match: TextSearchMatch
    }

    // swiftlint:disable function_body_length
    private func assertSearchObservationSupersedesOlderExternalResolution(
        intent: DeferredExternalChangeResolution
    ) async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let reader = ControlledCoherentFileReader()
        let defaultsSuiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.set(30.0, forKey: "Plainsong.settings.autosaveIntervalSeconds")
        let sourceA = "source A"
        let localSource = "local needle"
        let diskB = "older disk B"
        let diskC = "newer disk C"
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": sourceA],
            currentPath: "a.md",
            userDefaults: defaults,
            coherentFileReader: reader
        )
        defer {
            cleanUp(fixture)
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        let appState = fixture.appState
        let session = appState.currentDocument
        let sessionIdentity = ObjectIdentifier(session)
        let documentURL = fixture.rootURL.appendingPathComponent("a.md")
        let identity = try regularIdentity(at: documentURL)
        appState.replaceDocumentText(localSource, in: session)
        appState.pendingExternalTexts[documentURL] = diskB
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: documentURL)
        switch intent {
        case .reload:
            appState.reloadExternallyChangedFile()
        case .keepMine:
            appState.keepMineForExternallyChangedFile()
        }
        try await waitUntil("older external resolution starts") { reader.requestCount == 1 }
        let olderOperation = try XCTUnwrap(appState.externalReloadTasks[sessionIdentity])
        let olderGeneration = olderOperation.diskEventGeneration

        let handle = try FileHandle(forWritingTo: documentURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(diskC.utf8))
        try handle.synchronize()
        try handle.close()
        XCTAssertEqual(try regularIdentity(at: documentURL), identity)

        appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "needle"))
        try await waitUntil("conflicted-overlay search starts") { provider.requests.count == 1 }
        let request = provider.requests[0]
        let fileResult = result(
            path: "a.md",
            text: localSource,
            needle: "needle",
            rootURL: fixture.rootURL
        )
        let match = try XCTUnwrap(fileResult.matches.first)
        provider.yield(.fileResult(context(for: request), fileResult), to: 0)
        try await waitUntil("conflicted-overlay result applies") {
            appState.workspaceSearchState.fileResults == [fileResult]
        }
        let olderNavigation = seedOlderPendingNavigation(in: appState)

        appState.activateWorkspaceSearchResult(
            context: context(for: request),
            fileResult: fileResult,
            match: match
        )

        try await waitUntil("search observation restarts external resolution") {
            reader.requestCount == 2
        }
        let freshOperation = try XCTUnwrap(appState.externalReloadTasks[sessionIdentity])
        XCTAssertEqual(freshOperation.intent, intent)
        XCTAssertGreaterThan(freshOperation.diskEventGeneration, olderGeneration)
        XCTAssertEqual(appState.pendingExternalTexts[documentURL], diskC)
        XCTAssertEqual(appState.pendingExternalFileVersions[documentURL]?.file.text, diskC)
        XCTAssertEqual(appState.editorNavigationCommand, .navigate(olderNavigation))

        reader.resolve(
            request: 0,
            with: .loaded(coherentSnapshot(text: diskB, identity: identity))
        )
        await olderOperation.task.value
        XCTAssertEqual(session.text, localSource)
        XCTAssertEqual(appState.pendingExternalTexts[documentURL], diskC)
        XCTAssertNotNil(appState.externalReloadTasks[sessionIdentity])

        reader.resolve(
            request: 1,
            with: .loaded(coherentSnapshot(text: diskC, identity: identity))
        )
        await freshOperation.task.value
        XCTAssertNil(appState.externalReloadTasks[sessionIdentity])
        XCTAssertNil(appState.pendingExternalTexts[documentURL])
        XCTAssertNil(appState.pendingExternalFileVersions[documentURL])
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertEqual(appState.lastKnownDiskHashes[documentURL], AppState.contentHash(diskC))
        switch intent {
        case .reload:
            XCTAssertEqual(session.text, diskC)
            XCTAssertFalse(session.isDirty)
        case .keepMine:
            XCTAssertEqual(session.text, localSource)
            XCTAssertTrue(session.isDirty)
        }
    }

    // swiftlint:enable function_body_length

    // swiftlint:disable function_body_length
    private func assertSearchObservationSupersedesPendingExternalApplication(
        intent: DeferredExternalChangeResolution
    ) async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let reader = ControlledCoherentFileReader()
        let defaultsSuiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.set(30.0, forKey: "Plainsong.settings.autosaveIntervalSeconds")
        let sourceA = "source A"
        let localSource = "local needle"
        let diskB = "older needle B"
        let diskC = "newer disk C"
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": sourceA],
            currentPath: "a.md",
            userDefaults: defaults,
            coherentFileReader: reader
        )
        let appState = fixture.appState
        let session = appState.currentDocument
        let sessionIdentity = ObjectIdentifier(session)
        let documentURL = fixture.rootURL.appendingPathComponent("a.md")
        let identity = try regularIdentity(at: documentURL)
        let binding = appState.editorDocumentBinding(for: session)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        binding.sourceContract.registerSourceSynchronizer(installation) { _ in false }
        defer {
            binding.sourceContract.unregisterSourceSynchronizer(installation)
            binding.onLifecycle(.revoked(installation))
            cleanUp(fixture)
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }

        appState.replaceDocumentText(localSource, in: session)
        let sourceRevisionBeforeResolution = session.version
        appState.pendingExternalTexts[documentURL] = diskB
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: documentURL)
        switch intent {
        case .reload:
            appState.reloadExternallyChangedFile()
        case .keepMine:
            appState.keepMineForExternallyChangedFile()
        }
        try await waitUntil("older partial external resolution starts") {
            reader.requestCount == 1
        }
        let olderOperation = try XCTUnwrap(appState.externalReloadTasks[sessionIdentity])

        let diskBHandle = try FileHandle(forWritingTo: documentURL)
        try diskBHandle.truncate(atOffset: 0)
        try diskBHandle.write(contentsOf: Data(diskB.utf8))
        try diskBHandle.synchronize()
        try diskBHandle.close()
        XCTAssertEqual(try regularIdentity(at: documentURL), identity)
        reader.resolve(
            request: 0,
            with: .loaded(coherentSnapshot(text: diskB, identity: identity))
        )
        await olderOperation.task.value

        let olderApplication = try XCTUnwrap(
            appState.pendingExternalReloadApplications[sessionIdentity]
        )
        XCTAssertEqual(olderApplication.intent, intent)
        XCTAssertEqual(
            appState.externalResolutionIntentCaptures[documentURL]?.sourceSnapshot.revision,
            sourceRevisionBeforeResolution
        )
        switch intent {
        case .reload:
            XCTAssertEqual(session.text, diskB)
            XCTAssertGreaterThan(session.version, sourceRevisionBeforeResolution)
            XCTAssertEqual(olderApplication.acceptedSourceSnapshot.revision, session.version)
        case .keepMine:
            XCTAssertEqual(session.text, localSource)
            XCTAssertEqual(session.version, sourceRevisionBeforeResolution)
        }

        let searchSource = intent == .reload ? diskB : localSource
        appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "needle"))
        try await waitUntil("partial-application search starts") { provider.requests.count == 1 }
        let request = provider.requests[0]
        let fileResult = result(
            path: "a.md",
            text: searchSource,
            needle: "needle",
            rootURL: fixture.rootURL
        )
        let match = try XCTUnwrap(fileResult.matches.first)
        provider.yield(.fileResult(context(for: request), fileResult), to: 0)
        try await waitUntil("partial-application search result applies") {
            appState.workspaceSearchState.fileResults == [fileResult]
        }

        let diskCHandle = try FileHandle(forWritingTo: documentURL)
        try diskCHandle.truncate(atOffset: 0)
        try diskCHandle.write(contentsOf: Data(diskC.utf8))
        try diskCHandle.synchronize()
        try diskCHandle.close()
        XCTAssertEqual(try regularIdentity(at: documentURL), identity)
        let olderNavigation = seedOlderPendingNavigation(in: appState)

        appState.activateWorkspaceSearchResult(
            context: context(for: request),
            fileResult: fileResult,
            match: match
        )

        try await waitUntil("C observation restarts the partial external resolution") {
            reader.requestCount == 2
        }
        let freshOperation = try XCTUnwrap(appState.externalReloadTasks[sessionIdentity])
        XCTAssertNotEqual(freshOperation.token, olderApplication.token)
        XCTAssertGreaterThan(freshOperation.generation, olderApplication.generation)
        XCTAssertGreaterThan(
            freshOperation.diskEventGeneration,
            olderOperation.diskEventGeneration
        )
        XCTAssertNil(appState.pendingExternalReloadApplications[sessionIdentity])
        XCTAssertEqual(
            appState.externalResolutionIntentCaptures[documentURL]?.sourceSnapshot.revision,
            session.version
        )
        XCTAssertEqual(appState.pendingExternalTexts[documentURL], diskC)
        XCTAssertEqual(appState.pendingExternalFileVersions[documentURL]?.file.text, diskC)
        XCTAssertEqual(appState.editorNavigationCommand, .navigate(olderNavigation))

        binding.sourceContract.registerSourceSynchronizer(installation) { _ in true }
        appState.synchronizePendingExternalReloadIfPossible(for: session)
        XCTAssertNil(appState.pendingExternalReloadApplications[sessionIdentity])
        XCTAssertEqual(appState.pendingExternalTexts[documentURL], diskC)
        XCTAssertEqual(appState.pendingExternalFileVersions[documentURL]?.file.text, diskC)

        reader.resolve(
            request: 1,
            with: .loaded(coherentSnapshot(text: diskC, identity: identity))
        )
        await freshOperation.task.value
        XCTAssertNil(appState.externalReloadTasks[sessionIdentity])
        XCTAssertNil(appState.pendingExternalReloadApplications[sessionIdentity])
        XCTAssertNil(appState.pendingExternalTexts[documentURL])
        XCTAssertNil(appState.pendingExternalFileVersions[documentURL])
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertEqual(appState.lastKnownDiskHashes[documentURL], AppState.contentHash(diskC))
        switch intent {
        case .reload:
            XCTAssertEqual(session.text, diskC)
            XCTAssertFalse(session.isDirty)
        case .keepMine:
            XCTAssertEqual(session.text, localSource)
            XCTAssertTrue(session.isDirty)
        }
    }

    // swiftlint:enable function_body_length

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
        let fileResult = result(
            path: "b.md",
            text: "beta",
            needle: "beta",
            rootURL: fixture.rootURL
        )
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

    private func activateAndAssertNavigationUnchanged(
        _ scenario: AcceptedActivationScenario,
        olderNavigation: EditorNavigationRequest
    ) {
        scenario.fixture.appState.activateWorkspaceSearchResult(
            context: scenario.context,
            fileResult: scenario.fileResult,
            match: scenario.match
        )
        XCTAssertEqual(
            scenario.fixture.appState.editorNavigationCommand,
            .navigate(olderNavigation)
        )
    }

    private struct EditorBridgeFixture {
        let window: NSWindow
        let scrollView: NSScrollView
        let textView: MarkdownSTTextView
        let coordinator: MarkdownTextViewCoordinator
    }

    private func makeEditorBridgeFixture(
        representable: MarkdownTextView,
        source: String,
        makeKey: Bool = true
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
        if makeKey {
            window.makeKeyAndOrderFront(nil)
        }
        representable.updateRepresentedTextView(scrollView, coordinator: coordinator)
        return EditorBridgeFixture(
            window: window,
            scrollView: scrollView,
            textView: textView,
            coordinator: coordinator
        )
    }

    private struct SearchSidebarHost {
        let window: NSWindow
        let hostingView: NSHostingView<AnyView>
    }

    /// Hosts the full Files/Search sidebar shell (starts in Files unless mode already changed).
    private func makeWorkspaceSidebarHost(
        appState: AppState,
        makeKey: Bool
    ) async throws -> SearchSidebarHost {
        let root = WorkspaceSidebar()
            .environmentObject(appState)
            .frame(width: 280, height: 420)
        let hostingView = NSHostingView(rootView: AnyView(root))
        hostingView.frame = NSRect(x: 0, y: 0, width: 280, height: 420)
        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 280, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        if makeKey {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
        // Let SwiftUI install the shell; Search field is not required yet (Files mode).
        try await Task.sleep(nanoseconds: 30_000_000)
        return SearchSidebarHost(window: window, hostingView: hostingView)
    }

    /// Hosts `WorkspaceSearchSidebar` only (already on Search). Used for mid-flight key routing.
    private func makeSearchSidebarHost(
        appState: AppState,
        makeKey: Bool
    ) async throws -> SearchSidebarHost {
        let root = WorkspaceSearchSidebar()
            .environmentObject(appState)
            .frame(width: 280, height: 360)
        let hostingView = NSHostingView(rootView: AnyView(root))
        hostingView.frame = NSRect(x: 0, y: 0, width: 280, height: 360)
        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 280, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        if makeKey {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }

        try await waitUntil("search text field mounts in hosted window") {
            WorkspaceSearchFieldFocus.findSearchTextField(in: window.contentView) != nil
        }
        return SearchSidebarHost(window: window, hostingView: hostingView)
    }

    /// XCTest hosts often cannot acquire real `NSWindow.isKeyWindow`. Route focus eligibility
    /// through a designated-window override that still exercises live post-await re-queries.
    private func installDesignatedKeyWindowRouting(
        on appState: AppState,
        designatedKeyWindow: NSWindow
    ) {
        let designated = designatedKeyWindow
        appState.workspaceSearchFocusKeyWindowCheck = { window in
            window === designated
        }
        appState.refreshWorkspaceSearchFocusKeyRouting()
    }

    private struct Fixture {
        let appState: AppState
        let rootURL: URL
        let snapshot: WorkspaceFileSnapshot
    }

    private enum ReusableSearchSessionStorage {
        case cached
        case retired
    }

    private enum TestError: Error {
        case expectedEditorNavigation
        case expectedRegularFile
    }

    // swiftlint:disable:next function_body_length
    private func assertReusableSearchHardLinkCollisionIsAccountedFor(
        _ storage: ReusableSearchSessionStorage
    ) async throws {
        let provider = ControlledWorkspaceSearchStreamProvider()
        let reader = ControlledCoherentFileReader()
        let ownerText = "owner A needle"
        let retainedText = "retained B"
        let fixture = try makeFixture(
            provider: provider,
            files: ["a.md": ownerText, "b.md": retainedText],
            currentPath: "a.md",
            coherentFileReader: reader
        )
        defer { cleanUp(fixture) }
        let appState = fixture.appState
        let ownerSession = appState.currentDocument
        let ownerURL = fixture.rootURL.appendingPathComponent("a.md")
        let retainedURL = fixture.rootURL.appendingPathComponent("b.md")
        let rootAuthority = try XCTUnwrap(appState.workspaceSearchRootAuthority)
        let retainedLocation = try rootAuthority.canonicalizedLocation(forFileURL: retainedURL)
        let retainedRead = try MarkdownFileStore().loadResult(at: retainedLocation)
        let retainedSession = DocumentSession(
            text: retainedText,
            url: retainedLocation.fileURL,
            fileKind: .markdown
        )
        let retainedSessionIdentity = ObjectIdentifier(retainedSession)
        let retainedBinding = AnchoredWorkspaceSessionFileBinding(
            location: retainedLocation,
            identity: retainedRead.metadata.identity,
            sha256Digest: retainedRead.sha256Digest
        )
        appState.adoptAnchoredFileBinding(retainedBinding, for: retainedSession)
        switch storage {
        case .cached:
            appState.sessionCache[retainedLocation.fileURL] = retainedSession
        case .retired:
            appState.retiredEditorDocumentSessions[retainedLocation.fileURL] =
                RetiredEditorDocumentSession(
                    canonicalURL: retainedLocation.fileURL,
                    session: retainedSession,
                    bindingIDs: [],
                    awaitingInstallations: [],
                    securityScopedAuthorityOwners: []
                )
        }

        appState.handleExternalChange(for: retainedSession)
        try await waitUntil("older retained B inspection starts") { reader.requestCount == 1 }
        let olderInspection = try XCTUnwrap(
            appState.externalDiskInspectionTasks[retainedSessionIdentity]
        )
        let olderGeneration = olderInspection.diskEventGeneration

        try FileManager.default.removeItem(at: retainedURL)
        try FileManager.default.linkItem(at: ownerURL, to: retainedURL)
        let ownerIdentity = try regularIdentity(at: ownerURL)
        XCTAssertEqual(try regularIdentity(at: retainedURL), ownerIdentity)
        XCTAssertNotEqual(ownerIdentity, retainedBinding.identity)

        appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "needle"))
        try await waitUntil("hard-link replacement search starts") {
            provider.requests.count == 1
        }
        let request = provider.requests[0]
        let fileResult = result(
            path: "b.md",
            text: ownerText,
            needle: "needle",
            rootURL: fixture.rootURL
        )
        let match = try XCTUnwrap(fileResult.matches.first)
        provider.yield(.fileResult(context(for: request), fileResult), to: 0)
        try await waitUntil("hard-link replacement result applies") {
            appState.workspaceSearchState.fileResults == [fileResult]
        }
        let olderNavigation = seedOlderPendingNavigation(in: appState)

        appState.activateWorkspaceSearchResult(
            context: context(for: request),
            fileResult: fileResult,
            match: match
        )

        XCTAssertTrue(appState.currentDocument === ownerSession)
        XCTAssertEqual(retainedSession.text, retainedText)
        XCTAssertTrue(retainedSession.isDirty)
        XCTAssertTrue(appState.detachedSessionURLs.contains(retainedLocation.fileURL))
        XCTAssertEqual(
            appState.anchoredSessionFileBinding(for: retainedSession),
            retainedBinding
        )
        XCTAssertNil(appState.externalDiskInspectionTasks[retainedSessionIdentity])
        XCTAssertTrue(olderInspection.task.isCancelled)
        XCTAssertEqual(
            appState.currentExternalDiskEventGeneration(for: retainedSession),
            olderGeneration + 1
        )
        XCTAssertNil(appState.pendingExternalTexts[retainedLocation.fileURL])
        XCTAssertNil(appState.pendingExternalFileVersions[retainedLocation.fileURL])
        XCTAssertEqual(appState.editorNavigationCommand, .navigate(olderNavigation))
        XCTAssertFalse(appState.canAutosave(session: retainedSession))
        XCTAssertThrowsError(try appState.save(session: retainedSession))
        switch storage {
        case .cached:
            XCTAssertTrue(appState.sessionCache[retainedLocation.fileURL] === retainedSession)
        case .retired:
            XCTAssertTrue(
                appState.retiredEditorDocumentSessions[retainedLocation.fileURL]?.session ===
                    retainedSession
            )
        }

        reader.resolve(
            request: 0,
            with: .loaded(coherentSnapshot(
                text: retainedText,
                identity: retainedBinding.identity
            ))
        )
        await olderInspection.task.value

        XCTAssertEqual(retainedSession.text, retainedText)
        XCTAssertTrue(retainedSession.isDirty)
        XCTAssertTrue(appState.detachedSessionURLs.contains(retainedLocation.fileURL))
        XCTAssertEqual(
            appState.anchoredSessionFileBinding(for: retainedSession),
            retainedBinding
        )
        XCTAssertNil(appState.externalDiskInspectionTasks[retainedSessionIdentity])
        XCTAssertNil(appState.pendingExternalTexts[retainedLocation.fileURL])
        XCTAssertNil(appState.pendingExternalFileVersions[retainedLocation.fileURL])
        XCTAssertEqual(try String(contentsOf: retainedURL, encoding: .utf8), ownerText)
    }

    // swiftlint:disable:next function_body_length
    private func assertDeferredSymlinkSubstitutionDoesNotFollow(
        intent: DeferredExternalChangeResolution,
        race: SaveCopySymlinkRace,
        targetOutsideWorkspace: Bool
    ) async throws {
        let outerURL = try makeTemporaryDirectory()
        let rootURL = outerURL.appendingPathComponent("workspace", isDirectory: true)
        let ownedParentURL = rootURL.appendingPathComponent("owned", isDirectory: true)
        let movedParentURL = rootURL.appendingPathComponent(
            "owned-original",
            isDirectory: true
        )
        let targetParentURL = targetOutsideWorkspace
            ? outerURL.appendingPathComponent("outside-target", isDirectory: true)
            : rootURL.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(
            at: ownedParentURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: targetParentURL,
            withIntermediateDirectories: true
        )
        let documentAURL = ownedParentURL.appendingPathComponent("a.md")
        let documentBURL = targetParentURL.appendingPathComponent("a.md")
        let sourceA = "A local source: "
        let externalA = "A changed on disk"
        let sentinelB = targetOutsideWorkspace
            ? "outside B sentinel"
            : "workspace B sentinel"
        try sourceA.write(to: documentAURL, atomically: true, encoding: .utf8)
        try sentinelB.write(to: documentBURL, atomically: true, encoding: .utf8)

        let sessionA = DocumentSession(text: sourceA, url: documentAURL, fileKind: .markdown)
        let sessionB = DocumentSession(text: sentinelB, url: documentBURL, fileKind: .markdown)
        let appState = AppState(currentDocument: sessionA, shouldRestoreLastOpenedFile: false)
        configureWorkspace(
            appState,
            rootURL: rootURL,
            paths: targetOutsideWorkspace
                ? ["owned/a.md"]
                : ["owned/a.md", "target/a.md"],
            currentSession: sessionA,
            retainSecurityScope: true
        )
        let canonicalA = try XCTUnwrap(appState.sessionStateURL(for: sessionA))
        let locationB = try WorkspaceFileSystemLocation(fileURL: documentBURL)
        let loadedB = try MarkdownFileStore().loadResult(at: locationB)
        appState.retainUnanchoredManagedSessionOwnership(
            for: sessionB,
            location: locationB,
            identity: loadedB.metadata.identity,
            sha256Digest: loadedB.sha256Digest
        )
        let canonicalB = locationB.fileURL
        appState.sessionCache[canonicalB] = sessionB
        appState.recordKnownDiskText(sourceA, for: canonicalA)
        appState.recordKnownDiskText(sentinelB, for: canonicalB)

        let bindingA = appState.editorDocumentBinding(for: sessionA)
        var selectionA: NSRange? = NSRange(location: (sourceA as NSString).length, length: 0)
        let viewA = MarkdownTextView(
            text: bindingA.text,
            styledText: nil,
            selection: Binding(get: { selectionA }, set: { selectionA = $0 }),
            showsLineNumbers: false,
            documentIdentity: AppState.editorDocumentIdentity(for: canonicalA),
            documentBindingID: bindingA.id,
            onDocumentBindingLifecycle: bindingA.onLifecycle,
            documentSourceContract: bindingA.sourceContract
        )
        let fixture = try makeEditorBridgeFixture(representable: viewA, source: sourceA)
        defer {
            fixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
            if appState.missingFilePrompt != nil {
                appState.closeMissingFile()
            }
            try? FileManager.default.removeItem(at: outerURL)
        }

        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.textSelection = selectionA ?? .notFound
        fixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        try externalA.write(to: canonicalA, atomically: true, encoding: .utf8)
        appState.lastKnownDiskModificationDates[canonicalA] = .distantPast
        appState.handleExternalChange(for: sessionA)
        try await waitUntil("anchored detection records the external conflict") {
            appState.pendingExternalTexts[canonicalA] == externalA
        }
        XCTAssertEqual(appState.pendingExternalTexts[canonicalA], externalA)

        switch intent {
        case .reload:
            appState.reloadExternallyChangedFile()
        case .keepMine:
            appState.keepMineForExternallyChangedFile()
        }
        XCTAssertEqual(appState.deferredExternalChangeResolutions[canonicalA], intent)
        XCTAssertNil(appState.deferredExternalChangeResolutions[canonicalB])

        switch race {
        case .leaf:
            try FileManager.default.removeItem(at: documentAURL)
            try FileManager.default.createSymbolicLink(
                at: documentAURL,
                withDestinationURL: documentBURL
            )
            XCTAssertEqual(
                WorkspaceNoFollowFileInspector.status(at: canonicalA),
                .symbolicLink
            )
        case .intermediate:
            try FileManager.default.moveItem(at: ownedParentURL, to: movedParentURL)
            try FileManager.default.createSymbolicLink(
                at: ownedParentURL,
                withDestinationURL: targetParentURL
            )
        }
        try appState.closeWorkspaceForReplacement()
        XCTAssertTrue(appState.retiredEditorDocumentSessions[canonicalA]?.session === sessionA)
        XCTAssertNil(appState.retiredEditorDocumentSessions[canonicalB])

        fixture.textView.insertText("臺", replacementRange: .notFound)
        let committedA = sourceA + "臺"
        try await waitUntil("accepted input stale-drops the selection-time resolution") {
            sessionA.text == committedA &&
                appState.deferredExternalChangeResolutions[canonicalA] == nil &&
                appState.externalReloadTasks[ObjectIdentifier(sessionA)] == nil &&
                appState.externalChangePrompt?.fileURL == canonicalA
        }
        XCTAssertFalse(appState.detachedSessionURLs.contains(canonicalA))

        switch intent {
        case .reload:
            appState.reloadExternallyChangedFile()
        case .keepMine:
            appState.keepMineForExternallyChangedFile()
        }
        try await waitUntil("symlink substitution enters A recovery") {
            appState.detachedSessionURLs.contains(canonicalA) &&
                appState.externalReloadTasks[ObjectIdentifier(sessionA)] == nil
        }

        XCTAssertEqual(sessionA.text, committedA)
        XCTAssertEqual(try String(contentsOf: canonicalB, encoding: .utf8), sentinelB)
        XCTAssertEqual(appState.sessionStateURL(for: sessionA), canonicalA)
        XCTAssertEqual(appState.missingFilePrompt?.fileURL, canonicalA)
        XCTAssertNil(appState.externalChangePrompt)
        XCTAssertNil(appState.pendingExternalTexts[canonicalB])
        XCTAssertNil(appState.deferredExternalChangeResolutions[canonicalB])
        XCTAssertTrue(appState.editorBindingInstallations.values.contains { $0 === sessionA })
        XCTAssertFalse(appState.canAutosave(session: sessionA))
        XCTAssertThrowsError(try appState.save(session: sessionA))
        appState.flushAutosaveIfNeeded()
        XCTAssertEqual(try String(contentsOf: canonicalB, encoding: .utf8), sentinelB)
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
        let rootAuthority = try? WorkspaceFileSystemRootAuthority(
            rootURL: rootURL
        )
        appState.workspaceSearchRootAuthority = rootAuthority
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
        if let fileURL = currentSession.fileURL,
           let rootAuthority,
           let location = try? rootAuthority.canonicalizedLocation(forFileURL: fileURL),
           let loaded = try? MarkdownFileStore().loadResult(at: location)
        {
            appState.adoptAnchoredFileBinding(
                AnchoredWorkspaceSessionFileBinding(
                    location: location,
                    identity: loaded.metadata.identity,
                    sha256Digest: loaded.sha256Digest
                ),
                for: currentSession
            )
            appState.sessionCache[location.fileURL] = currentSession
            _ = appState.sessionPolicy.access(location.fileURL, isDirty: currentSession.isDirty)
        }
    }

    private func makeFixture(
        provider: ControlledWorkspaceSearchStreamProvider,
        files: [String: String],
        currentPath: String? = nil,
        debounceNanoseconds: UInt64 = 0,
        userDefaults: UserDefaults = .standard,
        coherentFileReader: any WorkspaceCoherentFileReading = WorkspaceCoherentFileReader(),
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
            coherentFileReader: coherentFileReader,
            directoryScanner: directoryScanner,
            workspaceSearchStreamProvider: provider,
            workspaceSearchDebounceNanoseconds: debounceNanoseconds,
            shouldRestoreLastOpenedFile: false,
            userDefaults: userDefaults
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
        for task in fixture.appState.sessionAutosaveTasks.values {
            task.task.cancel()
        }
        for task in fixture.appState.sessionStatisticsTasks.values {
            task.task.cancel()
        }
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
        truncated: Bool = false,
        rootURL: URL? = nil
    ) -> WorkspaceSearchFileResult {
        let range = (text as NSString).range(of: needle)
        let fileAuthority: WorkspaceSearchFileAuthority? = if let rootURL {
            makeSearchFileAuthority(rootURL: rootURL, relativePath: path)
        } else {
            nil
        }
        return WorkspaceSearchFileResult(
            relativePath: path,
            contentFingerprint: WorkspaceSearchContentFingerprint(text: text),
            matches: [TextSearchMatch(
                range: range,
                line: 1,
                preview: text,
                previewMatchRange: range
            )],
            isTruncated: truncated,
            fileAuthority: fileAuthority
        )
    }

    /// All non-overlapping occurrences of `needle` (for keyboard no-wrap smoke).
    private func multiMatchResult(
        path: String,
        text: String,
        needle: String,
        rootURL: URL
    ) -> WorkspaceSearchFileResult {
        let ns = text as NSString
        var matches: [TextSearchMatch] = []
        var searchRange = NSRange(location: 0, length: ns.length)
        while searchRange.length > 0 {
            let found = ns.range(of: needle, options: [], range: searchRange)
            if found.location == NSNotFound { break }
            let line = ns.substring(to: found.location).components(separatedBy: .newlines).count
            matches.append(
                TextSearchMatch(
                    range: found,
                    line: line,
                    preview: ns.substring(with: found),
                    previewMatchRange: NSRange(location: 0, length: found.length)
                )
            )
            let next = found.location + max(found.length, 1)
            searchRange = NSRange(location: next, length: max(0, ns.length - next))
        }
        return WorkspaceSearchFileResult(
            relativePath: path,
            contentFingerprint: WorkspaceSearchContentFingerprint(text: text),
            matches: matches,
            isTruncated: false,
            fileAuthority: makeSearchFileAuthority(rootURL: rootURL, relativePath: path)
        )
    }

    private func makeSearchFileAuthority(
        rootURL: URL,
        relativePath: String
    ) -> WorkspaceSearchFileAuthority? {
        guard let authority = try? WorkspaceFileSystemRootAuthority(
            rootURL: rootURL,
            securityScopedURL: rootURL
        ),
            let location = try? authority.location(relativePath: relativePath),
            case let .regular(identity) = WorkspaceNoFollowFileInspector.status(at: location)
        else {
            return nil
        }
        return WorkspaceSearchFileAuthority(location: location, identity: identity)
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
        return try WorkspaceFileSystemRootAuthority(rootURL: url).canonicalRootURL
    }

    private func regularIdentity(at url: URL) throws -> WorkspaceFileSystemIdentity {
        guard case let .regular(identity) = WorkspaceNoFollowFileInspector.status(at: url) else {
            throw TestError.expectedRegularFile
        }
        return identity
    }

    private func coherentSnapshot(
        text: String,
        identity: WorkspaceFileSystemIdentity
    ) -> WorkspaceCoherentFileSnapshot {
        let bytes = Data(text.utf8)
        return WorkspaceCoherentFileSnapshot(
            text: text,
            exactBytes: bytes,
            sha256Digest: WorkspaceSearchContentFingerprint(text: text).sha256Digest,
            metadata: WorkspaceCoherentFileMetadata(
                identity: identity,
                byteCount: Int64(bytes.count),
                modificationSeconds: 1_700_000_000,
                modificationNanoseconds: 123,
                changeSeconds: 1_700_000_000,
                changeNanoseconds: 456
            )
        )
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

private final class ControlledCoherentFileReader: WorkspaceCoherentFileReading, @unchecked Sendable {
    private struct Request {
        let url: URL
        let continuation: CheckedContinuation<WorkspaceCoherentFileReadOutcome, Never>
    }

    private let lock = NSLock()
    private var requests: [Request] = []

    var requestCount: Int {
        lock.withLock { requests.count }
    }

    func readCoherentFile(at url: URL) async -> WorkspaceCoherentFileReadOutcome {
        await withCheckedContinuation { continuation in
            lock.withLock {
                requests.append(Request(url: url, continuation: continuation))
            }
        }
    }

    func resolve(request index: Int, with outcome: WorkspaceCoherentFileReadOutcome) {
        let continuation = lock.withLock { requests[index].continuation }
        continuation.resume(returning: outcome)
    }
}

private final class ExternalReloadPreparationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var began = false
    private var finishedAt: UInt64?
    private var invocationCount = 0
    private var finishedCount = 0

    var hasBegun: Bool {
        lock.withLock { began }
    }

    var finishedUptimeNanoseconds: UInt64? {
        lock.withLock { finishedAt }
    }

    var successfulPreparationCount: Int {
        lock.withLock { finishedCount }
    }

    func beginAndWait() {
        let shouldWait = lock.withLock {
            began = true
            invocationCount += 1
            return invocationCount == 1
        }
        if shouldWait {
            gate.wait()
        }
    }

    func release() {
        gate.signal()
    }

    func finish() {
        lock.withLock {
            finishedCount += 1
            finishedAt = DispatchTime.now().uptimeNanoseconds
        }
    }
}

private final class EditorImageAssetDiscardGate: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var began = false

    var hasBegun: Bool {
        lock.withLock { began }
    }

    func beginAndWait() {
        lock.withLock { began = true }
        gate.wait()
    }

    func release() {
        gate.signal()
    }
}

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

private enum SaveCopySymlinkRace {
    case intermediate
    case leaf
}

private final class SymlinkSubstitutingWorkspaceAnchoredFileWriter: @unchecked Sendable {
    private let backingStore = MarkdownFileStore()
    private let race: SaveCopySymlinkRace
    private let destinationURL: URL
    private let destinationParentURL: URL
    private let movedParentURL: URL
    private let symlinkTargetURL: URL
    private let lock = NSLock()
    private var hasSubstituted = false

    init(
        race: SaveCopySymlinkRace,
        destinationURL: URL,
        destinationParentURL: URL,
        movedParentURL: URL,
        symlinkTargetURL: URL
    ) {
        self.race = race
        self.destinationURL = destinationURL
        self.destinationParentURL = destinationParentURL
        self.movedParentURL = movedParentURL
        self.symlinkTargetURL = symlinkTargetURL
    }

    func save(
        text: String,
        to location: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceNoFollowFileWriteExpectation
    ) throws -> WorkspaceFileWriteOutcome {
        let shouldSubstitute = lock.withLock {
            guard !hasSubstituted else { return false }
            hasSubstituted = true
            return true
        }
        if shouldSubstitute {
            switch race {
            case .intermediate:
                try FileManager.default.moveItem(
                    at: destinationParentURL,
                    to: movedParentURL
                )
                try FileManager.default.createSymbolicLink(
                    at: destinationParentURL,
                    withDestinationURL: symlinkTargetURL
                )
            case .leaf:
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.createSymbolicLink(
                    at: destinationURL,
                    withDestinationURL: symlinkTargetURL
                )
            }
        }
        return try backingStore.save(text: text, at: location, expecting: expectation)
    }
}

private final class FailingOnceWorkspaceAnchoredFileWriter: @unchecked Sendable {
    private enum SaveFailure: LocalizedError {
        case injected

        var errorDescription: String? {
            "Injected first-save failure"
        }
    }

    private let backingStore = MarkdownFileStore()
    private let lock = NSLock()
    private var shouldFailNextSave = true
    private var saveAttempts = 0

    var writeAttemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return saveAttempts
    }

    func save(
        text: String,
        to location: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceNoFollowFileWriteExpectation
    ) throws -> WorkspaceFileWriteOutcome {
        let shouldFail: Bool
        lock.lock()
        saveAttempts += 1
        shouldFail = shouldFailNextSave
        shouldFailNextSave = false
        lock.unlock()

        if shouldFail {
            throw SaveFailure.injected
        }
        return try backingStore.save(text: text, at: location, expecting: expectation)
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

@MainActor
private final class WorkspaceSearchSmokeKeyView: NSView {
    override var acceptsFirstResponder: Bool {
        true
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
    private(set) var savedURLs: [URL] = []

    init(saveError: Error? = nil, restoredURLs: [URL] = []) {
        self.saveError = saveError
        self.restoredURLs = restoredURLs
    }

    func save(_ url: URL) throws {
        if let saveError {
            throw saveError
        }
        savedURLs.append(url)
    }

    func restore() throws -> [URL] {
        restoredURLs
    }
}
