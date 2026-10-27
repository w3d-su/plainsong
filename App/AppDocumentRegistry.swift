import Combine
import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

/// File-scoped and app-global state (`docs/window-state-gates.md` §3.2). The §3.4 invariants
/// and the session LRU must see every file's writer, fences, quarantine, external-change
/// state, and recovery, so per-file state is keyed here rather than stored in a window.
/// The registry also owns the injected services, preferences, notices, recents, restoration
/// flags, and the app-global Replace authority generation.
///
/// Windows PR B1: `AppState` owns the only instance and forwards every property under its
/// original name (`AppState+RegistryForwarding.swift`, `AppState+SessionRegistryForwarding.swift`).
@MainActor
final class AppDocumentRegistry: ObservableObject {
    /// Set by `AppState.init`. Receives the hooked property's own `#fileID`/`#line`, so the
    /// Replace authority trace still names the input that changed. Until then a call goes
    /// to `UnwiredContainerHook`.
    var onEditorReplaceAuthorityInputChange: @MainActor (StaticString, UInt) -> Void = { fileID, line in
        UnwiredContainerHook.report(
            "AppDocumentRegistry.onEditorReplaceAuthorityInputChange",
            fileID: fileID,
            line: line
        )
    }

    /// One monotonic generation for every window's Find host (§3.2 `editorFindHost` row).
    let replaceAuthority = EditorReplaceAuthorityState()

    var isSaving = false // Synchronous save guard; unpublished, since no view can observe `true`.
    @Published var recentItemURLs: [URL] = []
    @Published var workspaceMutationReconciliationPrompt:
        WorkspaceMutationReconciliationPrompt?
    @Published var fileWriteArtifactNotices: [FileWriteArtifactNotice] = []
    @Published var workspaceTrashCleanupNotices: [WorkspaceTrashCleanupNotice] = []

    let fileStore: MarkdownFileStore
    let coherentFileReader: any WorkspaceCoherentFileReading
    let externalReloadApplicationPreparer: any ExternalReloadApplicationPreparing
    let lastOpenedFileStore: any LastOpenedFilePersisting
    let recentItemStore: any RecentItemPersisting
    let directoryScanner: any WorkspaceDirectoryScanning
    let workspaceSearchStreamProvider: any WorkspaceSearchStreamProviding
    let workspaceSearchLimits: WorkspaceSearchLimits
    let workspaceSearchDebounceNanoseconds: UInt64
    let fileOperations: WorkspaceFileOperations
    let workspaceMutationOperationRecoveryStore:
        any WorkspaceMutationOperationRecoveryPersisting
    let workspaceMutationTextRecoveryStore: any WorkspaceMutationTextRecoveryPersisting
    let reportedTrashBookmarkAccess: any ReportedTrashBookmarkAccessing
    let userDefaults: UserDefaults
    let editorImageThumbnailAdapter: WorkspaceEditorImageThumbnailAdapter
    var autosaveTask: Task<Void, Never>?
    var statisticsTask: Task<Void, Never>?
    /// Deterministic test seam for typed anchored-save outcomes.
    var anchoredFileSaveOverride: (@MainActor (
        String,
        WorkspaceFileSystemLocation,
        WorkspaceNoFollowFileWriteExpectation
    ) throws -> WorkspaceFileWriteOutcome)?
    var editorDocumentBindingIDs: [ObjectIdentifier: EditorDocumentBindingID] = [:]
    var editorDocumentBindingSessions: [EditorDocumentBindingID: DocumentSession] = [:]
    var editorBindingInstallations: [
        EditorDocumentBindingInstallation: DocumentSession
    ] = [:] {
        didSet { noteEditorReplaceAuthorityInputDidChange() }
    }

    var editorWriterInstallations: [ObjectIdentifier: EditorDocumentBindingInstallation] = [:]
    var pendingEditorSourceInstallations: [
        EditorDocumentBindingInstallation: DocumentSession
    ] = [:] {
        didSet { noteEditorReplaceAuthorityInputDidChange() }
    }

    var deferredExternalChangeResolutions: [URL: DeferredExternalChangeResolution] = [:] {
        didSet { noteEditorReplaceAuthorityInputDidChange() }
    }

    var externalResolutionIntentCaptures: [URL: ExternalResolutionIntentCapture] = [:]
    var externalReloadTasks: [ObjectIdentifier: ExternalReloadTask] = [:] {
        didSet { noteEditorReplaceAuthorityInputDidChange() }
    }

    var externalDiskInspectionTasks: [ObjectIdentifier: ExternalDiskInspectionTask] = [:] {
        didSet { noteEditorReplaceAuthorityInputDidChange() }
    }

    var pendingExternalReloadApplications: [
        ObjectIdentifier: PendingExternalReloadApplication
    ] = [:] {
        didSet { noteEditorReplaceAuthorityInputDidChange() }
    }

