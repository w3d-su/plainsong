import Combine
import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

@MainActor
final class WindowSharedRootAppTests: SharedRootAppTestCase {
    func testSameCanonicalRootSharesOneWatcherScopeAndScanPerRefresh() async throws {
        let root = try makeRoot("root")
        try await open(primary, root: root)
        let watcher = try XCTUnwrap(primary.workspaceWatcher)
        let access = try XCTUnwrap(primary.workspaceAccess)
        let alias = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)

        try second.openWorkspace(url: alias, rememberAsLastOpened: false)
        try await waitUntil("attached tree") { self.second.workspaceTree != nil }
        XCTAssertTrue(primary.workspaceRootContext === second.workspaceRootContext)
        XCTAssertTrue(second.workspaceWatcher === watcher)
        XCTAssertTrue(second.workspaceAccess === access)
        XCTAssertEqual(scopeStarts, 1)
        XCTAssertEqual(scanner.count(root), 1)
        XCTAssertEqual(primary.registry.activeWorkspaceRoots.count, 1)

        primary.refreshWorkspaceAfterFileSystemChange()
        await primary.workspaceReloadTask?.value
        XCTAssertEqual(scanner.count(root), 2)
        XCTAssertEqual(primary.workspaceTree?.root, second.workspaceTree?.root)
        XCTAssertNil(primary.presentedError)
    }

    func testWatcherSurvivesTheCreatingFacadeLeavingAndBeingReleased() async throws {
        let root = try makeRoot("root")
        try await openPair(root: root, keepWatcher: true)
        second.openWorkspaceFile(root.appendingPathComponent("b.md"))
        let context = primary.workspaceRootContext
        let watcher = try XCTUnwrap(primary.workspaceWatcher)
        let access = primary.workspaceAccess
        weak var original = primary
        try primary.closeWorkspaceForReplacement()
        XCTAssertTrue(second.workspaceRootContext === context)
        XCTAssertFalse(watcher.isStopped)
        XCTAssertTrue(second.workspaceAccess === access)
        primary = nil
        XCTAssertNil(original)

        try Data("gamma".utf8).write(to: root.appendingPathComponent("new.md"))
        try await waitUntil("survivor receives actual watcher event") {
            self.node("new.md", in: self.second) != nil
        }
        XCTAssertFalse(watcher.isStopped)
        XCTAssertNil(second.presentedError)
        XCTAssertEqual(second.shownSession.fileURL?.lastPathComponent, "b.md")
    }

    func testInFlightInitialScanSurvivesItsInitiatorDetaching() async throws {
        let root = try makeRoot("root", files: [:])
        await scanner.gate.holdNext()
        try primary.openWorkspace(url: root, rememberAsLastOpened: false)
        try await waitUntil("initial scan reaches gate") { self.scanner.count(root) == 1 }
        try second.openWorkspace(url: root, rememberAsLastOpened: false)
        let context = primary.workspaceRootContext
        try primary.closeWorkspaceForReplacement()
        await scanner.gate.release()
        await second.workspaceReloadTask?.value

        XCTAssertTrue(second.workspaceRootContext === context)
        XCTAssertNotNil(second.workspaceSnapshot)
        XCTAssertEqual(second.workspaceInstalledCaptureGeneration, second.workspaceGeneration)
        XCTAssertEqual(scanner.count(root), 1)
        XCTAssertNil(second.presentedError)
    }

    func testOnlyLastReleaseRunsRootRetirementAndRetainsInstalledAuthority() async throws {
        let root = try makeRoot("root")
        try await openPair(root: root)
        second.openWorkspaceFile(root.appendingPathComponent("b.md"))
        let firstSession = primary.shownSession
        let firstBinding = primary.editorDocumentBinding(for: firstSession)
        let installation = EditorDocumentBindingInstallation(
            bindingID: firstBinding.id, installationID: EditorDocumentBindingInstallationID()
        )
        firstBinding.onLifecycle(.installed(installation))
        let context = primary.workspaceRootContext
        let generation = context.workspaceGeneration
        let access = try XCTUnwrap(primary.workspaceAccess)
        try primary.closeWorkspaceForReplacement()
        XCTAssertEqual(context.workspaceGeneration, generation)
        XCTAssertNotNil(context.workspaceSnapshot)
        XCTAssertTrue(context.workspaceAccess === access)
        XCTAssertTrue(primary.retiredEditorDocumentSessions.isEmpty)

        try second.closeWorkspaceForReplacement()
        XCTAssertNil(context.workspaceSnapshot)
        XCTAssertNil(context.workspaceAccess)
        XCTAssertEqual(context.workspaceGeneration, generation + 1)
        XCTAssertTrue(primary.registry.activeWorkspaceRoots.isEmpty)
        let preserved = try XCTUnwrap(
            primary.registry.retainedWorkspaceAuthorityOwners[ObjectIdentifier(firstSession)]?.first
        )
        XCTAssertTrue(preserved.authority === access)
        XCTAssertFalse(preserved.hasStopped)
        firstBinding.onLifecycle(.revoked(installation))
        XCTAssertFalse(preserved.hasStopped, "the first window still shows this document")
    }

    func testDetachingClearsOnlyItsOwnSearchAndKeepsThePeersQueryAndGeneration() async throws {
        let root = try makeRoot("root")
        try await openPair(root: root)
        primary.setWorkspaceSearchQuery(TextSearchQuery(pattern: "alpha"))
        second.setWorkspaceSearchQuery(TextSearchQuery(pattern: "beta"))
        try await waitUntil("both window searches finish") {
            self.primary.workspaceSearchState.phase == .completed && self.second.workspaceSearchState
                .phase == .completed
        }
        let queryGeneration = second.workspaceSearchQueryGeneration
        let rootGeneration = second.workspaceGeneration
        let results = second.workspaceSearchState

        try primary.closeWorkspaceForReplacement()

        XCTAssertNil(primary.workspaceSearchState.activeQuery)
        XCTAssertNil(primary.workspaceSearchTask)
        XCTAssertNil(primary.workspaceSearchTaskToken)
        XCTAssertNil(primary.workspaceSearchRefreshIntent)
        XCTAssertEqual(second.workspaceSearchState, results)
        XCTAssertEqual(second.workspaceSearchQueryGeneration, queryGeneration)
        XCTAssertEqual(second.workspaceGeneration, rootGeneration)
        XCTAssertEqual(scanner.count(root), 1)
    }

    func testBodyEditsDoNotFanOutPublishesOrScansToTheOtherWindow() async throws {
        let root = try makeRoot("root")
        try await openPair(root: root)
        second.openWorkspaceFile(root.appendingPathComponent("b.md"))
        let scanCount = scanner.count(root)
        let secondTree = second.workspaceTree
        let secondSession = second.shownSession
        var publishes = 0
        let probe = second.objectWillChange.sink { publishes += 1 }
        defer { probe.cancel() }

        for index in 0 ..< 200 {
            primary.replaceDocumentText("alpha edit \(index)")
        }

        XCTAssertEqual(publishes, 0)
        XCTAssertEqual(scanner.count(root), scanCount)
        XCTAssertEqual(second.workspaceTree, secondTree)
        XCTAssertTrue(second.shownSession === secondSession)
        XCTAssertEqual(secondSession.text, "beta text")
    }

    /// A participant that is not the last to leave keeps the root alive, but a document it
    /// shows from outside the root leaves with it, so it is retired and its edit reaches disk.
    func testDetachingParticipantRetiresItsOwnStandaloneDocument() async throws {
        let root = try makeRoot("root", files: [:])
        let aloneURL = try writeOutsideRoot("alone.md", "alone")
        let nextURL = try writeOutsideRoot("next.md", "next")
        try await open(primary, root: root)
        let alone = try await showStandaloneThenAttach(second, file: aloneURL, root: root)
        let binding = second.editorDocumentBinding(for: alone)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id, installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        second.replaceDocumentText("edited", in: alone)
        let context = primary.workspaceRootContext
        let generation = context.workspaceGeneration

        try second.open(url: nextURL, rememberAsLastOpened: false, preserveWorkspace: false)

        XCTAssertTrue(primary.workspaceRootContext === context)
        XCTAssertEqual(context.workspaceGeneration, generation, "the shared root stays alive")
        XCTAssertTrue(second.isRetiredEditorSession(alone))
        binding.onLifecycle(.revoked(installation))
        second.flushAutosaveIfNeeded()
        XCTAssertEqual(try XCTUnwrap(String(bytes: Data(contentsOf: aloneURL), encoding: .utf8)), "edited")
    }

    /// The detaching window's own document outside the root gets the last release's
    /// preflight: an unresolved write refuses the detach and leaves the window attached.
    func testDetachRefusesWhileItsOwnStandaloneDocumentIsQuarantined() async throws {
        let root = try makeRoot("root", files: [:])
        let aloneURL = try writeOutsideRoot("alone.md", "alone")
        try await open(primary, root: root)
        let alone = try await showStandaloneThenAttach(second, file: aloneURL, root: root)
        second.indeterminateWorkspaceMutationSessions.insert(ObjectIdentifier(alone))
        let context = primary.workspaceRootContext

        XCTAssertThrowsError(try second.closeWorkspaceForReplacement())

        XCTAssertTrue(second.workspaceRootContext === context)
        XCTAssertNotNil(second.workspaceRootURL)
        XCTAssertTrue(second.shownSession === alone)
        second.indeterminateWorkspaceMutationSessions.remove(ObjectIdentifier(alone))
    }

    private func writeOutsideRoot(_ name: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Opens `file` standalone in `facade`, then attaches it to the empty shared `root`, which
    /// selects nothing, so the standalone document stays shown outside the root.
    private func showStandaloneThenAttach(
        _ facade: AppState,
        file: URL,
        root: URL
    ) async throws -> DocumentSession {
        try facade.open(url: file, rememberAsLastOpened: false, preserveWorkspace: false)
        let session = facade.shownSession
        try facade.openWorkspace(url: root, rememberAsLastOpened: false)
        try await waitUntil("the participant attaches") { facade.workspaceTree != nil }
        XCTAssertTrue(primary.workspaceRootContext === facade.workspaceRootContext)
        XCTAssertTrue(facade.shownSession === session)
        return session
    }
}
