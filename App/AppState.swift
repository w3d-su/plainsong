import AppKit
import Combine
import EditorKit
import MarkdownCore
import SwiftUI
import UniformTypeIdentifiers
import WorkspaceKit

protocol LastOpenedFilePersisting: AnyObject {
    func save(_ url: URL) throws
    func restore() throws -> URL?
}

extension LastOpenedFileStore: LastOpenedFilePersisting {}

protocol RecentItemPersisting: AnyObject {
    func save(_ url: URL) throws
    func restore() throws -> [URL]
}

extension RecentItemStore: RecentItemPersisting {}

protocol WorkspaceDirectoryScanning: Sendable {
    func snapshotCapture(root: URL) async throws -> WorkspaceDirectorySnapshotCapture
}

extension WorkspaceDirectoryScanner: WorkspaceDirectoryScanning {}

protocol ExternalReloadApplicationPreparing: Sendable {
    func prepare(
        snapshot: WorkspaceCoherentFileSnapshot,
        sourceSnapshot: EditorDocumentSourceSnapshot
    ) async -> ExternalReloadApplicationPayload?
}

struct ProductionExternalReloadApplicationPreparer: ExternalReloadApplicationPreparing {
    private let willPrepare: (@Sendable () -> Void)?
    private let didPrepare: (@Sendable () -> Void)?

    init(
        willPrepare: (@Sendable () -> Void)? = nil,
        didPrepare: (@Sendable () -> Void)? = nil
    ) {
        self.willPrepare = willPrepare
        self.didPrepare = didPrepare
    }

    func prepare(
        snapshot: WorkspaceCoherentFileSnapshot,
        sourceSnapshot: EditorDocumentSourceSnapshot
    ) async -> ExternalReloadApplicationPayload? {
        let preparationTask = Task<ExternalReloadApplicationPayload?, Never>.detached(
            priority: .utility
        ) {
            guard !Task.isCancelled else { return nil }
            willPrepare?()
            guard !Task.isCancelled else { return nil }
            guard let payload = ExternalReloadApplicationPayload.preparingIfNotCancelled(
                snapshot: snapshot,
                sourceSnapshot: sourceSnapshot
            ) else {
                return nil
            }
            guard !Task.isCancelled else { return nil }
            didPrepare?()
            return payload
        }
        return await withTaskCancellationHandler {
            await preparationTask.value
        } onCancel: {
            preparationTask.cancel()
        }
    }
}

struct FileWriteArtifactNotice: Identifiable, Equatable {
    let id: UUID
    let destinationURL: URL
    let destinationWasCommitted: Bool
    let artifactState: WorkspaceFileWriteArtifactState

    init(
        id: UUID = UUID(),
        destinationURL: URL,
        destinationWasCommitted: Bool,
        artifactState: WorkspaceFileWriteArtifactState
    ) {
        self.id = id
        self.destinationURL = destinationURL
        self.destinationWasCommitted = destinationWasCommitted
        self.artifactState = artifactState
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.destinationURL == rhs.destinationURL
            && lhs.destinationWasCommitted == rhs.destinationWasCommitted
            && lhs.artifactState == rhs.artifactState
    }
}

enum IndeterminateFileWriteReconciliationState: Equatable {
    case symbolicLink
    case notRegularFile
    case unreadable
}

struct IndeterminateFileWriteReconciliationPrompt: Equatable {
    let fileURL: URL
    let state: IndeterminateFileWriteReconciliationState
}

struct AppStateUserVisibleError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Top-level app state for the current editor window.
@MainActor
final class AppState: ObservableObject {
    typealias UserVisibleError = AppStateUserVisibleError

    struct ExternalChangePrompt: Identifiable, Equatable {
        let id = UUID()
        let fileURL: URL
    }

    struct MissingFilePrompt: Identifiable, Equatable {
        let id = UUID()
        let fileURL: URL
    }

