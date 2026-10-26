import AppKit
import Combine
import EditorKit
import MarkdownCore
import SwiftUI
import UniformTypeIdentifiers
import WorkspaceKit

/// Top-level app state. Windows PR B1 (`docs/window-state-gates.md` §3.2, §10) keeps its
/// storage in three scoped containers and this type as a forwarding façade over them:
/// `WindowState` (the window), `WorkspaceRootContext` (its workspace root), and
/// `AppDocumentRegistry` (per-file and app-global). Every window still shares one instance.
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

    /// Window-scoped storage, forwarded by `AppState+WindowStateForwarding.swift`.
    let windowState: WindowState
    /// Root-scoped storage, forwarded by `AppState+WorkspaceRootForwarding.swift`.
    let workspaceRootContext: WorkspaceRootContext
    /// Per-file and app-global storage, forwarded by `AppState+RegistryForwarding.swift` and
    /// `AppState+SessionRegistryForwarding.swift`.
    let registry: AppDocumentRegistry
    /// Re-sends each observable container's `objectWillChange`, so a moved `@Published`
    /// property still publishes `AppState.objectWillChange` once, before the change.
    private var containerChangeCancellables: [AnyCancellable] = []

    /// Like the next three, this `private(set)` property forwards here so its setter stays file-private.
    private(set) var layoutMode: EditorLayoutMode {
        get { windowState.layoutMode }
        set { windowState.layoutMode = newValue }
    }

    private(set) var wysiwygFallbackMessage: String? {
        get { windowState.wysiwygFallbackMessage }
        set { windowState.wysiwygFallbackMessage = newValue }
    }

    private(set) var editorFocusRequestID: Int {
        get { windowState.editorFocusRequestID }
        set { windowState.editorFocusRequestID = newValue }
    }

    private(set) var isWYSIWYGMechanismHealthy: Bool {
        get { registry.isWYSIWYGMechanismHealthy }
        set { registry.isWYSIWYGMechanismHealthy = newValue }
    }

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
        workspaceMutationOperationRecoveryStore:
        (any WorkspaceMutationOperationRecoveryPersisting)? = nil,
        workspaceMutationTextRecoveryStore:
        (any WorkspaceMutationTextRecoveryPersisting)? = nil,
        reportedTrashBookmarkAccess: any ReportedTrashBookmarkAccessing =
            ProductionReportedTrashBookmarkAccess(),
        shouldRestoreLastOpenedFile: Bool = !AppState.isRunningUnderXCTest,
        userDefaults: UserDefaults = .standard
    ) {
        // Side effects keep their pre-B1 order: recovery store construction, preferences,
        // layout restoration, recents, then each recovery store's single `load()`.
        let editorImageThumbnailAdapter = WorkspaceEditorImageThumbnailAdapter(
            provider: workspaceImageThumbnailProvider
        )
        workspaceRootContext = WorkspaceRootContext()
        let operationRecoveryStore =
            workspaceMutationOperationRecoveryStore
                ?? Self.makeDefaultWorkspaceMutationOperationRecoveryStore()
        let textRecoveryStore =
            workspaceMutationTextRecoveryStore
                ?? Self.makeDefaultWorkspaceMutationTextRecoveryStore()
        let preferences = PlainsongPreferences(userDefaults: userDefaults)
        let restoredLayout = Self.restoreLayoutMode(
            from: userDefaults,
            isExperimentalWYSIWYGEnabled: preferences.experimentalWYSIWYGEnabled
        )
        registry = AppDocumentRegistry(
            fileStore: fileStore,
            coherentFileReader: coherentFileReader,
            externalReloadApplicationPreparer: externalReloadApplicationPreparer,
            lastOpenedFileStore: lastOpenedFileStore,
            recentItemStore: recentItemStore,
            directoryScanner: directoryScanner,
            workspaceSearchStreamProvider: workspaceSearchStreamProvider,
            workspaceSearchLimits: workspaceSearchLimits,
            workspaceSearchDebounceNanoseconds: workspaceSearchDebounceNanoseconds,
            editorImageThumbnailAdapter: editorImageThumbnailAdapter,
            fileOperations: fileOperations,
            workspaceMutationOperationRecoveryStore: operationRecoveryStore,
            workspaceMutationTextRecoveryStore: textRecoveryStore,
            reportedTrashBookmarkAccess: reportedTrashBookmarkAccess,
            shouldRestoreLastOpenedFile: shouldRestoreLastOpenedFile,
            userDefaults: userDefaults,
            preferences: preferences
        )
        windowState = WindowState(
            currentDocument: currentDocument,
            layoutMode: restoredLayout.mode,
            wysiwygFallbackMessage: restoredLayout.fallbackMessage,
            replaceAuthority: registry.replaceAuthority
        )
        connectContainers()
        preferences.onChange = { [weak self] in
            self?.handlePreferencesChanged()
        }
        observeCurrentDocument()
        retainUnanchoredManagedSessionOwnership(for: currentDocument)
    }

    /// Each container's `didSet` hooks call back here, so a write through the façade or
    /// directly on a container advances the Replace authority generation and records
    /// Export as HTML… context changes exactly as the stored properties did.
    private func connectContainers() {
        windowState.onEditorReplaceAuthorityInputChange = { [weak self] fileID, line in
            self?.noteEditorReplaceAuthorityInputDidChange(fileID: fileID, line: line)
        }
        registry.onEditorReplaceAuthorityInputChange = { [weak self] fileID, line in
            self?.noteEditorReplaceAuthorityInputDidChange(fileID: fileID, line: line)
        }
        windowState.onExportHTMLContextChange = { [weak self] reason in
            self?.noteExportHTMLContextChange(reason)
        }
        workspaceRootContext.onExportHTMLContextChange = { [weak self] reason in
            self?.noteExportHTMLContextChange(reason)
        }
        containerChangeCancellables = [
            windowState.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            },
            registry.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            },
        ]
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
    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static func makeDefaultWorkspaceMutationOperationRecoveryStore()
        -> any WorkspaceMutationOperationRecoveryPersisting
    {
        if isRunningUnderXCTest {
            return TransientMutationOperationStore()
        }
        return WorkspaceMutationOperationRecoveryStore()
    }

    private static func makeDefaultWorkspaceMutationTextRecoveryStore()
        -> any WorkspaceMutationTextRecoveryPersisting
    {
        if isRunningUnderXCTest {
            return TransientMutationTextStore()
        }
        return WorkspaceMutationTextRecoveryStore()
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
