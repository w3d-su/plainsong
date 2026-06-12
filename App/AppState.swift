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

/// Top-level app state for the current single-file editing session.
@MainActor
final class AppState: ObservableObject {
    struct UserVisibleError: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published private(set) var currentDocument: DocumentSession
    @Published private(set) var isSaving = false
    @Published var presentedError: UserVisibleError?

    private let fileStore: MarkdownFileStore
    private let lastOpenedFileStore: any LastOpenedFilePersisting
    private var autosaveTask: Task<Void, Never>?
    private var statisticsTask: Task<Void, Never>?
    private var documentChangeCancellable: AnyCancellable?
    private let shouldRestoreLastOpenedFile: Bool
    private var didAttemptRestore = false

    init(
        currentDocument: DocumentSession = DocumentSession(),
        fileStore: MarkdownFileStore = MarkdownFileStore(),
        lastOpenedFileStore: any LastOpenedFilePersisting = LastOpenedFileStore(),
        shouldRestoreLastOpenedFile: Bool = !AppState.isRunningUnderXCTest
    ) {
        self.currentDocument = currentDocument
        self.fileStore = fileStore
        self.lastOpenedFileStore = lastOpenedFileStore
        self.shouldRestoreLastOpenedFile = shouldRestoreLastOpenedFile
        observeCurrentDocument()
    }

    var hasOpenDocument: Bool {
        currentDocument.fileURL != nil
    }

    var canSave: Bool {
        currentDocument.fileURL != nil && !isSaving
    }

    var windowTitle: String {
        currentDocument.fileURL?.lastPathComponent ?? "BlogEditor"
    }

    func restoreLastOpenedFileIfNeeded() {
        guard shouldRestoreLastOpenedFile, !didAttemptRestore, currentDocument.fileURL == nil else { return }
        didAttemptRestore = true

        do {
            guard let url = try lastOpenedFileStore.restore() else { return }
            try open(url: url, rememberAsLastOpened: false)
        } catch {
            present(error, title: "Could Not Reopen Last File")
        }
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.supportedContentTypes
        panel.message = "Choose a Markdown or MDX file."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        openExternalFile(url)
    }

    func openExternalFile(_ url: URL) {
        do {
            if currentDocument.isDirty {
                try saveCurrentDocument()
            }

            try open(url: url, rememberAsLastOpened: true)
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
        guard currentDocument.isDirty else { return }

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
        guard newText != currentDocument.text else { return }

        currentDocument.replaceText(newText, refreshStatistics: false)
        scheduleStatisticsRefresh()
        scheduleAutosave()
    }

    private func open(url: URL, rememberAsLastOpened: Bool) throws {
        guard FileKind(url: url) != nil else {
            throw AppStateError.unsupportedFile(url)
        }

        autosaveTask?.cancel()
        statisticsTask?.cancel()
        let file = try SecurityScopedAccess.withAccess(to: url) {
            try fileStore.load(url: url)
        }

        currentDocument.reset(
            text: file.text,
            url: file.url,
            fileKind: file.fileKind,
            isDirty: false
        )

        if rememberAsLastOpened {
            rememberLastOpenedFile(url)
        }
    }

    private func saveCurrentDocument() throws {
        guard let url = currentDocument.fileURL else { return }

        autosaveTask?.cancel()
        isSaving = true
        defer { isSaving = false }

        let text = currentDocument.text
        try SecurityScopedAccess.withAccess(to: url) {
            try fileStore.save(text: text, to: url)
        }
        currentDocument.markSaved(text: text, url: url)
    }

    private func rememberLastOpenedFile(_ url: URL) {
        do {
            try lastOpenedFileStore.save(url)
        } catch {
            present(error, title: "Could Not Remember Last File")
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
        guard currentDocument.fileURL != nil else { return }

        autosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
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
        guard currentDocument.isDirty else { return }

        do {
            try saveCurrentDocument()
        } catch {
            present(error, title: "Autosave Failed")
        }
    }

    private func present(_ error: Error, title: String) {
        presentedError = UserVisibleError(title: title, message: error.localizedDescription)
    }

    private func observeCurrentDocument() {
        documentChangeCancellable = currentDocument.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private static var supportedContentTypes: [UTType] {
        [
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "markdown"),
            UTType(filenameExtension: "mdx"),
        ].compactMap { $0 }
    }

    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

private enum AppStateError: LocalizedError {
    case unsupportedFile(URL)

    var errorDescription: String? {
        switch self {
        case let .unsupportedFile(url):
            "\(url.lastPathComponent) is not a supported Markdown file."
        }
    }
}
