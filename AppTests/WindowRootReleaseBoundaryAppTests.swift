import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// D1b review follow-up (2026-11-06). Root-scoped release still saves or retires the closing
/// window's own document, does not hand a new root's grant to a session nothing ties to it,
/// leaves the home window's foreground autosave and another root's recovery alone, and
/// releases a retained root scope whichever of revoke and switch-away happens last.
@MainActor
final class WindowRootReleaseBoundaryAppTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowRootReleaseBoundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "WindowRootReleaseBoundaryAppTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        KeyWindowRouter.shared.resetForTesting()
        WindowOpenAdmission.resetForTesting()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    /// A standalone file still shown after an empty folder opened belongs to no root, but it
    /// is the closing window's own document, so replacing the workspace saves or retires it.
    func testReplacingEmptyWorkspaceSavesPreviouslyShownStandaloneFile() async throws {
        let originalURL = try write("original.md", "original")
        let nextURL = try write("next.md", "next")
        let emptyRoot = directory.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        let appState = AppState(shouldRestoreLastOpenedFile: false, userDefaults: defaults)
        try appState.open(url: originalURL, rememberAsLastOpened: false, preserveWorkspace: false)
        let original = appState.shownSession
        try appState.openWorkspace(url: emptyRoot, rememberAsLastOpened: false)
        try await waitUntil("the empty root's first scan installs") {
            appState.workspaceSearchRootAuthority != nil
        }
        XCTAssertTrue(appState.shownSession === original)

        let binding = appState.editorDocumentBinding(for: original)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id, installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        appState.replaceDocumentText("edited", in: original)
        XCTAssertTrue(original.isDirty)

        try appState.open(url: nextURL, rememberAsLastOpened: false, preserveWorkspace: false)
        binding.onLifecycle(.revoked(installation))
        appState.flushAutosaveIfNeeded()

        XCTAssertEqual(try text(at: originalURL), "edited")
    }

    /// During a new root's first scan the window holds that root's grant but no root
    /// authority. Replacing it then must not retain the new grant for a session another
    /// window shows: nothing proves that session belongs to the new root.
    func testReplacementDuringInitialScanDoesNotTransferUnrelatedGrant() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        fixture.secondWindow.shownSession = fixture.first
        let rootAccess = SecurityScopedAccess.startAccessing(fixture.root)
        fixture.appState.workspaceAccess = rootAccess
        let newRoot = directory.appendingPathComponent("new-root", isDirectory: true)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)

        try fixture.appState.openWorkspace(url: newRoot, rememberAsLastOpened: false)
        let newAccess = try XCTUnwrap(fixture.appState.workspaceAccess)
        XCTAssertNil(fixture.appState.workspaceSearchRootAuthority, "the first scan has not installed")
        XCTAssertTrue(fixture.appState.shownSession === fixture.first)

        try fixture.appState.closeWorkspaceForReplacement()

        let owners = fixture.appState.registry
            .retainedWorkspaceAuthorityOwners[ObjectIdentifier(fixture.first)] ?? []
        XCTAssertTrue(owners.contains { $0.authority === rootAccess }, "the old root still backs it")
        XCTAssertFalse(owners.contains { $0.authority === newAccess })
    }

    /// The shared foreground autosave serves the home façade's document. A sibling closing its
    /// own root must not cancel it.
    func testSiblingClosePreservesHomeAutosave() throws {
        let roots = try TwoRootReleaseFixture.make(testCase: self)
        XCTAssertTrue(KeyWindowRouter.shared.isHome(roots.primary))
        let home = roots.primary.shownSession
        roots.primary.replaceDocumentText("home edited\n", in: home)
        roots.primary.scheduleAutosave()
        let timer = try XCTUnwrap(roots.primary.registry.autosaveTask)

        try roots.second.closeWorkspaceForReplacement()

        XCTAssertNil(roots.second.workspaceRootURL)
        XCTAssertEqual(roots.primary.registry.autosaveTask, timer)
        XCTAssertFalse(timer.isCancelled)
        roots.primary.cancelAutosave(for: home)
    }

    /// The closing home window still cancels its own foreground autosave, as before.
    func testHomeCloseStillCancelsItsForegroundAutosave() throws {
        let roots = try TwoRootReleaseFixture.make(testCase: self)
        roots.primary.replaceDocumentText("home edited\n", in: roots.primary.shownSession)
        roots.primary.scheduleAutosave()
        let timer = try XCTUnwrap(roots.primary.registry.autosaveTask)

        try roots.primary.closeWorkspaceForReplacement()

        XCTAssertNil(roots.primary.registry.autosaveTask)
        XCTAssertTrue(timer.isCancelled)
    }

    /// An operation recovery fences the root it names. R2's pending creation recovery must not
    /// stop R1's close, and the close leaves it in place.
    func testOtherRootCreationRecoveryDoesNotBlockRootClose() throws {
        let roots = try TwoRootReleaseFixture.make(testCase: self)
        try installCreationRecovery(named: "new.md", in: roots.second)
        XCTAssertEqual(roots.primary.workspaceMutationRecoveries.count, 1)

        try roots.primary.closeWorkspaceForReplacement()

        XCTAssertNil(roots.primary.workspaceRootURL)
        XCTAssertEqual(roots.primary.workspaceMutationRecoveries.count, 1)
        XCTAssertNotNil(roots.second.workspaceRootURL)
        XCTAssertTrue(roots.primary.registry.warmSession(at: roots.backgroundURL) === roots.background)
    }

    /// The closing root's own creation recovery still refuses its close.
    func testOwnRootCreationRecoveryStillBlocksRootClose() throws {
        let roots = try TwoRootReleaseFixture.make(testCase: self)
        try installCreationRecovery(named: "new.md", in: roots.primary)

        XCTAssertThrowsError(try roots.primary.closeWorkspaceForReplacement()) { error in
            guard case WorkspaceMutationError.indeterminateSession = error else {
                return XCTFail("Expected indeterminateSession, got \(error)")
            }
        }
        XCTAssertNotNil(roots.primary.workspaceRootURL)
        XCTAssertEqual(roots.primary.workspaceMutationRecoveries.count, 1)
    }

    /// Revoking the last installation while another window still shows the session keeps its
    /// registration. When that window then switches away, the retained root scope must stop.
    func testRevokeBeforeSwitchReleasesGrant() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let window = fixture.appState.makeSiblingFacade(admitsFileOperations: true)
        window.setCurrentDocument(fixture.second, requestingEditorFocus: false)
        let binding = window.editorDocumentBinding(for: fixture.second)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id, installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        fixture.secondWindow.shownSession = DocumentSession()
        fixture.appState.workspaceAccess = SecurityScopedAccess.startAccessing(fixture.root)
        try fixture.appState.closeWorkspaceForReplacement()
        let identity = ObjectIdentifier(fixture.second)
        let owner = try XCTUnwrap(fixture.appState.registry.retainedWorkspaceAuthorityOwners[identity]?.first)
        XCTAssertFalse(fixture.appState.registry.isWarmSession(fixture.second))

        binding.onLifecycle(.revoked(installation))
        XCTAssertFalse(owner.hasStopped, "the sibling still shows the session")

        window.setCurrentDocument(DocumentSession(), requestingEditorFocus: false)

        XCTAssertTrue(owner.hasStopped)
        XCTAssertNil(fixture.appState.registry.retainedWorkspaceAuthorityOwners[identity])
    }

    // MARK: - Helpers

    private func installCreationRecovery(named name: String, in facade: AppState) throws {
        let authority = try XCTUnwrap(facade.workspaceSearchRootAuthority)
        try Data("created\n".utf8).write(to: authority.canonicalRootURL.appendingPathComponent(name))
        let destination = try authority.location(relativePath: name)
        facade.installWorkspaceCreationRecovery(
            .init(destination: destination, reason: .durabilityFailed, recoveryState: .unknown),
            kind: .file
        )
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func text(at url: URL) throws -> String {
        try XCTUnwrap(String(bytes: Data(contentsOf: url), encoding: .utf8))
    }

    private func waitUntil(
        _ description: String,
        timeoutNanoseconds: UInt64 = 5_000_000_000,
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
