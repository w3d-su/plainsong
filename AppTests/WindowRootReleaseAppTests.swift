import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// Windows PR D1b (`docs/window-state-gates.md` W3 bullet 7 and W6 bullets 4–6):
/// closing one root releases only that root's eligible sessions.
@MainActor
final class WindowRootReleaseAppTests: XCTestCase {
    override func tearDown() async throws {
        KeyWindowRouter.shared.resetForTesting()
        WindowOpenAdmission.resetForTesting()
    }

    func testClosingR1KeepsPendingExternalStateForASecondWindowsSession() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let read = try MarkdownFileStore().loadResult(at: fixture.secondLocation)
        let version = ObservedRetainedFileVersion(location: fixture.secondLocation, result: read)
        fixture.appState.pendingExternalTexts[fixture.secondURL] = "changed on disk"
        fixture.appState.pendingExternalFileVersions[fixture.secondURL] = version
        fixture.appState.lastKnownDiskModificationDates[fixture.secondURL] = .distantPast

        try fixture.appState.closeWorkspaceForReplacement()

        XCTAssertEqual(fixture.appState.pendingExternalTexts[fixture.secondURL], "changed on disk")
        XCTAssertEqual(fixture.appState.pendingExternalFileVersions[fixture.secondURL], version)
        XCTAssertEqual(fixture.appState.lastKnownDiskModificationDates[fixture.secondURL], .distantPast)
    }

    func testClosingR1KeepsAnchoredBindingForASecondWindowsSession() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let binding = fixture.appState.anchoredSessionFileBindings[ObjectIdentifier(fixture.second)]

        try fixture.appState.closeWorkspaceForReplacement()

        XCTAssertEqual(
            fixture.appState.anchoredSessionFileBindings[ObjectIdentifier(fixture.second)]?.location,
            binding?.location
        )
    }

    func testClosingR1KeepsOwnershipProofForASecondWindowsSession() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let proof = UnanchoredManagedSessionFileProof(
            location: fixture.secondLocation,
            identity: fixture.secondIdentity,
            sha256Digest: "abc",
            installedWorkspaceLocation: fixture.secondLocation
        )
        fixture.appState.unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(fixture.second)] = .proven(proof)

        try fixture.appState.closeWorkspaceForReplacement()

        XCTAssertEqual(
            fixture.appState.unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(fixture.second)],
            .proven(proof)
        )
    }

    func testClosingR1KeepsDetachedURLForASecondWindowsSession() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        fixture.appState.detachedSessionURLs.insert(fixture.secondURL)

        try fixture.appState.closeWorkspaceForReplacement()

        XCTAssertTrue(fixture.appState.detachedSessionURLs.contains(fixture.secondURL))
    }

    func testClosingR1KeepsQuarantineForASecondWindowsSession() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let write = WorkspaceIndeterminateFileWrite(
            reason: .durabilityFailed,
            preparedMetadata: nil,
            recoveryArtifact: .none
        )
        let identity = ObjectIdentifier(fixture.second)
        fixture.appState.indeterminateSessionWrites[identity] = write
        fixture.appState.indeterminateSessionWriteContexts[identity] = IndeterminateSessionWriteContext(
            location: fixture.secondLocation,
            preparedSHA256Digest: "abcd"
        )

        try fixture.appState.closeWorkspaceForReplacement()

        XCTAssertNil(fixture.appState.workspaceRootURL)
        XCTAssertEqual(fixture.appState.indeterminateSessionWrites[identity], write)
        XCTAssertEqual(
            fixture.appState.indeterminateSessionWriteContexts[identity]?.location,
            fixture.secondLocation
        )
    }

    func testClosingR1KeepsEditorBindingRegistrationForASecondWindowsSession() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let binding = fixture.appState.editorDocumentBinding(for: fixture.second)

        try fixture.appState.closeWorkspaceForReplacement()

        XCTAssertEqual(
            fixture.appState.editorDocumentBindingIDs[ObjectIdentifier(fixture.second)],
            binding.id
        )
        XCTAssertTrue(fixture.appState.editorDocumentBindingSessions[binding.id] === fixture.second)
    }

    func testClosingR1KeepsBackgroundTasksForASecondWindowsSession() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let identity = ObjectIdentifier(fixture.second)
        let autosave = Task {}
        let statistics = Task {}
        fixture.appState.sessionAutosaveTasks[identity] = SessionBackgroundTask(token: UUID(), task: autosave)
        fixture.appState.sessionStatisticsTasks[identity] = SessionBackgroundTask(token: UUID(), task: statistics)
        defer {
            autosave.cancel()
            statistics.cancel()
        }

        try fixture.appState.closeWorkspaceForReplacement()

        XCTAssertFalse(autosave.isCancelled)
        XCTAssertFalse(statistics.isCancelled)
        XCTAssertFalse(fixture.appState.sessionAutosaveTasks[identity]?.task.isCancelled ?? true)
        XCTAssertFalse(fixture.appState.sessionStatisticsTasks[identity]?.task.isCancelled ?? true)
    }

    func testClosingR1KeepsWarmCacheEntryForASecondWindowsSession() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        fixture.appState.registry.setWarmSession(fixture.second, at: fixture.secondURL)

        try fixture.appState.closeWorkspaceForReplacement()

        XCTAssertTrue(fixture.appState.registry.warmSession(at: fixture.secondURL) === fixture.second)
    }

    func testClosingR1KeepsASessionAnotherWindowInstalls() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        fixture.appState.registry.setWarmSession(fixture.second, at: fixture.secondURL)
        let binding = fixture.appState.editorDocumentBinding(for: fixture.second)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        fixture.hideSecond()

        try fixture.appState.closeWorkspaceForReplacement()

        XCTAssertTrue(fixture.appState.editorBindingInstallations[installation] === fixture.second)
        XCTAssertTrue(fixture.appState.registry.warmSession(at: fixture.secondURL) === fixture.second)
    }

    func testLastR1ReleasePreservesOtherRootAndStandaloneSessionsAndLRURecency() throws {
        let roots = try TwoRootReleaseFixture.make(testCase: self)
        roots.primary.sessionPolicy = WorkspaceSessionLRUPolicy(limit: 8)
        _ = roots.primary.sessionPolicy.access(roots.standaloneURL, isDirty: false)
        _ = roots.primary.sessionPolicy.access(roots.backgroundURL, isDirty: false)
        _ = roots.primary.sessionPolicy.access(roots.shownBURL, isDirty: false)
        _ = roots.primary.sessionPolicy.access(roots.shownAURL, isDirty: false)
        let autosave = Task {}
        defer { autosave.cancel() }
        roots.primary.sessionAutosaveTasks[ObjectIdentifier(roots.background)] = SessionBackgroundTask(
            token: UUID(),
            task: autosave
        )
        roots.primary.pendingExternalTexts[roots.backgroundURL] = "r2 external"
        roots.primary.detachedSessionURLs.insert(roots.standaloneURL)

        try roots.primary.closeWorkspaceForReplacement()

        XCTAssertNil(roots.primary.registry.warmSession(at: roots.warmAURL))
        XCTAssertTrue(roots.primary.registry.warmSession(at: roots.backgroundURL) === roots.background)
        XCTAssertTrue(roots.primary.registry.warmSession(at: roots.shownBURL) === roots.shownB)
        XCTAssertTrue(roots.primary.registry.warmSession(at: roots.standaloneURL) === roots.standalone)
        XCTAssertEqual(
            roots.primary.sessionPolicy.warmURLsInLeastRecentOrder,
            [roots.standaloneURL, roots.backgroundURL, roots.shownBURL]
        )
        XCTAssertFalse(autosave.isCancelled)
        XCTAssertEqual(roots.primary.pendingExternalTexts[roots.backgroundURL], "r2 external")
        XCTAssertTrue(roots.primary.detachedSessionURLs.contains(roots.standaloneURL))
        XCTAssertNotNil(roots.second.workspaceSearchRootAuthority)
    }

    func testLastR1ReleaseKeepsAnotherWindowsEditorBindingRegistration() throws {
        let roots = try TwoRootReleaseFixture.make(testCase: self)
        let binding = roots.primary.editorDocumentBinding(for: roots.shownB)

        try roots.primary.closeWorkspaceForReplacement()

        XCTAssertEqual(
            roots.primary.editorDocumentBindingIDs[ObjectIdentifier(roots.shownB)],
            binding.id
        )
        XCTAssertTrue(roots.primary.editorDocumentBindingSessions[binding.id] === roots.shownB)
    }

    func testLastR1ReleaseKeepsAnotherWindowsBackgroundTasks() throws {
        let roots = try TwoRootReleaseFixture.make(testCase: self)
        let identity = ObjectIdentifier(roots.shownB)
        let autosave = Task {}
        let statistics = Task {}
        defer {
            autosave.cancel()
            statistics.cancel()
        }
        roots.primary.sessionAutosaveTasks[identity] = SessionBackgroundTask(token: UUID(), task: autosave)
        roots.primary.sessionStatisticsTasks[identity] = SessionBackgroundTask(token: UUID(), task: statistics)

        try roots.primary.closeWorkspaceForReplacement()

        XCTAssertFalse(autosave.isCancelled)
        XCTAssertFalse(statistics.isCancelled)
    }

    func testLastR1ReleaseKeepsAnotherWindowsWarmCacheEntry() throws {
        let roots = try TwoRootReleaseFixture.make(testCase: self)

        try roots.primary.closeWorkspaceForReplacement()

        XCTAssertTrue(roots.second.registry.warmSession(at: roots.shownBURL) === roots.shownB)
        XCTAssertEqual(roots.second.shownSession.fileURL?.lastPathComponent, "b.md")
    }

    func testLastR1ReleaseKeepsASessionShownFromAnotherRoot() throws {
        let roots = try TwoRootReleaseFixture.make(testCase: self)
        let binding = roots.primary.editorDocumentBinding(for: roots.shownB)
        let identity = ObjectIdentifier(roots.shownB)
        let autosave = Task {}
        defer { autosave.cancel() }
        roots.primary.sessionAutosaveTasks[identity] = SessionBackgroundTask(token: UUID(), task: autosave)

        try roots.primary.closeWorkspaceForReplacement()

        XCTAssertTrue(roots.primary.registry.warmSession(at: roots.shownBURL) === roots.shownB)
        XCTAssertEqual(roots.primary.editorDocumentBindingIDs[identity], binding.id)
        XCTAssertFalse(autosave.isCancelled)
        XCTAssertNotEqual(
            roots.second.workspaceSearchRootAuthority?.canonicalRootURL,
            roots.primary.workspaceRootURL
        )
    }

    func testOtherRootFencedQuarantinedAndConflictedStateDoesNotBlockR1Release() throws {
        let roots = try TwoRootReleaseFixture.make(testCase: self)
        let identity = ObjectIdentifier(roots.background)
        roots.background.replaceText("dirty r2")
        roots.primary.workspaceMutationWriteFences.insert(identity)
        roots.primary.indeterminateWorkspaceMutationSessions.insert(identity)
        let write = WorkspaceIndeterminateFileWrite(
            reason: .durabilityFailed,
            preparedMetadata: nil,
            recoveryArtifact: .none
        )
        roots.primary.indeterminateSessionWrites[identity] = write
        roots.primary.pendingExternalTexts[roots.backgroundURL] = "r2 conflict"
        roots.primary.pendingExternalFileVersions[roots.backgroundURL] = nil

        try roots.primary.closeWorkspaceForReplacement()

        XCTAssertNil(roots.primary.workspaceRootURL)
        XCTAssertTrue(roots.primary.workspaceMutationWriteFences.contains(identity))
        XCTAssertTrue(roots.primary.indeterminateWorkspaceMutationSessions.contains(identity))
        XCTAssertEqual(roots.primary.indeterminateSessionWrites[identity], write)
        XCTAssertEqual(roots.primary.pendingExternalTexts[roots.backgroundURL], "r2 conflict")
        XCTAssertTrue(roots.primary.registry.warmSession(at: roots.backgroundURL) === roots.background)
        XCTAssertEqual(roots.background.text, "dirty r2")
    }

    func testGlobalTransactionAndStoreLoadFencesStillBlockR1Release() throws {
        let transaction = try TwoRootReleaseFixture.make(testCase: self)
        transaction.primary.workspaceMutationNamespaceDepth = 1

        XCTAssertThrowsError(try transaction.primary.closeWorkspaceForReplacement())
        XCTAssertNotNil(transaction.primary.workspaceRootURL)
        XCTAssertTrue(transaction.primary.registry.warmSession(at: transaction.backgroundURL) === transaction
            .background)

        let loadFailure = try TwoRootReleaseFixture.make(testCase: self)
        loadFailure.primary.workspaceMutationOperationRecoveryLoadFailed = true

        XCTAssertThrowsError(try loadFailure.primary.closeWorkspaceForReplacement())
        XCTAssertNotNil(loadFailure.primary.workspaceRootURL)
        XCTAssertTrue(
            loadFailure.primary.registry.warmSession(at: loadFailure.backgroundURL) === loadFailure.background
        )
    }
}

