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
    @Published private(set) var isPreviewVisible: Bool
    @Published var workspaceRootURL: URL?
    @Published var workspaceTree: WorkspaceFileTree?
    @Published var showAllFiles = false
    @Published var completionWorkspace: CompletionWorkspace = .empty
    @Published var recentItemURLs: [URL] = []
    @Published var presentedError: UserVisibleError?
    @Published var externalChangePrompt: ExternalChangePrompt?
    @Published var missingFilePrompt: MissingFilePrompt?

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
        isPreviewVisible = userDefaults.bool(forKey: Self.previewVisibleDefaultsKey)
        self.shouldRestoreLastOpenedFile = shouldRestoreLastOpenedFile
        preferences = PlainsongPreferences(userDefaults: userDefaults)
        recentItemURLs = (try? recentItemStore.restore()) ?? []
        preferences.onChange = { [weak self] in
            self?.objectWillChange.send()
            self?.scheduleAutosave()
        }
        observeCurrentDocument()
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

    func flushAutosaveIfNeeded() {
        guard currentDocument.isDirty, canAutosaveCurrentDocument else { return }

        do {
            try saveCurrentDocument()
        } catch {
            present(error, title: "Could Not Save Changes")
        }
    }

    func dismissError() {
        presentedError = nil
    }

    func replaceDocumentText(_ newText: String) {
        replaceDocumentText(newText, in: currentDocument)
    }

    func replaceDocumentText(_ newText: String, in session: DocumentSession) {
        guard session === currentDocument,
              newText != session.text
        else {
            return
        }

        session.replaceText(newText, refreshStatistics: false)
        if let url = session.fileURL?.standardizedFileURL {
            sessionPolicy.updateDirtyState(for: url, isDirty: session.isDirty)
        }
        scheduleStatisticsRefresh()
        scheduleCompletionWorkspaceRefresh(debounceNanoseconds: 250_000_000)
        scheduleAutosave()
    }

    func togglePreview() {
        setPreviewVisible(!isPreviewVisible)
    }

    func setPreviewVisible(_ isVisible: Bool) {
        guard isPreviewVisible != isVisible else { return }

        isPreviewVisible = isVisible
        userDefaults.set(isVisible, forKey: Self.previewVisibleDefaultsKey)
    }

    func setTaskCheckbox(line: Int, checked: Bool, version: Int) {
        guard version == currentDocument.version else { return }
        guard let lineRange = currentDocument.text.rangeOfOneBasedLine(line) else { return }

        let lineText = String(currentDocument.text[lineRange])
        guard let checkboxRange = Self.taskCheckboxStateRange(in: lineText) else { return }

        let desiredState = checked ? "x" : " "
        guard String(lineText[checkboxRange]) != desiredState else { return }

        var updatedLine = lineText
        updatedLine.replaceSubrange(checkboxRange, with: desiredState)

        var updatedText = currentDocument.text
        updatedText.replaceSubrange(lineRange, with: updatedLine)
        replaceDocumentText(updatedText)
    }

    func openPreviewLink(_ href: String) {
        guard !href.hasPrefix("#"),
              let baseURL = currentDocument.fileURL?.deletingLastPathComponent()
        else {
            return
        }

        let path = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? href
        let url = URL(fileURLWithPath: path, relativeTo: baseURL).standardizedFileURL
        guard FileKind(url: url) != nil else { return }

        let isWorkspaceLink = workspaceRootURL.map { Self.isDescendant(url, of: $0) } ?? false
        if isWorkspaceLink {
            openWorkspaceFile(url)
        } else {
            openExternalFile(url)
        }
    }

    private func scheduleStatisticsRefresh() {
        statisticsTask?.cancel()
        statisticsTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }

            // Counting a large document is O(n); keep it off the main thread.
            let text = currentDocument.text
            let statistics = await Task.detached(priority: .utility) {
                TextStatistics(text: text)
            }.value

            guard !Task.isCancelled else { return }
            currentDocument.applyStatistics(statistics)
        }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard canAutosaveCurrentDocument else { return }

        let delayNanoseconds = UInt64(preferences.autosaveIntervalSeconds * 1_000_000_000)
        autosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
                guard !Task.isCancelled else { return }
                self?.autosaveIfNeeded()
            } catch {
                return
            }
        }
    }

    /// Synchronous by design: a background write can race an explicit ⌘S or a
    /// terminate flush and land *older* content last. The write happens after 1 s of
    /// idle, so it is off the typing hot path; a proper serialized background writer
    /// can come with M3's file coordination if profiling ever shows this hitch.
    private func autosaveIfNeeded() {
        guard currentDocument.isDirty, canAutosaveCurrentDocument else { return }

        do {
            try saveCurrentDocument()
        } catch {
            present(error, title: "Autosave Failed")
        }
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

    private static let previewVisibleDefaultsKey = "Plainsong.preview.isVisible"

    private static func taskCheckboxStateRange(in line: String) -> Range<String.Index>? {
        let pattern = #"^\s*(?:[-*+]|\d+[.)])\s+\[([ xX])\]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let fullRange = NSRange(line.startIndex ..< line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, range: fullRange) else { return nil }
        return Range(match.range(at: 1), in: line)
    }

    private var canAutosaveCurrentDocument: Bool {
        guard let url = currentDocument.fileURL?.standardizedFileURL else { return false }
        return !detachedSessionURLs.contains(url) &&
            externalChangePrompt?.fileURL.standardizedFileURL != url &&
            missingFilePrompt?.fileURL.standardizedFileURL != url
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

private extension String {
    func rangeOfOneBasedLine(_ requestedLine: Int) -> Range<String.Index>? {
        guard requestedLine > 0 else { return nil }

        var currentLine = 1
        var lineStart = startIndex

        while currentLine < requestedLine {
            guard let newline = self[lineStart...].firstIndex(where: \.isNewline) else {
                return nil
            }
            lineStart = index(after: newline)
            currentLine += 1
        }

        let lineEnd = self[lineStart...].firstIndex(where: \.isNewline) ?? endIndex
        return lineStart ..< lineEnd
    }
}