    @Published var currentDocument: DocumentSession
    @Published var isSaving = false
    @Published private(set) var layoutMode: EditorLayoutMode
    @Published var workspaceRootURL: URL?
    @Published var workspaceTree: WorkspaceFileTree?
    var workspaceSnapshot: WorkspaceFileSnapshot?
    var workspaceSearchRootAuthority: WorkspaceFileSystemRootAuthority?
    /// Generation that installed the current snapshot/authority pair. Search requires this to
    /// equal `workspaceGeneration` so a reload that has advanced generation cannot label an
    /// old capture as the new generation while the replacement scan is still in flight.
    var workspaceInstalledCaptureGeneration: UInt64?
    var workspaceGeneration: UInt64 = 0
    @Published var workspaceSearchState = WorkspaceSearchState()
    @Published var editorNavigationCommand: EditorNavigationCommand?
    @Published var showAllFiles = false
    @Published var completionWorkspace: CompletionWorkspace = .empty
    @Published var recentItemURLs: [URL] = []
    @Published var presentedError: UserVisibleError?
    @Published var externalChangePrompt: ExternalChangePrompt?
    @Published var missingFilePrompt: MissingFilePrompt?
    @Published var indeterminateFileWriteReconciliationPrompt:
        IndeterminateFileWriteReconciliationPrompt?
    @Published var fileWriteArtifactNotices: [FileWriteArtifactNotice] = []
    @Published private(set) var wysiwygFallbackMessage: String?
    @Published private(set) var editorFocusRequestID = 0

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
    let userDefaults: UserDefaults
    let editorImageThumbnailAdapter: WorkspaceEditorImageThumbnailAdapter
    let editorImageThumbnailRefreshProxy: EditorImageThumbnailRefreshProxy
    var autosaveTask: Task<Void, Never>?
    var statisticsTask: Task<Void, Never>?
    var workspaceReloadTask: Task<Void, Never>?
    /// Deterministic test seam at the final root-proof -> reload-activation boundary.
    var workspaceReloadPostProofHook: (@MainActor () throws -> Void)?
    /// Deterministic test seam after the authority-bound activation file is loaded.
    var workspaceReloadPostLoadHook: (@MainActor () throws -> Void)?
    /// Deterministic test seam after activation-file preparation but before the final root proof.
    var workspaceReloadPostPrepareHook: (@MainActor () throws -> Void)?
    /// Deterministic test seam after search activation but before its identity arbitration.
    var workspaceSearchPostActivationHook: (@MainActor () throws -> Void)?
    /// Deterministic test seam for typed anchored-save outcomes.
    var anchoredFileSaveOverride: (@MainActor (
        String,
        WorkspaceFileSystemLocation,
        WorkspaceNoFollowFileWriteExpectation
    ) throws -> WorkspaceFileWriteOutcome)?
    var workspaceSearchTask: Task<Void, Never>?
    var workspaceSearchTaskToken: UUID?
    var workspaceSearchQueryGeneration: UInt64 = 0
    var editorNavigationGeneration: UInt64 = 0
    var editorDocumentBindingIDs: [ObjectIdentifier: EditorDocumentBindingID] = [:]
    var editorDocumentBindingSessions: [EditorDocumentBindingID: DocumentSession] = [:]
    var editorBindingInstallations: [
        EditorDocumentBindingInstallation: DocumentSession
    ] = [:]
    var editorWriterInstallations: [ObjectIdentifier: EditorDocumentBindingInstallation] = [:]
    var pendingEditorSourceInstallations: [
        EditorDocumentBindingInstallation: DocumentSession
    ] = [:]
    var deferredExternalChangeResolutions: [URL: DeferredExternalChangeResolution] = [:]
    var externalResolutionIntentCaptures: [URL: ExternalResolutionIntentCapture] = [:]
    var externalReloadTasks: [ObjectIdentifier: ExternalReloadTask] = [:]
    var externalDiskInspectionTasks: [ObjectIdentifier: ExternalDiskInspectionTask] = [:]
    var pendingExternalReloadApplications: [
        ObjectIdentifier: PendingExternalReloadApplication
    ] = [:]
    var nextExternalReloadGeneration: UInt64 = 0
    var externalDiskEventGenerations: [ObjectIdentifier: UInt64] = [:]
    var retiredEditorDocumentSessions: [URL: RetiredEditorDocumentSession] = [:]
    var editorDocumentSourceFullComparisonCounts: [
        EditorDocumentSourceFullComparisonKind: Int
    ] = [:]
    var editorDocumentSourceSynchronizers: [
        EditorDocumentBindingInstallation: EditorDocumentSourceSynchronizer
    ] = [:]
    var completionWorkspaceTask: Task<Void, Never>?
    var sessionAutosaveTasks: [ObjectIdentifier: SessionBackgroundTask] = [:]
    var sessionStatisticsTasks: [ObjectIdentifier: SessionBackgroundTask] = [:]
    var documentChangeCancellable: AnyCancellable?
    let shouldRestoreLastOpenedFile: Bool
    var didAttemptRestore = false
    var workspaceAccess: SecurityScopedResourceAccess?
    var workspaceWatcher: WorkspaceEventWatcher?
    var sessionCache: [URL: DocumentSession] = [:]
    var sessionLifecycleGenerations: [ObjectIdentifier: UInt64] = [:]
    var sessionPolicy = WorkspaceSessionLRUPolicy(limit: 8)
    var lastKnownDiskHashes: [URL: String] = [:]
    var lastKnownDiskModificationDates: [URL: Date] = [:]
    var pendingExternalTexts: [URL: String] = [:]
    /// Coherent descriptor-bound observations that back pending external-change text. The
    /// legacy text map remains the session-scoped save/autosave fence, while this companion
    /// prevents Reload or Keep Mine from pairing one observed text version with a later,
    /// unrelated identity/SHA proof.
    var pendingExternalFileVersions: [URL: ObservedRetainedFileVersion] = [:]
    var detachedSessionURLs: Set<URL> = []
    /// Exact authority, identity, and content installed for each anchored workspace session.
    /// Saves use this proof instead of recapturing the session's mutable URL.
    var anchoredSessionFileBindings: [ObjectIdentifier: AnchoredWorkspaceSessionFileBinding] = [:]
    /// Descriptor-derived physical identity retained when an unanchored session becomes managed.
    /// `.unavailable` is a durable fail-closed proof state, never permission to re-inspect a URL.
    var unanchoredManagedSessionOwnershipProofs:
        [ObjectIdentifier: UnanchoredManagedSessionOwnershipProof] = [:]
    /// A typed indeterminate commit must be reconciled before this session can write again.
    var indeterminateSessionWrites: [ObjectIdentifier: WorkspaceIndeterminateFileWrite] = [:]
    /// Retains the exact authority location and prepared-byte digest for safe reconciliation.
    var indeterminateSessionWriteContexts: [ObjectIdentifier: IndeterminateSessionWriteContext] = [:]
    let preferences: PlainsongPreferences
    private(set) var isWYSIWYGMechanismHealthy = true