    var nextExternalReloadGeneration: UInt64 = 0
    var externalDiskEventGenerations: [ObjectIdentifier: UInt64] = [:]
    var retiredEditorDocumentSessions: [URL: RetiredEditorDocumentSession] = [:]
    var editorDocumentSourceFullComparisonCounts: [
        EditorDocumentSourceFullComparisonKind: Int
    ] = [:]
    var editorDocumentSourceSynchronizers: [
        EditorDocumentBindingInstallation: EditorDocumentSourceSynchronizer
    ] = [:]
    var sessionAutosaveTasks: [ObjectIdentifier: SessionBackgroundTask] = [:]
    var sessionStatisticsTasks: [ObjectIdentifier: SessionBackgroundTask] = [:]
    let shouldRestoreLastOpenedFile: Bool
    var didAttemptRestore = false
    var sessionCache: [URL: DocumentSession] = [:]
    var sessionLifecycleGenerations: [ObjectIdentifier: UInt64] = [:]
    var sessionPolicy = WorkspaceSessionLRUPolicy(limit: 8)
    var lastKnownDiskHashes: [URL: String] = [:]
    var lastKnownDiskModificationDates: [URL: Date] = [:]
    var pendingExternalTexts: [URL: String] = [:] {
        didSet { noteEditorReplaceAuthorityInputDidChange() }
    }

    /// Coherent descriptor-bound observations that back pending external-change text. The
    /// legacy text map remains the session-scoped save/autosave fence, while this companion
    /// prevents Reload or Keep Mine from pairing one observed text version with a later,
    /// unrelated identity/SHA proof.
    var pendingExternalFileVersions: [URL: ObservedRetainedFileVersion] = [:] {
        didSet { noteEditorReplaceAuthorityInputDidChange() }
    }

    var detachedSessionURLs: Set<URL> = [] {
        didSet { noteEditorReplaceAuthorityInputDidChange() }
    }

    /// Exact authority, identity, and content installed for each anchored workspace session.
    /// Saves use this proof instead of recapturing the session's mutable URL.
    var anchoredSessionFileBindings: [ObjectIdentifier: AnchoredWorkspaceSessionFileBinding] = [:]
    /// Descriptor-derived physical identity retained when an unanchored session becomes managed.
    /// `.unavailable` is a durable fail-closed proof state, never permission to re-inspect a URL.
    var unanchoredManagedSessionOwnershipProofs:
        [ObjectIdentifier: UnanchoredManagedSessionOwnershipProof] = [:]
    /// Descriptor-bound image placement authority cached for the exact retained document
    /// binding. SwiftUI reads only this cache; opening and validating the namespace never
    /// happens while evaluating `DocumentEditor.body`.
    var editorImageAssetDocumentAuthorities:
        [ObjectIdentifier: RetainedEditorImageAssetDocumentAuthority] = [:]
    /// A typed indeterminate commit must be reconciled before this session can write again.
    var indeterminateSessionWrites: [ObjectIdentifier: WorkspaceIndeterminateFileWrite] = [:] {
        didSet { noteEditorReplaceAuthorityInputDidChange() }
    }

    /// Retains the exact authority location and prepared-byte digest for safe reconciliation.
    var indeterminateSessionWriteContexts: [ObjectIdentifier: IndeterminateSessionWriteContext] = [:]
    /// Sessions whose retained namespace is being mutated. Save/autosave must not enter while
    /// their authority is between the old and new lexical locations.
    var workspaceMutationWriteFences: Set<ObjectIdentifier> = [] {
        didSet { noteEditorReplaceAuthorityInputDidChange() }
    }

    /// A namespace mutation fences image placement across the workspace, including mutations
    /// whose selected item is not itself an open document (for example an asset directory).
    var workspaceMutationNamespaceDepth = 0
    /// An indeterminate rename/move/Trash result cannot authorize either spelling. Keep the
    /// affected sessions quarantined until operation-level recovery proves one exact outcome
    /// or the user explicitly promotes the editor source to detached recovery.
    var indeterminateWorkspaceMutationSessions: Set<ObjectIdentifier> = [] {
        didSet { noteEditorReplaceAuthorityInputDidChange() }
    }

