import AppKit
import Foundation
import MarkdownCore
import UniformTypeIdentifiers
import WorkspaceKit

/// File › Open…, Save, launch restoration, and error presentation.
extension AppState {
    func restoreLastOpenedFileIfNeeded() {
        // A refused extra scene must not consume the one app-global restore attempt.
        guard WindowOpenAdmission.admits(windowState) else { return }
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
        guard shouldRestoreLastOpenedFile, shownSession.fileURL == nil else {
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
            try refuseWindowFileOpenIfNeeded()
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
        let target = KeyWindowRouter.shared.facadeForExternalOpen(fallback: self)
        guard target === self else {
            target.openExternalFile(url)
            return
        }
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

    /// Session failures land on the window showing `session`. An unseen warm session uses
    /// the home window (`docs/window-state-gates.md` §3.2, W3 bullets 5–6).
    ///
    /// Only a refusal the user caused (Quit) passes `activatesWindow`. A background failure,
    /// such as autosave, leaves the key window alone: making another window key would send
    /// the user's next keystroke into a different document.
    func present(
        _ error: Error,
        title: String,
        for session: DocumentSession,
        activatesWindow: Bool = false
    ) {
        let visible = UserVisibleError(
            title: title,
            message: userVisibleDescription(for: error)
        )
        let window = registry.connectedWindows.first { $0.shownSession === session }
            ?? (KeyWindowRouter.shared.home(for: registry) ?? self).windowState
        window.presentedError = visible
        if activatesWindow {
            KeyWindowRouter.shared.focus(window)
        }
    }

    /// Termination refusals with no session. The user asked to quit, so the home window
    /// comes forward.
    func presentOnHome(_ error: Error, title: String) {
        let home = KeyWindowRouter.shared.home(for: registry) ?? self
        home.present(error, title: title)
        KeyWindowRouter.shared.focus(home.windowState)
    }

    func refuseWindowFileOpenIfNeeded() throws {
        guard WindowOpenAdmission.admits(windowState) else {
            throw AppStateError.windowFileOpenRefused
        }
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
        shownSession.fileURL != nil
    }

    var canSave: Bool {
        guard let url = sessionStateURL(for: shownSession) else {
            return false
        }
        return !hasWorkspaceMutationRecoveryLoadFailure &&
            !isSaving &&
            !hasPendingEditorSource(for: shownSession) &&
            externalReloadTasks[ObjectIdentifier(shownSession)] == nil &&
            indeterminateSessionWrites[ObjectIdentifier(shownSession)] == nil &&
            !workspaceMutationWriteFences.contains(ObjectIdentifier(shownSession)) &&
            !indeterminateWorkspaceMutationSessions.contains(ObjectIdentifier(shownSession)) &&
            !detachedSessionURLs.contains(url) &&
            pendingExternalTexts[url] == nil &&
            pendingExternalFileVersions[url] == nil &&
            !isSaveBlockedByWindowPrompt(at: url)
    }

    var windowTitle: String {
        workspaceRootURL?.lastPathComponent ?? shownSession.fileURL?.lastPathComponent ?? "Plainsong"
    }

    var previewAssetRootURL: URL? {
        workspaceRootURL
    }
}
