import AppKit
import Combine
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

/// Top-level app state for the current editor window.
@MainActor
final class AppState: ObservableObject {
    struct UserVisibleError: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

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
    @Published var showAllFiles = false
    @Published var completionWorkspace: CompletionWorkspace = .empty
    @Published var recentItemURLs: [URL] = []
    @Published var presentedError: UserVisibleError?
    @Published var externalChangePrompt: ExternalChangePrompt?
    @Published var missingFilePrompt: MissingFilePrompt?
    @Published private(set) var wysiwygFallbackMessage: String?

    let fileStore: MarkdownFileStore
    let lastOpenedFileStore: any LastOpenedFilePersisting
    let recentItemStore: any RecentItemPersisting
    let directoryScanner: WorkspaceDirectoryScanner
    let fileOperations: WorkspaceFileOperations
    let userDefaults: UserDefaults
    var autosaveTask: Task<Void, Never>?
    var statisticsTask: Task<Void, Never>?
    var workspaceReloadTask: Task<Void, Never>?
    var completionWorkspaceTask: Task<Void, Never>?
    var documentChangeCancellable: AnyCancellable?
    let shouldRestoreLastOpenedFile: Bool
    var didAttemptRestore = false
    var workspaceAccess: SecurityScopedResourceAccess?
    var workspaceWatcher: WorkspaceEventWatcher?
    var sessionCache: [URL: DocumentSession] = [:]
    var sessionPolicy = WorkspaceSessionLRUPolicy(limit: 8)
    var lastKnownDiskHashes: [URL: UInt64] = [:]
    var lastKnownDiskModificationDates: [URL: Date] = [:]
    var pendingExternalTexts: [URL: String] = [:]
    var detachedSessionURLs: Set<URL> = []
    let preferences: PlainsongPreferences
    private(set) var isWYSIWYGMechanismHealthy = true

    init(
        currentDocument: DocumentSession = DocumentSession(),
        fileStore: MarkdownFileStore = MarkdownFileStore(),
        lastOpenedFileStore: any LastOpenedFilePersisting = LastOpenedFileStore(),
        recentItemStore: any RecentItemPersisting = RecentItemStore(),
        directoryScanner: WorkspaceDirectoryScanner = WorkspaceDirectoryScanner(),
        fileOperations: WorkspaceFileOperations = WorkspaceFileOperations(),
        shouldRestoreLastOpenedFile: Bool = !AppState.isRunningUnderXCTest,
        userDefaults: UserDefaults = .standard
    ) {
        self.currentDocument = currentDocument
        self.fileStore = fileStore
        self.lastOpenedFileStore = lastOpenedFileStore
        self.recentItemStore = recentItemStore
        self.directoryScanner = directoryScanner
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
    }

    var isPreviewVisible: Bool {
        layoutMode.showsPreview
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

    var hasOpenDocument: Bool {
        currentDocument.fileURL != nil
    }

    var canSave: Bool {
        guard let url = currentDocument.fileURL?.standardizedFileURL else { return false }
        return !isSaving &&
            !detachedSessionURLs.contains(url) &&
            externalChangePrompt?.fileURL.standardizedFileURL != url &&
            missingFilePrompt?.fileURL.standardizedFileURL != url
    }

    var windowTitle: String {
        workspaceRootURL?.lastPathComponent ?? currentDocument.fileURL?.lastPathComponent ?? "Plainsong"
    }

    var previewAssetRootURL: URL? {
        workspaceRootURL
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
            if currentDocument.isDirty {
                try saveCurrentDocument()
            }

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
                let message = "Experimental WYSIWYG is disabled; falling back to source-only layout without changing source text."
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

enum AppStateError: LocalizedError {
    case unsupportedFile(URL)
    case missingFile(URL)
    case unresolvedExternalChange(URL)

    var errorDescription: String? {
        switch self {
        case let .unsupportedFile(url):
            "\(url.lastPathComponent) is not a supported Markdown file."
        case let .missingFile(url):
            "\(url.lastPathComponent) is no longer on disk. Save a copy or close it."
        case let .unresolvedExternalChange(url):
            "\(url.lastPathComponent) changed on disk. Choose Reload or Keep mine before saving."
        }
    }
}
