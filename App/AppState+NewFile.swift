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
    /// New File's save-panel choice. Replacing a file another window shows would overwrite
    /// its document on disk, so that window comes forward instead and nothing is written
    /// (WD1). The new file then follows the Open rule (§5.2).
    func createNewFile(at url: URL) {
        do {
            guard FileKind(url: url) != nil else {
                throw AppStateError.unsupportedFile(url)
            }
            if let owner = windowShowingFile(at: url) {
                throw DocumentShownInAnotherWindow(fileURL: url, target: RegisteredWindowState(window: owner))
            }
            try SecurityScopedAccess.withAccess(to: url) {
                try Data().write(to: url, options: [.atomic])
            }
            routeOpen(url)
        } catch {
            present(error, title: "Could Not Create File")
        }
    }
}