    init(
        currentDocument: DocumentSession = DocumentSession(),
        fileStore: MarkdownFileStore = MarkdownFileStore(),
        coherentFileReader: any WorkspaceCoherentFileReading = WorkspaceCoherentFileReader(),
        externalReloadApplicationPreparer: any ExternalReloadApplicationPreparing =
            ProductionExternalReloadApplicationPreparer(),
        lastOpenedFileStore: any LastOpenedFilePersisting = LastOpenedFileStore(),
        recentItemStore: any RecentItemPersisting = RecentItemStore(),
        directoryScanner: any WorkspaceDirectoryScanning = WorkspaceDirectoryScanner(),
        workspaceSearchStreamProvider: any WorkspaceSearchStreamProviding = WorkspaceSearchService(),
        workspaceSearchLimits: WorkspaceSearchLimits = .init(),
        workspaceSearchDebounceNanoseconds: UInt64 = 200_000_000,
        workspaceImageThumbnailProvider: any WorkspaceImageThumbnailLoading = WorkspaceImageThumbnailProvider(),
        fileOperations: WorkspaceFileOperations = WorkspaceFileOperations(),
        shouldRestoreLastOpenedFile: Bool = !AppState.isRunningUnderXCTest,
        userDefaults: UserDefaults = .standard
    ) {
        self.currentDocument = currentDocument
        self.fileStore = fileStore
        self.coherentFileReader = coherentFileReader
        self.externalReloadApplicationPreparer = externalReloadApplicationPreparer
        self.lastOpenedFileStore = lastOpenedFileStore
        self.recentItemStore = recentItemStore
        self.directoryScanner = directoryScanner
        self.workspaceSearchStreamProvider = workspaceSearchStreamProvider
        self.workspaceSearchLimits = workspaceSearchLimits
        self.workspaceSearchDebounceNanoseconds = workspaceSearchDebounceNanoseconds
        editorImageThumbnailAdapter = WorkspaceEditorImageThumbnailAdapter(
            provider: workspaceImageThumbnailProvider
        )
        editorImageThumbnailRefreshProxy = EditorImageThumbnailRefreshProxy()
        self.fileOperations = fileOperations
        self.userDefaults = userDefaults
        self.shouldRestoreLastOpenedFile = shouldRestoreLastOpenedFile
        preferences = PlainsongPreferences(userDefaults: userDefaults)
        let restoredLayout = Self.restoreLayoutMode(
            from: userDefaults,
            isExperimentalWYSIWYGEnabled: preferences.experimentalWYSIWYGEnabled
        )
        layoutMode = restoredLayout.mode
        wysiwygFallbackMessage = restoredLayout.fallbackMessage
        recentItemURLs = (try? recentItemStore.restore()) ?? []
        preferences.onChange = { [weak self] in
            self?.handlePreferencesChanged()
        }
        observeCurrentDocument()
        retainUnanchoredManagedSessionOwnership(for: currentDocument)
    }

