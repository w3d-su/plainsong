@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// Windows PR B2 (`docs/window-state-gates.md` §3.4 I2, §11 W1 bullet 3): every session
/// inventory takes its sessions from the registry, so a session that only a second, connected
/// `WindowState` shows is seen by each operation with that operation's filters and extras.
/// Each test also hides the session from window 2 as a control: the operation stops seeing it.
@MainActor
final class WindowStateRegistryAppTests: XCTestCase {
    private var recorder: UnwiredContainerHookRecorder?

    override func setUp() async throws {
        try await super.setUp()
        recorder = UnwiredContainerHookRecorder()
    }

    override func tearDown() async throws {
        XCTAssertEqual(recorder?.reports, [], "Every window was connected before it received input")
        recorder?.stop()
        recorder = nil
        try await super.tearDown()
    }

    // MARK: - W1 bullet 3: inventories, ownership, and untitled sessions

    func testOwnershipInventoriesIncludeASessionOnlyASecondWindowShows() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let appState = fixture.appState
        func inventories() -> [(String, [DocumentSession])] {
            [
                ("mutation-managed", appState.workspaceMutationManagedSessions()),
                ("Save Copy candidates", appState.workspaceSaveCopyOwnershipCandidates()),
                ("termination", appState.workspaceMutationTerminationSessions()),
            ]
        }

        for (name, sessions) in inventories() {
            XCTAssertTrue(sessions.contains { $0 === fixture.second }, name)
            XCTAssertTrue(sessions.contains { $0 === fixture.first }, name)
        }
        XCTAssertTrue(appState.protectedSessionURLs().contains(fixture.secondURL), "LRU protection")
        XCTAssertTrue(appState.isManagedEditorSession(fixture.second))
        XCTAssertTrue(
            appState.isAddressableExternalResolutionSession(fixture.second, canonicalURL: fixture.secondURL)
        )

        fixture.hideSecond()

