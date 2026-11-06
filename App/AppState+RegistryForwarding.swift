import Combine
import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

/// App-global registry forwarding façade (`docs/window-state-gates.md` §3.2, Windows PR B1):
/// services, preferences, recents, notices, restoration, autosave tasks, and recovery state.
/// Each property keeps the name, type, and access level it had as an `AppState` stored
/// property; `isWYSIWYGMechanismHealthy` (`private(set)`) is forwarded in `AppState.swift`.
/// Settable properties forward with `_modify` (see `AppState+WindowStateForwarding.swift`).
@MainActor
extension AppState {
    var isSaving: Bool {
        get { registry.isSaving }
        _modify { yield &registry.isSaving }
    }

    var recentItemURLs: [URL] {
        get { registry.recentItemURLs }
        _modify { yield &registry.recentItemURLs }
    }

    var workspaceMutationReconciliationPrompt: WorkspaceMutationReconciliationPrompt? {
        get { registry.workspaceMutationReconciliationPrompt }
        _modify { yield &registry.workspaceMutationReconciliationPrompt }
    }

    var fileWriteArtifactNotices: [FileWriteArtifactNotice] {
        get { registry.fileWriteArtifactNotices }
        _modify { yield &registry.fileWriteArtifactNotices }
    }

    var workspaceTrashCleanupNotices: [WorkspaceTrashCleanupNotice] {
        get { registry.workspaceTrashCleanupNotices }
        _modify { yield &registry.workspaceTrashCleanupNotices }
    }

    var fileStore: MarkdownFileStore {
        registry.fileStore
    }

    var coherentFileReader: any WorkspaceCoherentFileReading {
        registry.coherentFileReader
    }

    var externalReloadApplicationPreparer: any ExternalReloadApplicationPreparing {
        registry.externalReloadApplicationPreparer
    }

    var lastOpenedFileStore: any LastOpenedFilePersisting {
        registry.lastOpenedFileStore
    }

    var recentItemStore: any RecentItemPersisting {
        registry.recentItemStore
    }

    var directoryScanner: any WorkspaceDirectoryScanning {
        registry.directoryScanner
    }

    var workspaceSearchStreamProvider: any WorkspaceSearchStreamProviding {
        registry.workspaceSearchStreamProvider
    }

    var workspaceSearchLimits: WorkspaceSearchLimits {
        registry.workspaceSearchLimits
    }

    var workspaceSearchDebounceNanoseconds: UInt64 {
        registry.workspaceSearchDebounceNanoseconds
    }

    var fileOperations: WorkspaceFileOperations {
        registry.fileOperations
    }

    var workspaceMutationOperationRecoveryStore: any WorkspaceMutationOperationRecoveryPersisting {
        registry.workspaceMutationOperationRecoveryStore
    }

    var workspaceMutationTextRecoveryStore: any WorkspaceMutationTextRecoveryPersisting {
        registry.workspaceMutationTextRecoveryStore
    }

    var reportedTrashBookmarkAccess: any ReportedTrashBookmarkAccessing {
        registry.reportedTrashBookmarkAccess
    }

    var userDefaults: UserDefaults {
        registry.userDefaults
    }

    var editorImageThumbnailAdapter: WorkspaceEditorImageThumbnailAdapter {
        registry.editorImageThumbnailAdapter
    }

    var autosaveTask: Task<Void, Never>? {
        get { registry.autosaveTask }
        _modify { yield &registry.autosaveTask }
    }

    var statisticsTask: Task<Void, Never>? {
        get { registry.statisticsTask }
        _modify { yield &registry.statisticsTask }
    }

    var anchoredFileSaveOverride: (@MainActor (
        String,
        WorkspaceFileSystemLocation,
        WorkspaceNoFollowFileWriteExpectation
    ) throws -> WorkspaceFileWriteOutcome)? {
        get { registry.anchoredFileSaveOverride }
        _modify { yield &registry.anchoredFileSaveOverride }
    }

    var sessionAutosaveTasks: [ObjectIdentifier: SessionBackgroundTask] {
        get { registry.sessionAutosaveTasks }
        _modify { yield &registry.sessionAutosaveTasks }
    }

