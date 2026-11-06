import AppKit
import Foundation
import MarkdownCore
import WorkspaceKit

/// File › Save As… (⇧⌘S).
///
/// Classic Save As: the shown session's current text is written to the chosen file and the
/// session — with every window showing it — continues editing that file. The original file
/// keeps the bytes it had on disk; unsaved edits go only to the new file. The write and the
/// rehoming are Missing File Save Copy's (`saveShownSessionCopy(from:to:)`), so destination
/// ownership, alias refusal, indeterminate-write quarantine, retirement, recents and Find
/// rekeying behave identically. A destination inside the open workspace appears in the tree on
/// the next file-system reload, which selects the shown document; a destination outside it
/// keeps the workspace open while the window edits the external file.
@MainActor
extension AppState {
    var canSaveAs: Bool {
        guard let url = sessionStateURL(for: shownSession) else { return false }
        if canSave { return true }
        return hasMissingFilePrompt(matching: url) && !hasWorkspaceMutationRecoveryLoadFailure
    }

    func saveAs() {
        guard canSaveAs, let url = sessionStateURL(for: shownSession) else { return }
        // A missing original is the banner's Save Copy; one panel and one error title for both.
        if hasMissingFilePrompt(matching: url) {
            saveMissingFileCopy()
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.directoryURL = url.deletingLastPathComponent()
        panel.allowedContentTypes = Self.supportedContentTypes
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            try saveCurrentDocumentAs(to: destination)
        } catch {
            present(error, title: "Could Not Save File")
        }
    }

    /// The panel-free half of `saveAs()`, which tests drive directly.
    func saveCurrentDocumentAs(to destinationURL: URL) throws {
        let session = shownSession
        guard let oldURL = sessionStateURL(for: session) else { return }
        if hasMissingFilePrompt(matching: oldURL) {
            try saveDetachedCurrentDocument(to: destinationURL)
            return
        }
        try validateWorkspaceMutationRecoveryStoresLoaded(at: oldURL)
        try validateSaveAsSourceState(for: session, at: oldURL)

        // Choosing the current file (or another spelling of it) is a plain Save. Rehoming onto
        // the session's own file would fail the Save Copy owner walk.
        if saveAsDestinationIsCurrentFile(destinationURL, session: session, oldURL: oldURL) {
            try save(session: session)
            return
        }
        try saveShownSessionCopy(from: oldURL, to: destinationURL)
    }
}

@MainActor
private extension AppState {
    func hasMissingFilePrompt(matching url: URL) -> Bool {
        guard let prompt = missingFilePrompt else { return false }
        return exactFileURLSpellingMatches(prompt.fileURL, url)
    }

    /// The source-side refusals of `save(session:)`. Save As must not move a session away
    /// from a file whose disk state is still being arbitrated or written.
    func validateSaveAsSourceState(for session: DocumentSession, at url: URL) throws {
        let sessionIdentity = ObjectIdentifier(session)
        guard !workspaceMutationWriteFences.contains(sessionIdentity),
              !indeterminateWorkspaceMutationSessions.contains(sessionIdentity)
        else {
            throw AppStateError.workspaceMutationInProgress(url)
        }
        guard !hasPendingEditorSource(for: session) else {
            throw AppStateError.pendingEditorSource(url)
        }
        if let indeterminate = indeterminateSessionWrites[sessionIdentity] {
            let reconciliationURL = indeterminateSessionWriteContexts[sessionIdentity]?.location.fileURL
                ?? url
            throw MarkdownFileStoreError.writeRequiresReconciliation(reconciliationURL, indeterminate)
        }
        guard !detachedSessionURLs.contains(url) else {
            throw AppStateError.missingFile(url)
        }
        guard pendingExternalTexts[url] == nil,
              pendingExternalFileVersions[url] == nil,
              !isSaveBlockedByWindowPrompt(at: url),
              externalReloadTasks[sessionIdentity] == nil,
              pendingExternalReloadApplications[sessionIdentity] == nil,
              deferredExternalChangeResolutions[url] == nil,
              externalDiskInspectionTasks[sessionIdentity] == nil
        else {
            throw AppStateError.unresolvedExternalChange(url)
        }
    }

    /// Same spelling, or a regular file whose identity is the one the session's retained
    /// binding proves (a case or normalization alias on this volume).
    func saveAsDestinationIsCurrentFile(
        _ destinationURL: URL,
        session: DocumentSession,
        oldURL: URL
    ) -> Bool {
        if exactFileURLSpellingMatches(destinationURL, oldURL) {
            return true
        }
        let sessionIdentity = ObjectIdentifier(session)
        let retainedIdentity: WorkspaceFileSystemIdentity? =
            if let binding = anchoredSessionFileBinding(for: session) {
                binding.identity
            } else if case let .proven(proof)? =
                unanchoredManagedSessionOwnershipProofs[sessionIdentity]
            {
                proof.identity
            } else {
                nil
            }
        guard let retainedIdentity,
              let location = try? WorkspaceFileSystemLocation(fileURL: destinationURL),
              let inspection = try? WorkspaceNoFollowFileInspector.inspectFileTarget(at: location),
              case let .regular(destinationIdentity) = inspection.state
        else {
            return false
        }
        return destinationIdentity == retainedIdentity
    }
}
