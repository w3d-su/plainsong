import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// Windows PR D2: an empty window's untouched document owns no file, so it must not make
/// Save Copy or export fail closed in another window (`docs/window-state-gates.md` W3 bullet 5
/// evidence). Every other file-less document still does.
@MainActor
final class WindowEmptyDocumentOwnershipAppTests: XCTestCase {
    override func tearDown() async throws {
        KeyWindowRouter.shared.resetForTesting()
        WindowOpenAdmission.resetForTesting()
    }

    func testAnEmptyAdmittedWindowDoesNotBlockSaveCopyOrExport() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let appState = fixture.appState
        _ = try fixture.showDetachedSessionInSharedWindow()
        let empty = appState.makeSiblingFacade(admitsFileOperations: true)
        XCTAssertTrue(appState.registry.connectedWindows.contains { $0 === empty.windowState })
        XCTAssertEqual(
            appState.unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(empty.shownSession)],
            .unavailable(fileURL: nil)
        )
        XCTAssertTrue(appState.isPristineEmptyDocument(empty.shownSession))
        XCTAssertTrue(empty.isEmptyWorkspaceWindow)
        XCTAssertFalse(appState.workspaceSaveCopyOwnershipCandidates().contains { $0 === empty.shownSession })
        XCTAssertTrue(
            appState.workspaceMutationTerminationSessions().contains { $0 === empty.shownSession },
            "termination still sees every window's document"
        )

        XCTAssertNil(appState.exportHTMLOwnershipStopReason())
        XCTAssertNoThrow(
            try appState.saveDetachedCurrentDocument(to: fixture.root.appendingPathComponent("copy.md"))
        )
    }

    func testTheOwnersLaunchBlankDoesNotBlockASiblingsSaveCopy() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let owner = fixture.appState
        let launchBlank = DocumentSession()
        owner.shownSession = launchBlank
        owner.retainUnanchoredManagedSessionOwnership(for: launchBlank)
        XCTAssertTrue(owner.isPristineEmptyDocument(launchBlank))
        let sibling = owner.makeSiblingFacade(admitsFileOperations: true)
        try showDetachedSession(in: sibling, fixture: fixture)

        XCTAssertNoThrow(
            try sibling.saveDetachedCurrentDocument(to: fixture.root.appendingPathComponent("copy.md"))
        )
    }

    /// Text, an edit later undone, an unavailable proof that names a file, or an editor
    /// binding keeps a file-less document a fail-closed candidate.
    func testAFileLessDocumentWithAnyHistoryStillFailsClosed() throws {
        let cases: [(String, @MainActor (AppState, DocumentSession) -> Void)] = [
            ("text", { _, session in session.replaceText("draft") }),
            ("edited back to empty", { _, session in
                session.replaceText("x")
                session.replaceText("")
            }),
            ("unavailable proof naming a file", { appState, session in
                appState.unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(session)] =
                    .unavailable(fileURL: URL(fileURLWithPath: "/tmp/elsewhere.md"))
            }),
            ("editor binding", { appState, session in
                _ = appState.editorDocumentBinding(for: session)
            }),
        ]
        for (name, mutate) in cases {
            let fixture = try SecondWindowRegistryFixture.make(testCase: self)
            let appState = fixture.appState
            _ = try fixture.showDetachedSessionInSharedWindow()
            let sibling = appState.makeSiblingFacade(admitsFileOperations: true)
            mutate(appState, sibling.shownSession)

            XCTAssertFalse(appState.isPristineEmptyDocument(sibling.shownSession), name)
            XCTAssertFalse(sibling.isEmptyWorkspaceWindow, name)
            XCTAssertTrue(
                appState.workspaceSaveCopyOwnershipCandidates().contains { $0 === sibling.shownSession },
                name
            )
            XCTAssertNotNil(appState.exportHTMLOwnershipStopReason(), name)
            XCTAssertThrowsError(
                try appState.saveDetachedCurrentDocument(to: fixture.root.appendingPathComponent("copy.md")),
                name
            )
            KeyWindowRouter.shared.resetForTesting()
        }
    }

    func testAWindowWithARootIsNotEmpty() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let sibling = fixture.appState.makeSiblingFacade(admitsFileOperations: true)
        XCTAssertTrue(sibling.isEmptyWorkspaceWindow)
        sibling.workspaceRootURL = fixture.root
        XCTAssertFalse(sibling.isEmptyWorkspaceWindow)
    }

    /// `SecondWindowRegistryFixture.showDetachedSessionInSharedWindow`, on another façade.
    private func showDetachedSession(in facade: AppState, fixture: SecondWindowRegistryFixture) throws {
        let missingURL = fixture.root.appendingPathComponent("missing.md")
        try Data("missing on disk".utf8).write(to: missingURL)
        let location = try fixture.authority.location(relativePath: "missing.md")
        let read = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(text: "unsaved missing", url: missingURL, fileKind: .markdown, isDirty: true)
        facade.registry.sessionCache[missingURL] = session
        facade.anchoredSessionFileBindings[ObjectIdentifier(session)] = AnchoredWorkspaceSessionFileBinding(
            location: location,
            identity: read.metadata.identity,
            sha256Digest: read.sha256Digest
        )
        facade.workspaceRootURL = fixture.root
        facade.workspaceSearchRootAuthority = fixture.authority
        facade.workspaceGeneration = 1
        facade.workspaceInstalledCaptureGeneration = 1
        facade.shownSession = session
        facade.detachedSessionURLs.insert(missingURL)
        facade.missingFilePrompt = AppState.MissingFilePrompt(fileURL: missingURL)
    }
}