        for (name, sessions) in inventories() {
            XCTAssertFalse(sessions.contains { $0 === fixture.second }, "\(name) control")
        }
        XCTAssertFalse(appState.protectedSessionURLs().contains(fixture.secondURL))
        XCTAssertFalse(appState.isManagedEditorSession(fixture.second))
        XCTAssertFalse(
            appState.isAddressableExternalResolutionSession(fixture.second, canonicalURL: fixture.secondURL)
        )
    }

    /// An untitled document is owned by the window that shows it, as the shared window's is.
    func testAnUntitledDocumentInASecondWindowIsOwned() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let appState = fixture.appState
        let untitled = DocumentSession(text: "untitled draft")
        fixture.secondWindow.shownSession = untitled

        XCTAssertTrue(appState.isManagedEditorSession(untitled))
        XCTAssertTrue(appState.workspaceMutationManagedSessions().contains { $0 === untitled })
        XCTAssertTrue(appState.workspaceSaveCopyOwnershipCandidates().contains { $0 === untitled })
        XCTAssertTrue(appState.workspaceMutationTerminationSessions().contains { $0 === untitled })

        fixture.hideSecond()

        XCTAssertFalse(appState.isManagedEditorSession(untitled))
        XCTAssertFalse(appState.workspaceMutationManagedSessions().contains { $0 === untitled })
    }

    // MARK: - W1 bullet 3 and W3 bullet 8: autosave and the per-file prompt gate

    func testAutosaveFlushSavesADirtySessionOnlyASecondWindowShows() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        fixture.second.replaceText("second edited in window 2")
        XCTAssertTrue(fixture.second.isDirty)
        XCTAssertTrue(fixture.appState.canAutosave(session: fixture.second))

        fixture.appState.flushAutosaveIfNeeded()

        XCTAssertEqual(try fixture.text(at: fixture.secondURL), "second edited in window 2")
        XCTAssertFalse(fixture.second.isDirty)
        XCTAssertNil(fixture.appState.presentedError)
    }

    func testAutosaveOfAHiddenSessionIsRefused() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        fixture.second.replaceText("second edited")
        fixture.hideSecond()

        XCTAssertFalse(fixture.appState.canAutosave(session: fixture.second))
        fixture.appState.flushAutosaveIfNeeded()

        XCTAssertEqual(try fixture.text(at: fixture.secondURL), "second on disk")
    }

    /// A prompt in window 2 blocks that file's autosave and Save from every window; the shared
    /// window's prompt for another file does not block it (§3.4 I3).
    func testAWindowPromptBlocksOnlyItsFilesSaveInEveryWindow() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let appState = fixture.appState
        fixture.second.replaceText("second edited")

        fixture.secondWindow.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: fixture.secondURL)
        XCTAssertFalse(appState.canAutosave(session: fixture.second))
        appState.flushAutosaveIfNeeded()
        XCTAssertEqual(try fixture.text(at: fixture.secondURL), "second on disk")

        fixture.secondWindow.externalChangePrompt = nil
        appState.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: fixture.firstURL)
        XCTAssertTrue(appState.canAutosave(session: fixture.second), "Another file's prompt does not block it")

        appState.externalChangePrompt = nil
        XCTAssertTrue(appState.canSave)
        fixture.secondWindow.missingFilePrompt = AppState.MissingFilePrompt(fileURL: fixture.firstURL)
        XCTAssertFalse(appState.canSave, "Window 2's prompt for the shared window's file blocks its Save")
        fixture.secondWindow.missingFilePrompt = nil
        XCTAssertTrue(appState.canSave)
    }

    // MARK: - W3 bullet 4: retained-authority collision and physical duplicates

    func testRetainedAuthorityCollisionAndPhysicalDuplicateSeeASecondWindowsSession() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let appState = fixture.appState
        appState.indeterminateSessionWrites[ObjectIdentifier(fixture.second)] = WorkspaceIndeterminateFileWrite(
            reason: .durabilityFailed,
            preparedMetadata: nil,
            recoveryArtifact: .none
        )

        XCTAssertTrue(appState.hasConflictingPhysicalSessionOwnership(
            fixture.secondIdentity,
            excluding: DocumentSession()
        ))
        XCTAssertTrue(appState.hasStatefulRetainedAuthorityCollision(
            at: fixture.secondURL,
            candidateLocation: fixture.firstLocation
        ))

        fixture.hideSecond()

        XCTAssertFalse(appState.hasConflictingPhysicalSessionOwnership(
            fixture.secondIdentity,
            excluding: DocumentSession()
        ))
        XCTAssertFalse(appState.hasStatefulRetainedAuthorityCollision(
            at: fixture.secondURL,
            candidateLocation: fixture.firstLocation
        ))
    }

    // MARK: - W1 bullet 3: pruning, conflicts, and proof release

    func testPruningKeepsStateForASessionOnlyASecondWindowShows() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let appState = fixture.appState
        let identity = ObjectIdentifier(fixture.second)
        appState.pendingExternalTexts[fixture.secondURL] = "disk"
        appState.lastKnownDiskHashes[fixture.secondURL] = "hash"
        appState.detachedSessionURLs.insert(fixture.secondURL)

        appState.retainMetadataOnlyForRetiredEditorSessions()

        XCTAssertEqual(appState.pendingExternalTexts[fixture.secondURL], "disk")
        XCTAssertEqual(appState.lastKnownDiskHashes[fixture.secondURL], "hash")
        XCTAssertTrue(appState.detachedSessionURLs.contains(fixture.secondURL))
        XCTAssertNotNil(appState.anchoredSessionFileBindings[identity])

        fixture.hideSecond()
        appState.retainMetadataOnlyForRetiredEditorSessions()

        XCTAssertNil(appState.pendingExternalTexts[fixture.secondURL])
        XCTAssertNil(appState.lastKnownDiskHashes[fixture.secondURL])
        XCTAssertFalse(appState.detachedSessionURLs.contains(fixture.secondURL))
        XCTAssertNil(appState.anchoredSessionFileBindings[identity])
    }

    func testExternalConflictAndProofReleaseSeeASecondWindowsSession() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let appState = fixture.appState
        let identity = ObjectIdentifier(fixture.second)
        fixture.second.replaceText("second edited")
        appState.pendingExternalTexts[fixture.secondURL] = "changed on disk"
        appState.unanchoredManagedSessionOwnershipProofs[identity] = .unavailable(fileURL: fixture.secondURL)

        XCTAssertEqual(appState.firstUnretirableExternalConflict(excluding: []), fixture.secondURL)
        appState.releaseUnreferencedSessionOwnership(for: fixture.second)
        XCTAssertNotNil(appState.unanchoredManagedSessionOwnershipProofs[identity])

        fixture.hideSecond()

        XCTAssertNil(appState.firstUnretirableExternalConflict(excluding: []))
        appState.releaseUnreferencedSessionOwnership(for: fixture.second)
        XCTAssertNil(appState.unanchoredManagedSessionOwnershipProofs[identity])
    }

    // MARK: - W1 bullet 3: search

    func testSearchOverlaysIncludeASecondWindowsDirtySession() async throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        fixture.second.replaceText("second edited in window 2")

        let overlays = try await fixture.appState.workspaceSearchDirtyOverlays(rootAuthority: fixture.authority)
        XCTAssertEqual(overlays.overlays.map(\.relativePath), ["second.md"])

        fixture.hideSecond()

        let hidden = try await fixture.appState.workspaceSearchDirtyOverlays(rootAuthority: fixture.authority)
        XCTAssertEqual(hidden.overlays.map(\.relativePath), [])
    }

    // MARK: - W3 bullets 1–3: Save Copy, export, and mutation destinations

    /// Save Copy from the shared window onto window 2's file is refused, and so is a hard link
    /// or a case alias of it. Once window 2 stops showing the file, the hard link is writable.
    func testSaveCopyOntoASecondWindowsFileIsRefused() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let detached = try fixture.showDetachedSessionInSharedWindow()
        let hardLink = fixture.root.appendingPathComponent("second-link.md")
        try FileManager.default.linkItem(at: fixture.secondURL, to: hardLink)
        var destinations = [fixture.secondURL, hardLink]
        let caseAlias = fixture.root.appendingPathComponent("SECOND.md")
        if try !WorkspaceNoFollowItemInspector.parentIsCaseSensitive(of: fixture.secondLocation) {
            destinations.append(caseAlias)
        }

        for destination in destinations {
            XCTAssertThrowsError(try fixture.appState.saveDetachedCurrentDocument(to: destination), destination.path)
        }
        XCTAssertEqual(try fixture.text(at: fixture.secondURL), "second on disk")
        XCTAssertTrue(fixture.appState.shownSession === detached)

        fixture.hideSecond()

        XCTAssertNoThrow(try fixture.appState.saveDetachedCurrentDocument(to: hardLink))
        XCTAssertEqual(try fixture.text(at: hardLink), "unsaved missing")
        XCTAssertEqual(try fixture.text(at: fixture.secondURL), "second on disk")
    }

    /// Export refuses window 2's file through both of its inventories: the Save Copy owner walk
    /// (a hard link, by identity) and the mutation inventory (the file's own path).
    func testExportOntoASecondWindowsFileIsRefused() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let appState = fixture.appState
        let exportURL = fixture.root.appendingPathComponent("export.html")
        try FileManager.default.linkItem(at: fixture.secondURL, to: exportURL)
        let hardLink = try ExportArtifactWriter.inspectLeaf(at: exportURL).get()
        let ownPath = try ExportArtifactWriter.inspectLeaf(at: fixture.secondURL).get()

        XCTAssertEqual(
            appState.exportArtifactDestinationOwnership(for: hardLink, exportSource: fixture.first),
            .refused
        )
        XCTAssertThrowsError(try appState.validateExportArtifactSaveCopyInventory(
            hardLink,
            exportSource: fixture.first
        ))
        XCTAssertThrowsError(try appState.validateExportArtifactMutationInventory(ownPath))

        fixture.hideSecond()

        XCTAssertEqual(
            appState.exportArtifactDestinationOwnership(for: hardLink, exportSource: fixture.first),
            .permitted
        )
        XCTAssertNoThrow(try appState.validateExportArtifactSaveCopyInventory(hardLink, exportSource: fixture.first))
        XCTAssertNoThrow(try appState.validateExportArtifactMutationInventory(ownPath))
    }

    func testMutationDestinationOwnedByASecondWindowsSessionIsRefused() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)

        XCTAssertThrowsError(
            try fixture.appState.validateWorkspaceMutationDestinationOwnership(fixture.secondLocation)
        )

        fixture.hideSecond()

        XCTAssertNoThrow(
            try fixture.appState.validateWorkspaceMutationDestinationOwnership(fixture.secondLocation)
        )
    }

    /// The Save Copy owner walk fails closed on a candidate with no binding or proof, and every
    /// window's document is a candidate. So an untitled document with no ownership record in
    /// another window refuses every Save Copy until PR D2 decides that window's filter.
    func testAnUntitledRecordlessDocumentInASecondWindowFailsSaveCopyClosed() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        _ = try fixture.showDetachedSessionInSharedWindow()
        fixture.secondWindow.shownSession = DocumentSession(text: "untitled draft")

        XCTAssertThrowsError(
            try fixture.appState.saveDetachedCurrentDocument(to: fixture.root.appendingPathComponent("free.md"))
        )

        fixture.hideSecond()

        XCTAssertNoThrow(
            try fixture.appState.saveDetachedCurrentDocument(to: fixture.root.appendingPathComponent("free.md"))
        )
    }

    // MARK: - W1 bullet 3: closure and termination

    /// Closing the workspace keeps the proof and URL-keyed state of a file window 2 shows, as
    /// it does for the shared window's document; a session only the cache held is pruned.
    func testClosingTheWorkspaceKeepsStateForASecondWindowsSession() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        let appState = fixture.appState
        appState.lastKnownDiskHashes[fixture.secondURL] = "hash"
        appState.pendingExternalTexts[fixture.secondURL] = "changed on disk"
        appState.detachedSessionURLs.insert(fixture.secondURL)

        try appState.closeWorkspaceForReplacement()

        XCTAssertNotNil(appState.anchoredSessionFileBindings[ObjectIdentifier(fixture.second)])
        XCTAssertEqual(appState.lastKnownDiskHashes[fixture.secondURL], "hash")
        XCTAssertEqual(appState.pendingExternalTexts[fixture.secondURL], "changed on disk")
        XCTAssertTrue(appState.detachedSessionURLs.contains(fixture.secondURL))

        // A quarantined write in window 2 refuses the close instead of being pruned.
        let quarantined = try SecondWindowRegistryFixture.make(testCase: self)
        let write = WorkspaceIndeterminateFileWrite(
            reason: .durabilityFailed,
            preparedMetadata: nil,
            recoveryArtifact: .none
        )
        quarantined.appState.indeterminateSessionWrites[ObjectIdentifier(quarantined.second)] = write
        XCTAssertThrowsError(try quarantined.appState.closeWorkspaceForReplacement())
        XCTAssertEqual(quarantined.appState.indeterminateSessionWrites[ObjectIdentifier(quarantined.second)], write)

        let control = try SecondWindowRegistryFixture.make(testCase: self)
        control.hideSecond()
        control.appState.registry.sessionCache[control.secondURL] = control.second
        control.appState.lastKnownDiskHashes[control.secondURL] = "hash"

        try control.appState.closeWorkspaceForReplacement()

        XCTAssertNil(control.appState.anchoredSessionFileBindings[ObjectIdentifier(control.second)])
        XCTAssertNil(control.appState.lastKnownDiskHashes[control.secondURL])
    }

    /// Termination refuses while window 2's session has changes that cannot be saved safely.
    /// (W3 bullet 5 also requires focusing that window, which is PR C.)
    func testTerminationRefusesForASecondWindowsUnsavableSession() throws {
        let fixture = try SecondWindowRegistryFixture.make(testCase: self)
        fixture.second.replaceText("second edited")
        let installation = EditorDocumentBindingInstallation(
            bindingID: EditorDocumentBindingID(),
            installationID: EditorDocumentBindingInstallationID()
        )
        fixture.appState.pendingEditorSourceInstallations[installation] = fixture.second

        XCTAssertFalse(fixture.appState.prepareForTermination())
        XCTAssertNil(fixture.appState.presentedError)
        XCTAssertNotNil(fixture.secondWindow.presentedError)
        XCTAssertTrue(KeyWindowRouter.shared.focusedWindowState === fixture.secondWindow)

        fixture.appState.pendingEditorSourceInstallations[installation] = nil
        fixture.hideSecond()
        fixture.appState.dismissError()

        XCTAssertTrue(fixture.appState.prepareForTermination())
    }
}