    var workspaceMutationRecoveries: [UUID: WorkspaceMutationRecoveryContext] = [:]
    var workspaceMutationOperationRecoveryRecords:
        [UUID: WorkspaceMutationOperationRecoveryRecord] = [:]
    var workspaceMutationOperationRecoveryIDsWithUnpromotedText: Set<UUID> = []
    var workspaceMutationRecoveryIDBySession: [ObjectIdentifier: UUID] = [:]
    var workspaceMutationTextRecoveryContexts:
        [ObjectIdentifier: WorkspaceMutationTextRecoveryContext] = [:]
    var workspaceMutationTextRecoverySessions: [UUID: DocumentSession] = [:]
    var workspaceMutationTextRecoveryTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    var pendingWorkspaceMutationTextRecoveryRecords:
        [WorkspaceMutationTextRecoveryRecord] = []
    var pendingWorkspaceMutationOperationRecoveryRecords:
        [WorkspaceMutationOperationRecoveryRecord] = []
    var workspaceMutationRecoveryLoadErrors: [Error] = []
    var workspaceMutationOperationRecoveryLoadError: Error?
    var workspaceMutationTextRecoveryLoadError: Error?
    @Published var workspaceMutationOperationRecoveryLoadFailed = false
    @Published var workspaceMutationTextRecoveryLoadFailed = false
    let preferences: PlainsongPreferences
    var isWYSIWYGMechanismHealthy = true

    /// Loads recents and each recovery store exactly once, in `AppState.init`'s order.
    init(
        fileStore: MarkdownFileStore,
        coherentFileReader: any WorkspaceCoherentFileReading,
        externalReloadApplicationPreparer: any ExternalReloadApplicationPreparing,
        lastOpenedFileStore: any LastOpenedFilePersisting,
        recentItemStore: any RecentItemPersisting,
        directoryScanner: any WorkspaceDirectoryScanning,
        workspaceSearchStreamProvider: any WorkspaceSearchStreamProviding,
        workspaceSearchLimits: WorkspaceSearchLimits,
        workspaceSearchDebounceNanoseconds: UInt64,
        editorImageThumbnailAdapter: WorkspaceEditorImageThumbnailAdapter,
        fileOperations: WorkspaceFileOperations,
        workspaceMutationOperationRecoveryStore: any WorkspaceMutationOperationRecoveryPersisting,
        workspaceMutationTextRecoveryStore: any WorkspaceMutationTextRecoveryPersisting,
        reportedTrashBookmarkAccess: any ReportedTrashBookmarkAccessing,
        shouldRestoreLastOpenedFile: Bool,
        userDefaults: UserDefaults,
        preferences: PlainsongPreferences
    ) {
        self.fileStore = fileStore
        self.coherentFileReader = coherentFileReader
        self.externalReloadApplicationPreparer = externalReloadApplicationPreparer
        self.lastOpenedFileStore = lastOpenedFileStore
        self.recentItemStore = recentItemStore
        self.directoryScanner = directoryScanner
        self.workspaceSearchStreamProvider = workspaceSearchStreamProvider
        self.workspaceSearchLimits = workspaceSearchLimits
        self.workspaceSearchDebounceNanoseconds = workspaceSearchDebounceNanoseconds
        self.editorImageThumbnailAdapter = editorImageThumbnailAdapter
        self.fileOperations = fileOperations
        self.workspaceMutationOperationRecoveryStore = workspaceMutationOperationRecoveryStore
        self.workspaceMutationTextRecoveryStore = workspaceMutationTextRecoveryStore
        self.reportedTrashBookmarkAccess = reportedTrashBookmarkAccess
        self.userDefaults = userDefaults
        self.shouldRestoreLastOpenedFile = shouldRestoreLastOpenedFile
        self.preferences = preferences
        recentItemURLs = (try? recentItemStore.restore()) ?? []
        do {
            pendingWorkspaceMutationOperationRecoveryRecords =
                try workspaceMutationOperationRecoveryStore.load()
        } catch {
            workspaceMutationOperationRecoveryLoadFailed = true
            workspaceMutationOperationRecoveryLoadError = error
            workspaceMutationRecoveryLoadErrors.append(error)
        }
        do {
            pendingWorkspaceMutationTextRecoveryRecords =
                try workspaceMutationTextRecoveryStore.load()
        } catch {
            workspaceMutationTextRecoveryLoadFailed = true
            workspaceMutationTextRecoveryLoadError = error
            workspaceMutationRecoveryLoadErrors.append(error)
        }
    }

    deinit {
        for reload in externalReloadTasks.values {
            reload.task.cancel()
        }
        for inspection in externalDiskInspectionTasks.values {
            inspection.task.cancel()
        }
        for task in sessionAutosaveTasks.values {
            task.task.cancel()
        }
        for task in sessionStatisticsTasks.values {
            task.task.cancel()
        }
        for task in workspaceMutationTextRecoveryTasks.values {
            task.cancel()
        }
        var stoppedOwners: Set<ObjectIdentifier> = []
        for retirement in retiredEditorDocumentSessions.values {
            for owner in retirement.securityScopedAuthorityOwners
                where stoppedOwners.insert(ObjectIdentifier(owner)).inserted
            {
                owner.stop()
            }
        }
    }

    func noteEditorReplaceAuthorityInputDidChange(fileID: StaticString = #fileID, line: UInt = #line) {
        onEditorReplaceAuthorityInputChange(fileID, line)
    }
}
