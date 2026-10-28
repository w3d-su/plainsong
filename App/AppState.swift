import AppKit
import Combine
import EditorKit
import MarkdownCore
import SwiftUI
import UniformTypeIdentifiers
import WorkspaceKit

/// Top-level app state. Windows PR C gives each workspace window one façade over its own
/// `WindowState` and `WorkspaceRootContext`, all sharing one `AppDocumentRegistry`
/// (`docs/window-state-gates.md` §10 row C). Menus, Find, and external opens resolve the
/// façade through `KeyWindowRouter` instead of a process-wide `AppState`.
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

    /// Layout writes live in `AppState+LayoutMode.swift`. The setters stay file-private.
    func storeLayoutMode(_ mode: EditorLayoutMode) {
        layoutMode = mode
    }

    func storeWYSIWYGFallbackMessage(_ message: String?) {
        wysiwygFallbackMessage = message
    }

    func storeEditorFocusRequestID(_ identifier: Int) {
        editorFocusRequestID = identifier
    }

    func storeWYSIWYGMechanismHealthy(_ isHealthy: Bool) {
        isWYSIWYGMechanismHealthy = isHealthy
    }

    init(
        shownSession: DocumentSession = DocumentSession(),
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
            shownSession: shownSession,
            layoutMode: restoredLayout.mode,
            wysiwygFallbackMessage: restoredLayout.fallbackMessage,
            replaceAuthority: registry.replaceAuthority
        )
        finishConnecting(registerWindow: true, admitsFileOperations: true)
    }

    /// A later workspace scene on an existing registry. An admitted sibling registers its
    /// window. A refused one is wired but not registered, so its empty document cannot make
    /// Save Copy fail closed (`docs/decisions/2026-10-27-windows-b2-registry-enumeration.md`).
    init(sharing registry: AppDocumentRegistry, admitsFileOperations: Bool) {
        self.registry = registry
        workspaceRootContext = WorkspaceRootContext()
        let restoredLayout = Self.restoreLayoutMode(
            from: registry.userDefaults,
            isExperimentalWYSIWYGEnabled: registry.preferences.experimentalWYSIWYGEnabled
        )
        windowState = WindowState(
            shownSession: DocumentSession(),
            layoutMode: restoredLayout.mode,
            wysiwygFallbackMessage: restoredLayout.fallbackMessage,
            replaceAuthority: registry.replaceAuthority
        )
        finishConnecting(registerWindow: admitsFileOperations, admitsFileOperations: admitsFileOperations)
    }

    func makeSiblingFacade(admitsFileOperations: Bool) -> AppState {
        AppState(sharing: registry, admitsFileOperations: admitsFileOperations)
    }

    private func finishConnecting(registerWindow: Bool, admitsFileOperations: Bool) {
        connectContainers(registerWindow: registerWindow)
        WindowOpenAdmission.set(windowState, admits: admitsFileOperations)
        KeyWindowRouter.shared.track(self)
        installSharedRegistryHook()
        installPreferencesFanoutIfNeeded()
        observeCurrentDocument()
        if admitsFileOperations {
            retainUnanchoredManagedSessionOwnership(for: shownSession)
        }
    }

    /// Each container's `didSet` hooks call back here, so a write through the façade or
    /// directly on a container advances the Replace authority generation and records
    /// Export as HTML… context changes exactly as the stored properties did.
    private func connectContainers(registerWindow: Bool) {
        wire(windowState)
        if registerWindow {
            registry.register(windowState)
        }
        workspaceRootContext.onExportHTMLContextChange = { [weak self] reason, _, _ in
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

    /// One registry callback fans out to every façade. The generation advances once.
    private func installSharedRegistryHook() {
        registry.onEditorReplaceAuthorityInputChange = { [weak registry] fileID, line in
            guard let registry else { return }
            let peers = KeyWindowRouter.shared.facades(in: registry)
            guard let first = peers.first else { return }
            first.noteEditorReplaceAuthorityInputDidChange(fileID: fileID, line: line)
            for peer in peers.dropFirst() {
                peer.scheduleStaleEditorReplaceBlockedStatusCheck()
            }
        }
    }

    /// The registry owns the one preferences callback. Siblings must not replace it.
    private func installPreferencesFanoutIfNeeded() {
        guard registry.preferences.onChange == nil else { return }
        registry.preferences.onChange = { [weak registry] in
            guard let registry else { return }
            for facade in KeyWindowRouter.shared.facades(in: registry) {
                facade.handlePreferencesChanged()
            }
        }
    }

    private func wire(_ window: WindowState) {
        window.onEditorReplaceAuthorityInputChange = { [weak self] fileID, line in
            self?.noteEditorReplaceAuthorityInputDidChange(fileID: fileID, line: line)
        }
        window.onExportHTMLContextChange = { [weak self] reason, _, _ in
            self?.noteExportHTMLContextChange(reason)
        }
    }

    /// Connects `window`'s hooks to this state, then adds it to every registry inventory
    /// (`docs/window-state-gates.md` §3.4 I2). A window must be connected before it can
    /// receive input.
    func connect(_ window: WindowState) {
        wire(window)
        registry.register(window)
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
