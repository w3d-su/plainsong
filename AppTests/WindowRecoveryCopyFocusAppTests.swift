import AppKit
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// WD1 for recovery copies and for paths that are not a user request
/// (`docs/window-state-gates.md` §4.1, W4 bullet 1). Recovery Show/Keep Editor Copy brings
/// forward the window that shows the copy. Recovery promotion, trash completion, and a
/// background reload leave the document in its window and move no focus.
@MainActor
final class WindowRecoveryCopyFocusAppTests: SharedRootAppTestCase {
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        try await super.setUp()
        KeyWindowRouter.shared.attach(makeWindow(), to: primary)
        KeyWindowRouter.shared.attach(makeWindow(), to: second)
    }

    override func tearDown() async throws {
        for window in windows {
            window.orderOut(nil)
        }
        windows = []
        try await super.tearDown()
    }

    func testRecoveryShowEditorCopyFocusesTheWindowShowingTheCopy() async throws {
        try await assertTextRecoveryAction(.showEditorCopy)
    }

    func testRecoveryKeepEditorCopyFocusesTheWindowShowingTheCopy() async throws {
        try await assertTextRecoveryAction(.keepEditorCopy)
    }

    private func assertTextRecoveryAction(_ action: WorkspaceMutationRecoverySecondaryAction) async throws {
        _ = try await showSharedA()
        let before = second.shownSession
        let recoveryID = registerTextRecovery(for: primary.shownSession)
        second.workspaceMutationReconciliationPrompt = try WorkspaceMutationReconciliationPrompt(
            recoveryID: recoveryID, operation: .textRecovery,
            sourceURL: XCTUnwrap(primary.shownSession.fileURL), secondaryAction: action
        )

        second.performWorkspaceMutationRecoverySecondaryAction()

        assertFocusedPrimary(leaving: before)
    }

    func testTrashRecoveryShowEditorCopyFocusesTheWindowShowingTheCopy() async throws {
        let root = try await showSharedA()
        let before = second.shownSession
        let recoveryID = try registerTrashRecovery(for: primary.shownSession, root: root)
        second.workspaceMutationReconciliationPrompt = try WorkspaceMutationReconciliationPrompt(
            recoveryID: recoveryID, operation: .trash,
            sourceURL: XCTUnwrap(primary.shownSession.fileURL), secondaryAction: .showEditorCopy
        )

        second.performWorkspaceMutationRecoverySecondaryAction()

        assertFocusedPrimary(leaving: before)
    }

    /// Promotion is not a user request: the copy stays in window 1 and nothing moves focus.
    func testRecoveryPromotionLeavesACopyShownInAnotherWindow() async throws {
        let root = try await showSharedA()
        let before = second.shownSession
        registerTextRecovery(for: primary.shownSession)

        second.promoteNextWorkspaceMutationRecoverySessionIfNeeded()

        assertStaysInPrimary(leaving: before)
        _ = clearTextRecovery(for: primary.shownSession)

        try registerTrashRecovery(for: primary.shownSession, root: root)
        second.promoteNextWorkspaceMutationRecoverySessionIfNeeded()

        assertStaysInPrimary(leaving: before)
    }

    /// Window 2 trashes a file whose edited copy window 1 shows: the detached copy stays there.
    func testTrashCompletionLeavesADetachedCopyShownInAnotherWindow() async throws {
        let root = try await showSharedA()
        let before = second.shownSession
        let session = primary.shownSession
        let record = try trashRecord(for: session, root: root, initialVersion: session.version + 1)

        second.finishWorkspaceTrash([record])

        assertStaysInPrimary(leaving: before)
    }

    /// A reload that would select the first file selects nothing when window 1 shows it.
    func testAReloadDoesNotSelectAFileShownInAnotherWindow() async throws {
        let root = try makeRoot("blog", files: ["a.md": "alpha text"])
        try await openPair(root: root)
        primary.openWorkspaceFile(root.appendingPathComponent("a.md"))
        try await waitUntil("window 1 shows a.md") { self.primary.shownSession.fileURL?.lastPathComponent == "a.md" }
        let before = second.shownSession
        XCTAssertNil(before.fileURL)

        try await second.reloadWorkspaceTree(root: root, selectFirstIfNeeded: true)

        assertStaysInPrimary(leaving: before)
        XCTAssertNil(second.workspaceTree?.selectedNodeID)
    }

    // MARK: - Fixture

    private func showSharedA() async throws -> URL {
        let root = try makeRoot("blog")
        try await openPair(root: root)
        primary.openWorkspaceFile(root.appendingPathComponent("a.md"))
        try await waitUntil("window 1 shows a.md") {
            self.primary.shownSession.fileURL?.lastPathComponent == "a.md"
        }
        XCTAssertNil(primary.presentedError)
        return root
    }

    private func assertFocusedPrimary(
        leaving before: DocumentSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            KeyWindowRouter.shared.focusedWindowState === primary.windowState,
            "window 1 was not brought forward",
            file: file,
            line: line
        )
        XCTAssertTrue(second.shownSession === before, "window 2 changed its document", file: file, line: line)
        XCTAssertNil(second.presentedError, "window 2 presented an error", file: file, line: line)
    }

    @discardableResult
    private func registerTextRecovery(for session: DocumentSession) -> UUID {
        let identity = ObjectIdentifier(session)
        let recoveryID = UUID()
        let url = session.fileURL ?? directory.appendingPathComponent("a.md")
        primary.unanchoredManagedSessionOwnershipProofs[identity] = .unavailable(fileURL: url)
        primary.workspaceMutationTextRecoverySessions[recoveryID] = session
        primary.workspaceMutationTextRecoveryContexts[identity] = WorkspaceMutationTextRecoveryContext(
            recoveryID: recoveryID, originalURL: url, fileKind: .markdown,
            reason: .trash, persistedRevision: session.version
        )
        return recoveryID
    }

    private func clearTextRecovery(for session: DocumentSession) -> Bool {
        let identity = ObjectIdentifier(session)
        primary.unanchoredManagedSessionOwnershipProofs[identity] = nil
        guard let context = primary.workspaceMutationTextRecoveryContexts.removeValue(forKey: identity) else {
            return false
        }
        primary.workspaceMutationTextRecoverySessions[context.recoveryID] = nil
        return true
    }

    private func trashRecord(
        for session: DocumentSession,
        root: URL,
        initialVersion: Int
    ) throws -> AppState.WorkspaceTrashSessionRecord {
        let url = try XCTUnwrap(session.fileURL)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: url.lastPathComponent)
        let read = try MarkdownFileStore().loadResult(at: location)
        return AppState.WorkspaceTrashSessionRecord(
            session: session, oldLocation: location, oldURL: url,
            identity: read.metadata.identity, sha256Digest: read.sha256Digest,
            initialVersion: initialVersion, deferredExternalResolution: nil,
            hadExternalDiskInspection: false
        )
    }

    @discardableResult
    private func registerTrashRecovery(for session: DocumentSession, root: URL) throws -> UUID {
        let identity = ObjectIdentifier(session)
        let recoveryID = UUID()
        let record = try trashRecord(for: session, root: root, initialVersion: session.version)
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        primary.workspaceMutationRecoveries[recoveryID] = try .trash(WorkspaceTrashRecoveryContext(
            id: recoveryID, source: record.oldLocation,
            expectation: WorkspaceNoFollowItemInspector.inspect(at: record.oldLocation),
            sourceParentExpectation: authority.directoryMutationExpectation,
            reason: .durabilityFailed, recoveryLocation: nil, reportedTrashURL: nil,
            reportedTrashBookmarkData: nil, reportedTrashAuthorityLocation: nil,
            cleanupState: .notCreated, actualStagedExpectation: nil, actualStagedEntryRecoveryLocation: nil,
            records: [record], remainingSessionIDs: [identity]
        ))
        primary.workspaceMutationRecoveryIDBySession[identity] = recoveryID
        return recoveryID
    }

    private func assertStaysInPrimary(
        leaving before: DocumentSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(second.shownSession === before, "window 2 changed its document", file: file, line: line)
        XCTAssertNil(second.presentedError, "window 2 presented an error", file: file, line: line)
        XCTAssertNil(KeyWindowRouter.shared.focusedWindowState, "focus moved", file: file, line: line)
        XCTAssertFalse(
            primary.registry.connectedWindows.filter { $0.shownSession === primary.shownSession }.count > 1,
            "two windows show one session",
            file: file,
            line: line
        )
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }
}
