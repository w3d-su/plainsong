import AppKit
import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    /// File > New (⌘N). In a workspace, creates a deduplicated `Untitled.md` at the
    /// workspace root and opens it; in single-file mode, asks for a location first.
    func newFile() {
        if let workspaceRootURL {
            let name = Self.untitledFileName(in: workspaceRootURL)
            createWorkspaceFile(named: name, inDirectoryID: nil)
        } else {
            newFileViaSavePanel()
        }
    }

    static func untitledFileName(in directory: URL) -> String {
        let base = "Untitled"
        var candidate = "\(base).md"
        var counter = 2

        while FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(candidate).path
        ) {
            candidate = "\(base) \(counter).md"
            counter += 1
        }

        return candidate
    }
}

private extension AppState {
    func newFileViaSavePanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Untitled.md"
        panel.allowedContentTypes = Self.supportedContentTypes
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            guard FileKind(url: url) != nil else {
                throw AppStateError.unsupportedFile(url)
            }
            try SecurityScopedAccess.withAccess(to: url) {
                try Data().write(to: url, options: [.atomic])
            }
            try open(url: url, rememberAsLastOpened: true, preserveWorkspace: false)
        } catch {
            present(error, title: "Could Not Create File")
        }
    }
}
