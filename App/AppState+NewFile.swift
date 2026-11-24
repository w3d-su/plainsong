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

        do {
            try createEmptyFileAndOpen(at: url)
        } catch {
            present(error, title: "Could Not Create File")
        }
    }
}

@MainActor
extension AppState {
    /// Runs every refusal `open` can raise before the chosen file is emptied. The save panel
    /// may name an existing file, and a close blocked by a conflict or a failed save must
    /// leave that file's bytes alone.
    func createEmptyFileAndOpen(at url: URL) throws {
        guard FileKind(url: url) != nil else {
            throw AppStateError.unsupportedFile(url)
        }
        try refuseWindowFileOpenIfNeeded()
        try validateWorkspaceMutationRecoveryStoresLoaded(at: url)
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
        try closeWorkspaceForReplacement()
        try SecurityScopedAccess.withAccess(to: url) {
            try Data().write(to: url, options: [.atomic])
        }
        try open(url: url, rememberAsLastOpened: true, preserveWorkspace: false)
    }
}
