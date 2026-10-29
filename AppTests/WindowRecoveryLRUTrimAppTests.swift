import Foundation
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

@MainActor
final class WindowRecoveryLRUTrimAppTests: XCTestCase {
    func testShowTextRecoveryCopyTrimsThePreviousShownSession() throws {
        try verifyRecoveryActionTrimsPreviousShown(operation: .textRecovery, action: .showEditorCopy)
    }

    func testKeepTextRecoveryCopyTrimsThePreviousShownSession() throws {
        try verifyRecoveryActionTrimsPreviousShown(operation: .textRecovery, action: .keepEditorCopy)
    }

    func testShowMutationRecoveryCopyTrimsThePreviousShownSession() throws {
        try verifyRecoveryActionTrimsPreviousShown(operation: .trash, action: .showEditorCopy)
    }

    private func verifyRecoveryActionTrimsPreviousShown(
        operation: WorkspaceMutationRecoveryOperation,
        action: WorkspaceMutationRecoverySecondaryAction
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "WindowRecoveryLRU-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let appState = AppState(shouldRestoreLastOpenedFile: false, userDefaults: defaults)
        defer {
            appState.autosaveTask?.cancel()
            appState.statisticsTask?.cancel()
            KeyWindowRouter.shared.resetForTesting()
            WindowOpenAdmission.resetForTesting()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        appState.sessionPolicy = .init(limit: 1)
        let oldestURL = directory.appendingPathComponent("oldest.md")
        let shownURL = directory.appendingPathComponent("shown.md")
        let recoveryURL = directory.appendingPathComponent("recovered.md")
        for url in [oldestURL, shownURL, recoveryURL] {
            try Data(url.lastPathComponent.utf8).write(to: url)
        }
        try appState.activateFileSession(url: oldestURL)
        let oldest = appState.shownSession
        try appState.activateFileSession(url: shownURL)
        let shown = appState.shownSession
        let oldestKey = try XCTUnwrap(appState.sessionStateURL(for: oldest))
        let shownKey = try XCTUnwrap(appState.sessionStateURL(for: shown))
        let recovered = DocumentSession(text: "preserved text", url: recoveryURL, fileKind: .markdown, isDirty: true)
        let identity = ObjectIdentifier(recovered)
        let recoveryID = UUID()
        appState.unanchoredManagedSessionOwnershipProofs[identity] = .unavailable(fileURL: recoveryURL)
        if operation == .textRecovery {
            appState.workspaceMutationTextRecoverySessions[recoveryID] = recovered
            appState.workspaceMutationTextRecoveryContexts[identity] = WorkspaceMutationTextRecoveryContext(
                recoveryID: recoveryID, originalURL: recoveryURL, fileKind: .markdown,
                reason: .trash, persistedRevision: recovered.version
            )
        } else {
            let authority = try WorkspaceFileSystemRootAuthority(rootURL: directory)
            let location = try authority.location(relativePath: "recovered.md")
            let read = try MarkdownFileStore().loadResult(at: location)
            let record = AppState.WorkspaceTrashSessionRecord(
                session: recovered, oldLocation: location, oldURL: recoveryURL,
                identity: read.metadata.identity, sha256Digest: read.sha256Digest,
                initialVersion: recovered.version, deferredExternalResolution: nil,
                hadExternalDiskInspection: false
            )
            appState.workspaceMutationRecoveries[recoveryID] = try .trash(WorkspaceTrashRecoveryContext(
                id: recoveryID, source: location,
                expectation: WorkspaceNoFollowItemInspector.inspect(at: location),
                sourceParentExpectation: authority.directoryMutationExpectation,
                reason: .durabilityFailed, recoveryLocation: nil, reportedTrashURL: nil,
                reportedTrashBookmarkData: nil, reportedTrashAuthorityLocation: nil,
                cleanupState: .notCreated, actualStagedExpectation: nil, actualStagedEntryRecoveryLocation: nil,
                records: [record], remainingSessionIDs: [identity]
            ))
            appState.workspaceMutationRecoveryIDBySession[identity] = recoveryID
        }
        appState.workspaceMutationReconciliationPrompt = WorkspaceMutationReconciliationPrompt(
            recoveryID: recoveryID, operation: operation, sourceURL: recoveryURL, secondaryAction: action
        )
        XCTAssertTrue(appState.registry.warmSession(at: oldestKey) === oldest)
        XCTAssertTrue(appState.registry.warmSession(at: shownKey) === shown)

        appState.performWorkspaceMutationRecoverySecondaryAction()

        XCTAssertTrue(appState.shownSession === recovered)
        XCTAssertEqual(recovered.text, "preserved text")
        XCTAssertNil(appState.registry.warmSession(at: oldestKey))
        XCTAssertTrue(appState.registry.warmSession(at: shownKey) === shown)
        XCTAssertEqual(appState.sessionPolicy.warmURLsInLeastRecentOrder, [shownKey])
    }
}