@MainActor
private struct TwoRootReleaseFixture {
    let primary: AppState
    let second: AppState
    let shownAURL: URL
    let warmAURL: URL
    let shownBURL: URL
    let backgroundURL: URL
    let standaloneURL: URL
    let shownB: DocumentSession
    let background: DocumentSession
    let standalone: DocumentSession

    static func make(testCase: XCTestCase) throws -> TwoRootReleaseFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowRootRelease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let rootA = directory.appendingPathComponent("root-a", isDirectory: true)
        let rootB = directory.appendingPathComponent("root-b", isDirectory: true)
        let rootStandalone = directory.appendingPathComponent("standalone", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootStandalone, withIntermediateDirectories: true)
        let shownAURL = rootA.appendingPathComponent("a.md")
        let warmAURL = rootA.appendingPathComponent("a-warm.md")
        let shownBURL = rootB.appendingPathComponent("b.md")
        let backgroundURL = rootB.appendingPathComponent("b-warm.md")
        let standaloneURL = rootStandalone.appendingPathComponent("alone.md")
        for url in [shownAURL, warmAURL, shownBURL, backgroundURL, standaloneURL] {
            try Data("text\n".utf8).write(to: url)
        }

        let authorityA = try WorkspaceFileSystemRootAuthority(rootURL: rootA)
        let authorityB = try WorkspaceFileSystemRootAuthority(rootURL: rootB)
        let authorityStandalone = try WorkspaceFileSystemRootAuthority(rootURL: rootStandalone)
        let shownA = DocumentSession(text: "text\n", url: shownAURL, fileKind: .markdown)
        let warmA = DocumentSession(text: "text\n", url: warmAURL, fileKind: .markdown)
        let shownB = DocumentSession(text: "text\n", url: shownBURL, fileKind: .markdown)
        let background = DocumentSession(text: "text\n", url: backgroundURL, fileKind: .markdown)
        let standalone = DocumentSession(text: "text\n", url: standaloneURL, fileKind: .markdown)
        let primary = AppState(shownSession: shownA, shouldRestoreLastOpenedFile: false)
        primary.workspaceRootURL = authorityA.canonicalRootURL
        primary.workspaceSearchRootAuthority = authorityA
        primary.workspaceGeneration = 1
        primary.workspaceInstalledCaptureGeneration = 1
        let second = primary.makeSiblingFacade(admitsFileOperations: true)
        second.workspaceRootURL = authorityB.canonicalRootURL
        second.workspaceSearchRootAuthority = authorityB
        second.workspaceGeneration = 1
        second.workspaceInstalledCaptureGeneration = 1
        second.shownSession = shownB

