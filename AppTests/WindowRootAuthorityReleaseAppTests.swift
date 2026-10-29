import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

@MainActor
final class WindowRootAuthorityReleaseAppTests: XCTestCase {
    override func tearDown() async throws {
        KeyWindowRouter.shared.resetForTesting()
        WindowOpenAdmission.resetForTesting()
    }

    func testLastReleaseKeepsScopeForRootSessionShownInAnotherWindowUntilEviction() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let access = SecurityScopedAccess.startAccessing(fixture.root)
        fixture.appState.workspaceAccess = access
        fixture.appState.registry.setWarmSession(fixture.second, at: fixture.secondURL)

        try fixture.appState.closeWorkspaceForReplacement()

        let owner = try XCTUnwrap(
            fixture.appState.registry.retainedWorkspaceAuthorityOwners[ObjectIdentifier(fixture.second)]?.first
        )
        XCTAssertTrue(owner.authority === access)
        XCTAssertFalse(owner.hasStopped)
        XCTAssertEqual(owner.dependentSessionCount, 1)
        XCTAssertTrue(fixture.appState.registry.warmSession(at: fixture.secondURL) === fixture.second)

        fixture.hideSecond()
        fixture.appState.handleSessionEvictions([
            WorkspaceSessionEviction(url: fixture.secondURL, requiresSave: false),
        ])
        XCTAssertNil(fixture.appState.registry.warmSession(at: fixture.secondURL))
        XCTAssertTrue(owner.hasStopped)
        XCTAssertNil(fixture.appState.registry.retainedWorkspaceAuthorityOwners[ObjectIdentifier(fixture.second)])
    }

    func testSingleWindowDelayedInstallationRetiresWithScopeUntilRevoked() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        fixture.appState.registry.unregister(fixture.secondWindow)
        let access = SecurityScopedAccess.startAccessing(fixture.root)
        fixture.appState.workspaceAccess = access
        let binding = fixture.appState.editorDocumentBinding(for: fixture.first)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id, installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        fixture.appState.setCurrentDocument(fixture.second, requestingEditorFocus: false)

        try fixture.appState.closeWorkspaceForReplacement()

        let retired = try XCTUnwrap(fixture.appState.retiredEditorDocumentSessions[fixture.firstURL])
        let owner = try XCTUnwrap(retired.securityScopedAuthorityOwners.first)
        XCTAssertTrue(owner.authority === access)
        XCTAssertFalse(owner.hasStopped)
        XCTAssertNil(fixture.appState.registry.warmSession(at: fixture.firstURL))
        binding.onLifecycle(.revoked(installation))
        XCTAssertNil(fixture.appState.retiredEditorDocumentSessions[fixture.firstURL])
        XCTAssertTrue(owner.hasStopped)
    }

    func testStandaloneReplacementRetiresOwnInstallationAndPreservesOtherOwners() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        fixture.appState.workspaceRootURL = nil
        fixture.appState.workspaceSearchRootAuthority = nil
        let thirdURL = try XCTUnwrap(fixture.appState.sessionStateURL(for: fixture.third))
        fixture.appState.registry.setWarmSession(fixture.third, at: thirdURL)
        fixture.appState.indeterminateWorkspaceMutationSessions.insert(ObjectIdentifier(fixture.second))
        fixture.appState.pendingExternalTexts[thirdURL] = "unrelated warm conflict"
        let binding = fixture.appState.editorDocumentBinding(for: fixture.first)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id, installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        defer { binding.onLifecycle(.revoked(installation)) }

        try fixture.appState.closeWorkspaceForReplacement()

        let retired = try XCTUnwrap(fixture.appState.retiredEditorDocumentSessions[fixture.firstURL])
        XCTAssertTrue(retired.awaitingInstallations.contains(installation))
        XCTAssertTrue(fixture.secondWindow.shownSession === fixture.second)
        XCTAssertTrue(fixture.appState.indeterminateWorkspaceMutationSessions
            .contains(ObjectIdentifier(fixture.second)))
        XCTAssertTrue(fixture.appState.registry.warmSession(at: thirdURL) === fixture.third)
        XCTAssertEqual(fixture.appState.pendingExternalTexts[thirdURL], "unrelated warm conflict")
    }

    func testLastReleaseRefusesOwnRootQuarantineAndKeepsItsLiveScope() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let access = SecurityScopedAccess.startAccessing(fixture.root)
        fixture.appState.workspaceAccess = access
        let identity = ObjectIdentifier(fixture.second)
        fixture.appState.indeterminateWorkspaceMutationSessions.insert(identity)

        XCTAssertThrowsError(try fixture.appState.closeWorkspaceForReplacement())

        XCTAssertTrue(fixture.appState.workspaceAccess === access)
        XCTAssertNotNil(fixture.appState.workspaceRootURL)
        XCTAssertTrue(fixture.appState.indeterminateWorkspaceMutationSessions.contains(identity))
    }
}