    deinit {
        workspaceReloadTask?.cancel()
        completionWorkspaceTask?.cancel()
        workspaceWatcher?.stop()
        workspaceSearchTask?.cancel()
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
        var stoppedOwners: Set<ObjectIdentifier> = []
        for retirement in retiredEditorDocumentSessions.values {
            for owner in retirement.securityScopedAuthorityOwners
                where stoppedOwners.insert(ObjectIdentifier(owner)).inserted
            {
                owner.stop()
            }
        }
    }
}

extension AppState {
    var isPreviewVisible: Bool {
        layoutMode.showsPreview
    }

    func requestEditorFocus() {
        editorFocusRequestID += 1
    }

    var isExperimentalWYSIWYGAvailable: Bool {
        preferences.experimentalWYSIWYGEnabled && isWYSIWYGMechanismHealthy
    }

    var shouldUseWYSIWYGPresentation: Bool {
        layoutMode.usesWYSIWYGPresentation && isExperimentalWYSIWYGAvailable
    }

    var layoutModeCommandTitle: String {
        switch layoutMode {
        case .sourcePreview:
            "Show Source Only"
        case .sourceOnly:
            isExperimentalWYSIWYGAvailable ? "Show WYSIWYG (Experimental)" : "Show Preview"
        case .wysiwyg:
            "Show Source + Preview"
        }
    }

    var layoutModeToolbarTitle: String {
        switch layoutMode {
        case .sourcePreview:
            "Source Only"
        case .sourceOnly:
            isExperimentalWYSIWYGAvailable ? "WYSIWYG" : "Preview"
        case .wysiwyg:
            "Source + Preview"
        }
    }

    var layoutModeToolbarSystemImage: String {
        switch layoutMode {
        case .sourcePreview:
            "doc.text"
        case .sourceOnly:
            isExperimentalWYSIWYGAvailable ? "textformat" : "sidebar.right"
        case .wysiwyg:
            "sidebar.right"
        }
    }

    var layoutModeToolbarHelp: String {
        isExperimentalWYSIWYGAvailable
            ? "Cycle layout: source + preview, source only, WYSIWYG (Experimental)"
            : "Toggle layout between source + preview and source only"
    }

    func restoreLastOpenedFileIfNeeded() {
        guard shouldRestoreLastOpenedFile, !didAttemptRestore, currentDocument.fileURL == nil else { return }
        didAttemptRestore = true

        do {
            guard let url = try lastOpenedFileStore.restore() else { return }
            try open(url: url, rememberAsLastOpened: false, preserveWorkspace: false)
        } catch {
            present(error, title: "Could Not Reopen Last File")
        }
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        // `.folder` must be included: setting `allowedContentTypes` otherwise disables
        // directory selection in the panel even when `canChooseDirectories` is true,
        // so folder workspaces could not be chosen despite the message inviting it.
        panel.allowedContentTypes = Self.supportedContentTypes + [.folder]
        panel.directoryURL = preferences.defaultFolderURL
        panel.message = "Choose a Markdown or MDX file, or a folder workspace."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        openExternalFile(url)
    }