        let pairs: [(DocumentSession, WorkspaceFileSystemRootAuthority, String)] = [
            (shownA, authorityA, "a.md"),
            (warmA, authorityA, "a-warm.md"),
            (shownB, authorityB, "b.md"),
            (background, authorityB, "b-warm.md"),
            (standalone, authorityStandalone, "alone.md"),
        ]
        for (session, authority, name) in pairs {
            let location = try authority.location(relativePath: name)
            let read = try MarkdownFileStore().loadResult(at: location)
            primary.anchoredSessionFileBindings[ObjectIdentifier(session)] = AnchoredWorkspaceSessionFileBinding(
                location: location,
                identity: read.metadata.identity,
                sha256Digest: read.sha256Digest
            )
            primary.registry.setWarmSession(session, at: location.fileURL)
        }

        return try TwoRootReleaseFixture(
            primary: primary,
            second: second,
            shownAURL: XCTUnwrap(primary.sessionStateURL(for: shownA)),
            warmAURL: XCTUnwrap(primary.sessionStateURL(for: warmA)),
            shownBURL: XCTUnwrap(primary.sessionStateURL(for: shownB)),
            backgroundURL: XCTUnwrap(primary.sessionStateURL(for: background)),
            standaloneURL: XCTUnwrap(primary.sessionStateURL(for: standalone)),
            shownB: shownB,
            background: background,
            standalone: standalone
        )
    }
}
