import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

@MainActor
final class WindowRetainedAuthorityLifecycleAppTests: XCTestCase {
    override func tearDown() async throws {
        KeyWindowRouter.shared.resetForTesting()
        WindowOpenAdmission.resetForTesting()
    }

    func testEvictionKeepsScopeUntilPendingDiskInspectionActuallyCompletes() async throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let owner = try preserveSecond(fixture)
        fixture.hideSecond()
        fixture.appState.handleExternalChange(for: fixture.second)
        let identity = ObjectIdentifier(fixture.second)
        let inspection = try XCTUnwrap(fixture.appState.externalDiskInspectionTasks[identity])

        fixture.appState.handleSessionEvictions([
            WorkspaceSessionEviction(url: fixture.secondURL, requiresSave: false),
        ])

        XCTAssertNil(fixture.appState.registry.warmSession(at: fixture.secondURL))
        XCTAssertFalse(owner.hasStopped, "in-flight filesystem work still needs the grant")
        await inspection.task.value
        XCTAssertNil(fixture.appState.externalDiskInspectionTasks[identity])
        XCTAssertTrue(owner.hasStopped)
        XCTAssertNil(fixture.appState.registry.retainedWorkspaceAuthorityOwners[identity])
    }

    func testEvictionKeepsScopeUntilPendingExternalReloadActuallyCompletes() async throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let owner = try preserveSecond(fixture)
        fixture.appState.setCurrentDocument(fixture.second, requestingEditorFocus: false)
        fixture.appState.pendingExternalTexts[fixture.secondURL] = "external version"
        fixture.appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: fixture.secondURL)
        fixture.appState.reloadExternallyChangedFile()
        let identity = ObjectIdentifier(fixture.second)
        let reload = try XCTUnwrap(fixture.appState.externalReloadTasks[identity])
        fixture.appState.setCurrentDocument(fixture.third, requestingEditorFocus: false)
        fixture.hideSecond()

        fixture.appState.handleSessionEvictions([
            WorkspaceSessionEviction(url: fixture.secondURL, requiresSave: false),
        ])

        XCTAssertFalse(owner.hasStopped)
        await reload.task.value
        XCTAssertNil(fixture.appState.externalReloadTasks[identity])
        XCTAssertTrue(owner.hasStopped)
        XCTAssertNil(fixture.appState.registry.retainedWorkspaceAuthorityOwners[identity])
    }

    func testReclosingTheSameRootReleasesThePreviouslyPreservedWarmSession() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let owner = try preserveSecond(fixture)
        fixture.hideSecond()
        fixture.appState.workspaceRootURL = fixture.root
        fixture.appState.workspaceSearchRootAuthority = try WorkspaceFileSystemRootAuthority(rootURL: fixture.root)
        XCTAssertEqual(fixture.appState.workspaceSearchRootAuthority, fixture.authority)
        XCTAssertFalse(owner.hasStopped)

        try fixture.appState.closeWorkspaceForReplacement()

        XCTAssertNil(fixture.appState.registry.warmSession(at: fixture.secondURL))
        XCTAssertTrue(owner.hasStopped)
        XCTAssertNil(fixture.appState.registry.retainedWorkspaceAuthorityOwners[ObjectIdentifier(fixture.second)])
    }

    func testLastRevokeReleasesScopeWhenOnlyAnotherWindowsInstallationKeptTheSession() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let window = fixture.appState.makeSiblingFacade(admitsFileOperations: true)
        window.setCurrentDocument(fixture.second, requestingEditorFocus: false)
        let binding = window.editorDocumentBinding(for: fixture.second)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id, installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        window.setCurrentDocument(DocumentSession(), requestingEditorFocus: false)
        fixture.secondWindow.shownSession = DocumentSession()
        fixture.appState.workspaceAccess = SecurityScopedAccess.startAccessing(fixture.root)
        try fixture.appState.closeWorkspaceForReplacement()
        let identity = ObjectIdentifier(fixture.second)
        let owner = try XCTUnwrap(fixture.appState.registry.retainedWorkspaceAuthorityOwners[identity]?.first)
        XCTAssertFalse(owner.hasStopped)
        XCTAssertFalse(fixture.appState.registry.isWarmSession(fixture.second))

        binding.onLifecycle(.revoked(installation))

        XCTAssertTrue(owner.hasStopped)
        XCTAssertNil(fixture.appState.registry.retainedWorkspaceAuthorityOwners[identity])
        XCTAssertNil(fixture.appState.registry.editorInstallationWindows[installation])
        fixture.appState.releaseRetainedWorkspaceAuthorityIfUnreferenced(for: fixture.second)
        XCTAssertEqual(owner.dependentSessionCount, 0)
    }

    func testDiscardAlsoRemovesTheInstallationWindowRecord() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let binding = fixture.appState.editorDocumentBinding(for: fixture.first)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id, installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        try fixture.appState.closeWorkspaceForReplacement()
        XCTAssertNotNil(fixture.appState.registry.editorInstallationWindows[installation])

        fixture.appState.discardRetiredEditorDocumentSession(fixture.first, canonicalURL: fixture.firstURL)

        XCTAssertNil(fixture.appState.editorBindingInstallations[installation])
        XCTAssertNil(fixture.appState.registry.editorInstallationWindows[installation])
    }

    private func preserveSecond(_ fixture: SecondWindowRegistryFixture) throws -> RetiredWorkspaceAuthorityOwner {
        fixture.appState.workspaceAccess = SecurityScopedAccess.startAccessing(fixture.root)
        fixture.appState.registry.setWarmSession(fixture.second, at: fixture.secondURL)
        try fixture.appState.closeWorkspaceForReplacement()
        return try XCTUnwrap(
            fixture.appState.registry.retainedWorkspaceAuthorityOwners[ObjectIdentifier(fixture.second)]?.first
        )
    }
}