    func openExternalFile(_ url: URL) {
        do {
            try open(url: url, rememberAsLastOpened: true, preserveWorkspace: false)
        } catch {
            present(error, title: "Could Not Open File")
        }
    }

    func save() {
        do {
            try saveCurrentDocument()
        } catch {
            present(error, title: "Could Not Save File")
        }
    }

    func dismissError() {
        presentedError = nil
    }

    func cycleLayoutMode() {
        setLayoutMode(layoutMode.next(isWYSIWYGAvailable: isExperimentalWYSIWYGAvailable))
    }

    func togglePreview() {
        cycleLayoutMode()
    }

    func setPreviewVisible(_ isVisible: Bool) {
        setLayoutMode(isVisible ? .sourcePreview : .sourceOnly)
    }

    func setLayoutMode(_ requestedMode: EditorLayoutMode) {
        let resolvedMode = resolveLayoutModeForCurrentAvailability(requestedMode)
        // The request was honored as-is (no WYSIWYG downgrade), so any earlier
        // fallback notice is stale — clear it once the user lands where they asked.
        if resolvedMode == requestedMode {
            dismissWYSIWYGFallbackMessage()
        }
        guard layoutMode != resolvedMode else {
            persistLayoutMode(resolvedMode)
            return
        }

        layoutMode = resolvedMode
        persistLayoutMode(resolvedMode)
    }

    func dismissWYSIWYGFallbackMessage() {
        guard wysiwygFallbackMessage != nil else { return }
        wysiwygFallbackMessage = nil
    }

    func handleWYSIWYGMechanismFailure(_ reason: String) {
        guard isWYSIWYGMechanismHealthy || layoutMode == .wysiwyg else { return }

        isWYSIWYGMechanismHealthy = false
        recoverFromUnavailableWYSIWYG(reason: reason)
    }

    func present(_ error: Error, title: String) {
        presentedError = UserVisibleError(title: title, message: error.localizedDescription)
    }

    func observeCurrentDocument() {
        documentChangeCancellable?.cancel()
        documentChangeCancellable = currentDocument.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func handlePreferencesChanged() {
        reconcileLayoutModeAvailability()
        objectWillChange.send()
        scheduleAutosave()
    }

    private func reconcileLayoutModeAvailability() {
        guard layoutMode == .wysiwyg, !isExperimentalWYSIWYGAvailable else { return }

        let reason = preferences.experimentalWYSIWYGEnabled
            ? "WYSIWYG editor mechanism is unhealthy"
            : "Experimental WYSIWYG is disabled"
        recoverFromUnavailableWYSIWYG(reason: reason)
    }

    private func resolveLayoutModeForCurrentAvailability(_ requestedMode: EditorLayoutMode) -> EditorLayoutMode {
        guard requestedMode == .wysiwyg, !isExperimentalWYSIWYGAvailable else {
            return requestedMode
        }

        let reason = preferences.experimentalWYSIWYGEnabled
            ? "WYSIWYG editor mechanism is unhealthy"
            : "Experimental WYSIWYG is disabled"
        recordWYSIWYGFallback(reason: reason)
        return .sourceOnly
    }

    private func recoverFromUnavailableWYSIWYG(reason: String) {
        recordWYSIWYGFallback(reason: reason)
        guard layoutMode != .sourceOnly else {
            persistLayoutMode(.sourceOnly)
            return
        }

        layoutMode = .sourceOnly
        persistLayoutMode(.sourceOnly)
    }

    private func recordWYSIWYGFallback(reason: String) {
        let message = "\(reason); falling back to source-only layout without changing source text."
        wysiwygFallbackMessage = message
        NSLog("[Plainsong] %@", message)
    }

    private func persistLayoutMode(_ mode: EditorLayoutMode) {
        userDefaults.set(mode.rawValue, forKey: Self.layoutModeDefaultsKey)
    }
}

extension AppState {
    static var supportedContentTypes: [UTType] {
        [
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "markdown"),
            UTType(filenameExtension: "mdx"),
        ].compactMap { $0 }
    }

    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static let layoutModeDefaultsKey = "Plainsong.layout.mode"
    static let legacyPreviewVisibleDefaultsKey = "Plainsong.preview.isVisible"