    var sessionStatisticsTasks: [ObjectIdentifier: SessionBackgroundTask] {
        get { registry.sessionStatisticsTasks }
        _modify { yield &registry.sessionStatisticsTasks }
    }

    var shouldRestoreLastOpenedFile: Bool {
        registry.shouldRestoreLastOpenedFile
    }

    var didAttemptRestore: Bool {
        get { registry.didAttemptRestore }
        _modify { yield &registry.didAttemptRestore }
    }

    var workspaceMutationRecoveries: [UUID: WorkspaceMutationRecoveryContext] {
        get { registry.workspaceMutationRecoveries }
        _modify { yield &registry.workspaceMutationRecoveries }
    }

    var workspaceMutationOperationRecoveryRecords: [UUID: WorkspaceMutationOperationRecoveryRecord] {
        get { registry.workspaceMutationOperationRecoveryRecords }
        _modify { yield &registry.workspaceMutationOperationRecoveryRecords }
    }

    var workspaceMutationOperationRecoveryIDsWithUnpromotedText: Set<UUID> {
        get { registry.workspaceMutationOperationRecoveryIDsWithUnpromotedText }
        _modify { yield &registry.workspaceMutationOperationRecoveryIDsWithUnpromotedText }
    }

    var workspaceMutationRecoveryIDBySession: [ObjectIdentifier: UUID] {
        get { registry.workspaceMutationRecoveryIDBySession }
        _modify { yield &registry.workspaceMutationRecoveryIDBySession }
    }

    var workspaceMutationTextRecoveryContexts: [ObjectIdentifier: WorkspaceMutationTextRecoveryContext] {
        get { registry.workspaceMutationTextRecoveryContexts }
        _modify { yield &registry.workspaceMutationTextRecoveryContexts }
    }

    var workspaceMutationTextRecoverySessions: [UUID: DocumentSession] {
        get { registry.workspaceMutationTextRecoverySessions }
        _modify { yield &registry.workspaceMutationTextRecoverySessions }
    }

    var workspaceMutationTextRecoveryTasks: [ObjectIdentifier: Task<Void, Never>] {
        get { registry.workspaceMutationTextRecoveryTasks }
        _modify { yield &registry.workspaceMutationTextRecoveryTasks }
    }

    var pendingWorkspaceMutationTextRecoveryRecords: [WorkspaceMutationTextRecoveryRecord] {
        get { registry.pendingWorkspaceMutationTextRecoveryRecords }
        _modify { yield &registry.pendingWorkspaceMutationTextRecoveryRecords }
    }

    var pendingWorkspaceMutationOperationRecoveryRecords: [WorkspaceMutationOperationRecoveryRecord] {
        get { registry.pendingWorkspaceMutationOperationRecoveryRecords }
        _modify { yield &registry.pendingWorkspaceMutationOperationRecoveryRecords }
    }

    var workspaceMutationRecoveryLoadErrors: [Error] {
        get { registry.workspaceMutationRecoveryLoadErrors }
        _modify { yield &registry.workspaceMutationRecoveryLoadErrors }
    }

    var workspaceMutationOperationRecoveryLoadError: Error? {
        get { registry.workspaceMutationOperationRecoveryLoadError }
        _modify { yield &registry.workspaceMutationOperationRecoveryLoadError }
    }

    var workspaceMutationTextRecoveryLoadError: Error? {
        get { registry.workspaceMutationTextRecoveryLoadError }
        _modify { yield &registry.workspaceMutationTextRecoveryLoadError }
    }

    var workspaceMutationOperationRecoveryLoadFailed: Bool {
        get { registry.workspaceMutationOperationRecoveryLoadFailed }
        _modify { yield &registry.workspaceMutationOperationRecoveryLoadFailed }
    }

    var workspaceMutationTextRecoveryLoadFailed: Bool {
        get { registry.workspaceMutationTextRecoveryLoadFailed }
        _modify { yield &registry.workspaceMutationTextRecoveryLoadFailed }
    }

    var preferences: PlainsongPreferences {
        registry.preferences
    }
}
