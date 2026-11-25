import AppKit
import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    /// File > New (⌘N). In a workspace, creates a deduplicated `Untitled.md` at the
    /// workspace root and opens it; in single-file mode, asks for a location first.
    func newFile() {
        do {
            try refuseWindowFileOpenIfNeeded()
            try validateWorkspaceMutationRecoveryStoresLoaded()
        } catch {
            present(error, title: "Could Not Create File")
            return
        }
        if let workspaceRootURL {
            let name = Self.untitledFileName(
                in: workspaceRootURL,
                fileExtension: preferences.defaultFileExtension.rawValue
            )
            createWorkspaceFile(named: name, inDirectoryID: nil)
        } else {
            newFileViaSavePanel()
        }
    }

    static func untitledFileName(in directory: URL, fileExtension: String = "md") -> String {
        let base = "Untitled"
        var candidate = "\(base).\(fileExtension)"
        var counter = 2

        while FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(candidate).path
        ) {
            candidate = "\(base) \(counter).\(fileExtension)"
            counter += 1
        }

        return candidate
    }
}

private extension AppState {
    func newFileViaSavePanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Untitled.\(preferences.defaultFileExtension.rawValue)"
        panel.allowedContentTypes = Self.supportedContentTypes
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.defaultFolderURL

        guard panel.runModal() == .OK, let url = panel.url else { return }

        createNewFile(at: url)
    }
}

@MainActor
extension AppState {
    /// New File's save-panel choice follows the Open rule (§5.2): an empty window takes the new
    /// file, otherwise a new window does. The file is emptied by the window that opens it, so a
    /// new window that never appears leaves its bytes alone.
    func createNewFile(at url: URL) {
        let errorTitle = "Could Not Create File"
        do {
            try validateNewFile(at: url)
            guard !isEmptyWorkspaceWindow,
                  WorkspaceWindowRequests.shared.canOpenNewWindow(for: registry)
            else {
                try createEmptyFileAndOpen(at: url)
                return
            }
            WorkspaceWindowRequests.shared.openNewWindow(
                on: registry,
                then: { [weak self] facade in
                    facade.performInRequestedWindow(origin: self, errorTitle: errorTitle) {
                        try facade.createEmptyFileAndOpen(at: url)
                    }
                },
                ifItNeverOpens: { [weak self] in
                    self?.present(AppStateError.newWindowDidNotOpen(url), title: errorTitle)
                }
            )
        } catch {
            present(error, title: errorTitle)
        }
    }

    /// Runs every refusal the open can raise before the chosen file is emptied. The save panel
    /// may name an existing file, and a close blocked by a conflict or a failed save must
    /// leave that file's bytes alone.
    func createEmptyFileAndOpen(at url: URL) throws {
        try validateNewFile(at: url)
        try closeWorkspaceForReplacement()
        try SecurityScopedAccess.withAccess(to: url) {
            try Data().write(to: url, options: [.atomic])
        }
        try openInThisWindow(url)
    }

    private func validateNewFile(at url: URL) throws {
        guard FileKind(url: url) != nil else {
            throw AppStateError.unsupportedFile(url)
        }
        try refuseWindowFileOpenIfNeeded()
        try validateWorkspaceMutationRecoveryStoresLoaded(at: url)
        // WD1: replacing a file a window shows would overwrite its document on disk, so that
        // window comes forward instead and nothing is written.
        if let owner = windowShowingFile(at: url) {
            throw DocumentShownInAnotherWindow(fileURL: url, target: RegisteredWindowState(window: owner))
        }
        // Unsaved text for the chosen file would be written over the new empty file, or lost.
        let stateURL = url.standardizedFileURL
        let dirtyOwner = registry.sessions(from: [
            .warmCache, .retired, .editorBindings, .editorInstallations, .mutationRecovery, .windowDocuments,
        ]).first { session in
            guard session.isDirty, let ownedURL = sessionStateURL(for: session) else { return false }
            return exactFileURLSpellingMatches(ownedURL, stateURL)
        }
        guard dirtyOwner == nil else {
            throw AppStateError.duplicateSessionOwnership(url)
        }
    }
}