    private static func restoreLayoutMode(
        from userDefaults: UserDefaults,
        isExperimentalWYSIWYGEnabled: Bool
    ) -> (mode: EditorLayoutMode, fallbackMessage: String?) {
        if let rawMode = userDefaults.string(forKey: layoutModeDefaultsKey),
           let persistedMode = EditorLayoutMode(rawValue: rawMode)
        {
            guard persistedMode != .wysiwyg || isExperimentalWYSIWYGEnabled else {
                let message = "Experimental WYSIWYG is disabled; " +
                    "falling back to source-only layout without changing source text."
                userDefaults.set(EditorLayoutMode.sourceOnly.rawValue, forKey: layoutModeDefaultsKey)
                NSLog("[Plainsong] %@", message)
                return (.sourceOnly, message)
            }

            return (persistedMode, nil)
        }

        let migratedMode: EditorLayoutMode = if let legacyValue = userDefaults
            .object(forKey: legacyPreviewVisibleDefaultsKey) as? Bool
        {
            legacyValue ? .sourcePreview : .sourceOnly
        } else {
            .sourceOnly
        }
        userDefaults.set(migratedMode.rawValue, forKey: layoutModeDefaultsKey)
        userDefaults.removeObject(forKey: legacyPreviewVisibleDefaultsKey)
        return (migratedMode, nil)
    }
}

extension AppState {
    var hasOpenDocument: Bool {
        currentDocument.fileURL != nil
    }

    var canSave: Bool {
        guard let url = sessionStateURL(for: currentDocument) else {
            return false
        }
        return !isSaving &&
            !hasPendingEditorSource(for: currentDocument) &&
            externalReloadTasks[ObjectIdentifier(currentDocument)] == nil &&
            indeterminateSessionWrites[ObjectIdentifier(currentDocument)] == nil &&
            !detachedSessionURLs.contains(url) &&
            pendingExternalTexts[url] == nil &&
            pendingExternalFileVersions[url] == nil &&
            externalChangePrompt.map { !exactFileURLSpellingMatches($0.fileURL, url) } != false &&
            missingFilePrompt.map { !exactFileURLSpellingMatches($0.fileURL, url) } != false
    }

    var windowTitle: String {
        workspaceRootURL?.lastPathComponent ?? currentDocument.fileURL?.lastPathComponent ?? "Plainsong"
    }

    var previewAssetRootURL: URL? {
        workspaceRootURL
    }
}

struct RetiredEditorDocumentSession {
    let canonicalURL: URL
    let session: DocumentSession
    var bindingIDs: Set<EditorDocumentBindingID>
    var awaitingInstallations: Set<EditorDocumentBindingInstallation>
    var securityScopedAuthorityOwners: [RetiredWorkspaceAuthorityOwner]
}

enum DeferredExternalChangeResolution: Equatable {
    case reload
    case keepMine
}

struct ExternalResolutionIntentCapture: Equatable {
    let intent: DeferredExternalChangeResolution
    let sourceSnapshot: EditorDocumentSourceSnapshot
    var diskEventGeneration: UInt64
}

final class RetiredWorkspaceAuthorityOwner: @unchecked Sendable {
    let authority: SecurityScopedResourceAccess

    private let lock = NSLock()
    private var dependentSessions: Set<ObjectIdentifier> = []
    private var isStopped = false

    init(authority: SecurityScopedResourceAccess) {
        self.authority = authority
    }

