import AppKit
import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// In-document find against the real document lifecycle: External Reload, rename, and
/// Save Copy (including the indeterminate quarantine rehome).
///
/// These drive production entry points rather than the `notifyEditorFind*` hooks directly,
/// so a hook wired at the wrong point in a transaction is visible here.
@MainActor
final class EditorFindLifecycleCombinationTests: XCTestCase {
    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorFindLifecycle")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL
    }

    private func openFindBar(_ appState: AppState, query: String) {
        appState.editorFindHost.controller.debounceNanoseconds = 0
        appState.editorFindHost.commandContextOverride = true
        var ui = appState.editorFindHost.ui
        ui.isBarVisible = true
        ui.queryText = query
        appState.setEditorFindUI(ui)
        appState.ensureEditorFindSessionObserverInstalled()
        appState.syncEditorFindControllerDocument()
        appState.pushEditorFindQueryToController()
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 3,
        predicate: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func findIdentity(_ appState: AppState) -> EditorDocumentIdentity? {
        appState.editorFindHost.controller.documentBinding.identity
    }

    // MARK: - External Reload

    func testCleanExternalReloadRecountsFindWithoutAutoJumping() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let post = root.appendingPathComponent("post.md")
        try "hit one".write(to: post, atomically: true, encoding: .utf8)
        let appState = AppState(shouldRestoreLastOpenedFile: false)

        appState.openExternalFile(root)
        try await waitUntil("post selected") {
            appState.currentDocument.fileURL?.standardizedFileURL == post.standardizedFileURL
        }
        openFindBar(appState, query: "hit")
        try await waitUntil("initial session") {
            appState.editorFindHost.controller.session?.total == 1
        }
        appState.editorNavigationCommand = nil

        try "hit one hit two hit three".write(to: post, atomically: true, encoding: .utf8)
        appState.refreshWorkspaceAfterFileSystemChange()

        try await waitUntil("clean reload adopted") {
            appState.currentDocument.text == "hit one hit two hit three"
        }
        try await waitUntil("find recounts against reloaded content") {
            appState.editorFindHost.controller.session?.total == 3
        }
        XCTAssertEqual(
            appState.editorFindHost.controller.documentBinding.text,
            "hit one hit two hit three"
        )
        XCTAssertNil(
            appState.editorFindHost.controller.pendingNavigationCommand,
            "External Reload recomputes the counter only; it must not move the selection"
        )
        if case .navigate = appState.editorNavigationCommand {
            XCTFail("External Reload must not publish a find navigation")
        }
    }

    func testKeepMineAfterExternalChangeLeavesFindOnTheLocalSource() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let post = root.appendingPathComponent("post.md")
        try "hit one".write(to: post, atomically: true, encoding: .utf8)
        let appState = AppState(shouldRestoreLastOpenedFile: false)

        appState.openExternalFile(root)
        try await waitUntil("post selected") {
            appState.currentDocument.fileURL?.standardizedFileURL == post.standardizedFileURL
        }
        appState.replaceDocumentText("hit local hit local")
        openFindBar(appState, query: "hit")
        try await waitUntil("local session") {
            appState.editorFindHost.controller.session?.total == 2
        }

        try "hit disk hit disk hit disk".write(to: post, atomically: true, encoding: .utf8)
        appState.refreshWorkspaceAfterFileSystemChange()
        try await waitUntil("conflict prompted") {
            appState.externalChangePrompt?.fileURL.standardizedFileURL == post.standardizedFileURL
        }

        appState.keepMineForExternallyChangedFile()
        try await waitUntil("prompt resolved") { appState.externalChangePrompt == nil }
        XCTAssertEqual(appState.currentDocument.text, "hit local hit local")
        try await waitUntil("find still counts the retained local source") {
            appState.editorFindHost.controller.session?.total == 2
        }
        XCTAssertEqual(
            appState.editorFindHost.controller.documentBinding.text,
            "hit local hit local"
        )
    }

    // MARK: - Rename

    func testRenameRekeysFindIdentityToTheNewURL() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let post = root.appendingPathComponent("post.md")
        try "hit one hit two".write(to: post, atomically: true, encoding: .utf8)
        let appState = AppState(shouldRestoreLastOpenedFile: false)

        appState.openExternalFile(root)
        try await waitUntil("post selected") {
            appState.currentDocument.fileURL?.standardizedFileURL == post.standardizedFileURL
        }
        openFindBar(appState, query: "hit")
        try await waitUntil("session ready") {
            appState.editorFindHost.controller.session?.total == 2
        }
        let originalIdentity = try XCTUnwrap(findIdentity(appState))

        let nodeID = try XCTUnwrap(
            appState.workspaceTree?.root.children.first { $0.relativePath == "post.md" }?.id
        )
        appState.renameWorkspaceItem(id: nodeID, to: "renamed.md")

        let renamed = root.appendingPathComponent("renamed.md").standardizedFileURL
        try await waitUntil("session relocated") {
            appState.currentDocument.fileURL?.standardizedFileURL == renamed
        }
        try await waitUntil("find identity tracks the new URL") {
            self.findIdentity(appState) != originalIdentity
        }
        XCTAssertEqual(
            findIdentity(appState),
            appState.activeEditorDocumentIdentity,
            "Find must bind to the identity App now uses for this session"
        )
        try await waitUntil("query still counts after rename") {
            appState.editorFindHost.controller.session?.total == 2
        }
        XCTAssertEqual(appState.editorFindHost.ui.queryText, "hit")
    }

    // MARK: - Save Copy

    func testDetachedSaveCopyRekeysFindToTheDestination() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("missing.md").standardizedFileURL
        let destinationURL = root.appendingPathComponent("recovered.md").standardizedFileURL
        let session = DocumentSession(
            text: "hit one hit two",
            url: sourceURL,
            fileKind: .markdown,
            isDirty: true
        )
        let appState = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        appState.missingFilePrompt = AppState.MissingFilePrompt(fileURL: sourceURL)
        openFindBar(appState, query: "hit")
        try await waitUntil("session ready") {
            appState.editorFindHost.controller.session?.total == 2
        }
        let originalIdentity = try XCTUnwrap(findIdentity(appState))

        try appState.saveDetachedCurrentDocument(to: destinationURL)

        XCTAssertEqual(appState.currentDocument.fileURL?.standardizedFileURL, destinationURL)
        try await waitUntil("find identity tracks the Save Copy destination") {
            self.findIdentity(appState) != originalIdentity
        }
        XCTAssertEqual(findIdentity(appState), appState.activeEditorDocumentIdentity)
        XCTAssertEqual(
            findIdentity(appState)?.rawValue,
            AppState.editorDocumentIdentity(for: destinationURL).rawValue
        )
    }

    func testIndeterminateSaveCopyQuarantineRekeysFindToTheQuarantinedLocation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("missing.md").standardizedFileURL
        try "missing A".write(to: sourceURL, atomically: true, encoding: .utf8)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let missingLocation = try authority.location(relativePath: "missing.md")
        let missingURL = missingLocation.fileURL
        let destinationURL = try authority.location(relativePath: "recovered.md").fileURL
        let missingRead = try MarkdownFileStore().loadResult(at: missingLocation)
        let session = DocumentSession(
            text: "hit one hit two",
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

        openFindBar(appState, query: "hit")
        try await waitUntil("session ready") {
            appState.editorFindHost.controller.session?.total == 2
        }
        let originalIdentity = try XCTUnwrap(findIdentity(appState))
        XCTAssertEqual(originalIdentity.rawValue, missingURL.absoluteString)

        appState.anchoredFileSaveOverride = { text, location, _ in
            let actual = try MarkdownFileStore().save(
                text: text,
                at: location,
                expecting: .missing
            )
            guard case let .committedAndDurable(durable) = actual else {
                XCTFail("Expected deterministic destination commit")
                return actual
            }
            return .committedButIndeterminate(
                WorkspaceIndeterminateFileWrite(
                    reason: .durabilityFailed,
                    preparedMetadata: durable.metadata,
                    recoveryArtifact: .retained(location)
                )
            )
        }

        XCTAssertThrowsError(try appState.saveDetachedCurrentDocument(to: destinationURL))

        // The session is rehomed to the quarantined destination; Find must follow it.
        XCTAssertEqual(appState.currentDocument.fileURL?.standardizedFileURL, destinationURL)
        XCTAssertEqual(
            appState.indeterminateSessionWriteContexts[ObjectIdentifier(session)]?.location.fileURL,
            destinationURL
        )
        try await waitUntil("find identity leaves the pre-quarantine URL") {
            self.findIdentity(appState) != originalIdentity
        }
        XCTAssertEqual(
            findIdentity(appState),
            appState.activeEditorDocumentIdentity,
            "Find must use the identity the quarantined session now owns"
        )
        XCTAssertEqual(findIdentity(appState)?.rawValue, destinationURL.absoluteString)
    }
}
