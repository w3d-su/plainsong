import AppKit
import Foundation
import MarkdownCore
import UniformTypeIdentifiers
import WorkspaceKit

/// File › Open…, Save, launch restoration, and error presentation.
extension AppState {
    func restoreLastOpenedFileIfNeeded() {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true

        restoreWorkspaceMutationOperationRecoveryIfNeeded()
        restoreWorkspaceMutationTextRecoveryIfNeeded()

        if let recoveryLoadError = workspaceMutationRecoveryLoadErrors.first {
            present(recoveryLoadError, title: "Could Not Load Workspace Recovery")
            return
        }
        guard workspaceMutationRecoveries.isEmpty,
              pendingWorkspaceMutationOperationRecoveryRecords.isEmpty,
              pendingWorkspaceMutationTextRecoveryRecords.isEmpty,
              workspaceMutationTextRecoveryContexts.isEmpty
        else {
            return
        }
        guard shouldRestoreLastOpenedFile, currentDocument.fileURL == nil else {
            return
        }
        do {
            if let url = try lastOpenedFileStore.restore() {
                try open(url: url, rememberAsLastOpened: false, preserveWorkspace: false)
            }
        } catch {
            present(error, title: "Could Not Reopen Last File")
        }
    }

    func openFile() {
        do {
            try validateWorkspaceMutationRecoveryStoresLoaded()
        } catch {
            present(error, title: "Could Not Open File")
            return
        }
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

    func present(_ error: Error, title: String) {
        presentedError = UserVisibleError(
            title: title,
            message: userVisibleDescription(for: error)
        )
    }

    private func userVisibleDescription(for error: Error) -> String {
        guard case let MarkdownFileStoreError.writeRequiresReconciliation(url, result) = error
        else {
            return error.localizedDescription
        }

        let reconciliation =
            "\(url.lastPathComponent) may already contain the new bytes and must be reconciled."
        return switch result.recoveryArtifact {
        case .none:
            reconciliation
        case let .retained(location):
            "\(reconciliation) A recovery artifact was retained at \(location.fileURL.path)."
        case let .removalIndeterminate(location):
            "\(reconciliation) Removal of the recovery artifact at \(location.fileURL.path) could not be confirmed."
        }
    }
}

extension AppState {
    static var supportedContentTypes: [UTType] {
        [
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "markdown"),
            UTType(filenameExtension: "mdx"),
        ].compactMap { $0 }
    }
}

/// Document facts the menus, toolbar, and preview read.
extension AppState {
    var hasOpenDocument: Bool {
        currentDocument.fileURL != nil
    }

    var canSave: Bool {
        guard let url = sessionStateURL(for: currentDocument) else {
            return false
        }
        return !hasWorkspaceMutationRecoveryLoadFailure &&
            !isSaving &&
            !hasPendingEditorSource(for: currentDocument) &&
            externalReloadTasks[ObjectIdentifier(currentDocument)] == nil &&
            indeterminateSessionWrites[ObjectIdentifier(currentDocument)] == nil &&
            !workspaceMutationWriteFences.contains(ObjectIdentifier(currentDocument)) &&
            !indeterminateWorkspaceMutationSessions.contains(ObjectIdentifier(currentDocument)) &&
            !detachedSessionURLs.contains(url) &&
            pendingExternalTexts[url] == nil &&
            pendingExternalFileVersions[url] == nil &&
            externalChangePrompt.map { !exactFileURLSpellingMatches($0.fileURL, url) } != false &&
            missingFilePrompt.map { !exactFileURLSpellingMatches($0.fileURL, url) } != false
    }

    var windowTitle: String {
        workspaceRootURL?.lastPathComponent ?? currentDocument.fileURL?.lastPathComponent ?? "Plainsong"
    }

    var previewAssetRootURL: URL? {
        workspaceRootURL
    }
}