    var hasStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }

    var dependentSessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dependentSessions.count
    }

    deinit {
        stop()
    }

    func retain(_ session: DocumentSession) {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped else { return }
        dependentSessions.insert(ObjectIdentifier(session))
    }

    func release(_ session: DocumentSession) {
        let shouldStop: Bool
        lock.lock()
        dependentSessions.remove(ObjectIdentifier(session))
        shouldStop = dependentSessions.isEmpty && !isStopped
        if shouldStop {
            isStopped = true
        }
        lock.unlock()

        if shouldStop {
            authority.stop()
        }
    }

    func stopIfUnused() {
        let shouldStop: Bool
        lock.lock()
        shouldStop = dependentSessions.isEmpty && !isStopped
        if shouldStop {
            isStopped = true
        }
        lock.unlock()

        if shouldStop {
            authority.stop()
        }
    }

    func stop() {
        let shouldStop: Bool
        lock.lock()
        shouldStop = !isStopped
        isStopped = true
        dependentSessions.removeAll()
        lock.unlock()

        if shouldStop {
            authority.stop()
        }
    }
}

struct SessionBackgroundTask {
    let token: UUID
    let task: Task<Void, Never>
}

struct ExternalReloadTask {
    let token: UUID
    let generation: UInt64
    let session: DocumentSession
    let canonicalURL: URL
    let location: WorkspaceFileSystemLocation
    let lifecycleGeneration: UInt64
    let sourceSnapshot: EditorDocumentSourceSnapshot
    let diskEventGeneration: UInt64
    let intent: DeferredExternalChangeResolution
    let task: Task<Void, Never>
}

struct ExternalDiskInspectionTask {
    let token: UUID
    let session: DocumentSession
    let canonicalURL: URL
    let location: WorkspaceFileSystemLocation
    let lifecycleGeneration: UInt64
    let diskEventGeneration: UInt64
    let sourceSnapshot: EditorDocumentSourceSnapshot
    let task: Task<Void, Never>
}

struct PendingExternalReloadApplication {
    let token: UUID
    let generation: UInt64
    let session: DocumentSession
    let canonicalURL: URL
    let payload: ExternalReloadApplicationPayload
    let acceptedSourceSnapshot: EditorDocumentSourceSnapshot
    let intent: DeferredExternalChangeResolution
    var synchronizedInstallations: Set<EditorDocumentBindingInstallation>
}

struct ExternalReloadApplicationPayload {
    let snapshot: WorkspaceCoherentFileSnapshot
    let contentHash: String
    let textTransition: DocumentSessionTextTransition

    private nonisolated init(
        snapshot: WorkspaceCoherentFileSnapshot,
        contentHash: String,
        textTransition: DocumentSessionTextTransition
    ) {
        self.snapshot = snapshot
        self.contentHash = contentHash
        self.textTransition = textTransition
    }

    nonisolated static func preparingIfNotCancelled(
        snapshot: WorkspaceCoherentFileSnapshot,
        sourceSnapshot: EditorDocumentSourceSnapshot
    ) -> Self? {
        guard !Task.isCancelled else { return nil }
        let textTransition = DocumentSessionTextTransition(
            sourceText: sourceSnapshot.source,
            sourceRevision: sourceSnapshot.revision,
            destinationText: snapshot.text
        )
        guard !Task.isCancelled else { return nil }
        return Self(
            snapshot: snapshot,
            contentHash: snapshot.sha256Digest,
            textTransition: textTransition
        )
    }
}

enum AppStateError: LocalizedError {
    case unsupportedFile(URL)
    case missingFile(URL)
    case unresolvedExternalChange(URL)
    case invalidSessionIdentity(URL)
    case duplicateSessionOwnership(URL)
    case pendingEditorSource(URL)
    case unsafeWriteTarget(URL)

    var errorDescription: String? {
        switch self {
        case let .unsupportedFile(url):
            "\(url.lastPathComponent) is not a supported Markdown file."
        case let .missingFile(url):
            "\(url.lastPathComponent) is no longer on disk. Save a copy or close it."
        case let .unresolvedExternalChange(url):
            "\(url.lastPathComponent) changed on disk. Choose Reload or Keep mine before saving."
        case let .invalidSessionIdentity(url):
            "The cached editor session for \(url.lastPathComponent) no longer matches that file."
        case let .duplicateSessionOwnership(url):
            "More than one editor session owns \(url.lastPathComponent)."
        case let .pendingEditorSource(url):
            "\(url.lastPathComponent) still has editor input waiting to synchronize."
        case let .unsafeWriteTarget(url):
            "\(url.lastPathComponent) no longer refers to the file owned by this editor session."
        }
    }
}
