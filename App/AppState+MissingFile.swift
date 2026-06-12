import AppKit
import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    func saveMissingFileCopy() {
        guard let prompt = missingFilePrompt else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = prompt.fileURL.lastPathComponent
        panel.directoryURL = prompt.fileURL.deletingLastPathComponent()
        panel.allowedContentTypes = Self.supportedContentTypes

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try saveDetachedCurrentDocument(to: url)
        } catch {
            present(error, title: "Could Not Save Copy")
        }
    }

    func closeMissingFile() {
        guard let prompt = missingFilePrompt else { return }
        let key = prompt.fileURL.standardizedFileURL

        autosaveTask?.cancel()
        statisticsTask?.cancel()
        clearSessionState(for: key)

        if currentDocument.fileURL?.standardizedFileURL == key {
            currentDocument = DocumentSession()
            observeCurrentDocument()
        }
    }

    func clearPromptsNotMatchingCurrentDocument() {
        guard let url = currentDocument.fileURL?.standardizedFileURL else {
            externalChangePrompt = nil
            missingFilePrompt = nil
            return
        }

        if externalChangePrompt?.fileURL.standardizedFileURL != url {
            externalChangePrompt = nil
        }
        if missingFilePrompt?.fileURL.standardizedFileURL != url {
            missingFilePrompt = nil
        }
    }

    func saveDetachedCurrentDocument(to destinationURL: URL) throws {
        guard let oldURL = missingFilePrompt?.fileURL.standardizedFileURL,
              currentDocument.fileURL?.standardizedFileURL == oldURL
        else {
            return
        }

        let destination = destinationURL.standardizedFileURL
        let text = currentDocument.text
        try SecurityScopedAccess.withAccess(to: destination) {
            try fileStore.save(text: text, to: destination)
        }

        clearSessionState(for: oldURL)
        currentDocument.markSaved(text: text, url: destination)
        sessionCache[destination] = currentDocument
        recordKnownDiskText(text, for: destination)
        handleSessionAccess(url: destination, isDirty: false)
        rememberRecentItem(destination)
    }
}
