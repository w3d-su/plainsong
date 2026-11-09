import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

@MainActor
final class WindowSharedRootAdmissionAppTests: SharedRootAppTestCase {
    func testAncestorRootRefusesBeforeReplacingCurrentRootAndOffersShow() async throws {
        let root = try makeRoot("parent/child")
        let other = try makeRoot("other")
        try await open(primary, root: root)
        try await open(second, root: other)
        let secondContext = second.workspaceRootContext
        let starts = scopeStarts

        do {
            try second.openWorkspace(url: root.deletingLastPathComponent(), rememberAsLastOpened: false)
            XCTFail("an ancestor must refuse")
        } catch {
            second.present(error, title: "Could Not Open Workspace")
        }

        XCTAssertTrue(second.workspaceRootContext === secondContext)
        XCTAssertEqual(second.workspaceRootURL, other)
        XCTAssertEqual(scopeStarts, starts)
        let show = try XCTUnwrap(second.presentedError?.showWindow)
        show()
        XCTAssertTrue(KeyWindowRouter.shared.focusedWindowState === primary.windowState)
    }

    func testFilesystemRootCountsAsAnOverlappingAncestor() async throws {
        let root = try makeRoot("root")
        try await open(primary, root: root)
        XCTAssertThrowsError(try second.validateWorkspaceRootInstallation(
            url: URL(fileURLWithPath: "/", isDirectory: true), sharing: nil
        ))
        XCTAssertNil(second.workspaceRootURL)
        XCTAssertEqual(scopeStarts, 1)
    }

    func testDescendantRootRefusesBeforeInstallationAndOffersShow() async throws {
        let root = try makeRoot("parent", files: ["a.md": "text", "child/b.md": "text"])
        try await open(primary, root: root)

        do {
            try second.openWorkspace(url: root.appendingPathComponent("child"), rememberAsLastOpened: false)
            XCTFail("a descendant must refuse")
        } catch {
            second.present(error, title: "Could Not Open Workspace")
        }

        XCTAssertNil(second.workspaceRootURL)
        XCTAssertNil(second.workspaceAccess)
        XCTAssertEqual(scopeStarts, 1)
        try XCTUnwrap(second.presentedError?.showWindow)()
        XCTAssertTrue(KeyWindowRouter.shared.focusedWindowState === primary.windowState)
    }

    func testRootContainingAnotherWindowsStandaloneDocumentRefusesBeforeInstallation() throws {
        let root = try makeRoot("root")
        try primary.activateFileSession(url: root.appendingPathComponent("a.md"))
        let original = primary.shownSession

        do {
            try second.openWorkspace(url: root, rememberAsLastOpened: false)
            XCTFail("a standalone installation inside the root must refuse")
        } catch {
            second.present(error, title: "Could Not Open Workspace")
        }

        XCTAssertNil(second.workspaceRootURL)
        XCTAssertNil(second.workspaceWatcher)
        XCTAssertEqual(scopeStarts, 0)
        XCTAssertTrue(primary.shownSession === original)
        try XCTUnwrap(second.presentedError?.showWindow)()
        XCTAssertTrue(KeyWindowRouter.shared.focusedWindowState === primary.windowState)
    }

    func testRootContainingAnotherWindowsDelayedStandaloneInstallationRefuses() throws {
        let root = try makeRoot("root")
        try primary.activateFileSession(url: root.appendingPathComponent("a.md"))
        let session = primary.shownSession
        let binding = primary.editorDocumentBinding(for: session)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id, installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        primary.setCurrentDocument(DocumentSession(), requestingEditorFocus: false)
        XCTAssertThrowsError(try second.openWorkspace(url: root, rememberAsLastOpened: false))
        XCTAssertNil(second.workspaceRootURL)
        XCTAssertEqual(scopeStarts, 0)
        binding.onLifecycle(.revoked(installation))
    }

    func testDelayedStandaloneInstallationStillRefusesAfterItsWindowOpensAnotherRoot() async throws {
        let root = try makeRoot("root")
        let other = try makeRoot("other")
        try primary.activateFileSession(url: root.appendingPathComponent("a.md"))
        let session = primary.shownSession
        let binding = primary.editorDocumentBinding(for: session)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id, installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        defer { binding.onLifecycle(.revoked(installation)) }
        try await open(primary, root: other)
        XCTAssertFalse(primary.shownSession === session)
        XCTAssertTrue(primary.editorBindingInstallations[installation] === session)

        XCTAssertThrowsError(try second.openWorkspace(url: root, rememberAsLastOpened: false))

        XCTAssertNil(second.workspaceRootURL)
        XCTAssertNil(second.workspaceAccess)
        XCTAssertEqual(scopeStarts, 1)
        XCTAssertEqual(primary.workspaceRootURL, other)
    }

    func testDetachedParticipantStillShowingTheRootDoesNotBlockAnotherWindow() async throws {
        let root = try makeRoot("root")
        try await openPair(root: root)
        let shown = second.shownSession
        try second.closeWorkspaceForReplacement()
        XCTAssertTrue(second.shownSession === shown)
        XCTAssertNil(second.workspaceRootURL)

        let third = primary.makeSiblingFacade(admitsFileOperations: true)
        defer { third.workspaceWatcher?.stop() }
        try third.openWorkspace(url: root, rememberAsLastOpened: false)

        XCTAssertTrue(third.workspaceRootContext === primary.workspaceRootContext)
        XCTAssertEqual(scopeStarts, 1)
        XCTAssertNil(third.presentedError)
    }

    func testReopeningTheCurrentRootRemembersWithoutRescanning() async throws {
        let lastOpened = MemoryLastOpenedFileStore()
        let recents = MemoryRecentItemStore()
        let root = try makeRoot("root")
        let suiteName = "SharedRoot-reopen-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let facade = AppState(
            lastOpenedFileStore: lastOpened,
            recentItemStore: recents,
            directoryScanner: scanner,
            workspaceSearchDebounceNanoseconds: 0,
            workspaceMutationOperationRecoveryStore: operationStore,
            shouldRestoreLastOpenedFile: false,
            userDefaults: defaults
        )
        facade.registry.workspaceScopeStarter = { [weak self] root in
            self?.scopeStarts += 1
            return SecurityScopedAccess.startAccessing(root)
        }
        defer { facade.workspaceWatcher?.stop() }
        try await open(facade, root: root)
        let scans = scanner.count(root)
        let generation = facade.workspaceGeneration

        try facade.openWorkspace(url: root, rememberAsLastOpened: true)

        XCTAssertEqual(scanner.count(root), scans)
        XCTAssertEqual(facade.workspaceGeneration, generation)
        XCTAssertEqual(try lastOpened.restore(), root)
        XCTAssertEqual(try recents.restore(), [root])
    }
}
