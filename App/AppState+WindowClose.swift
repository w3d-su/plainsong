import Foundation
import MarkdownCore
import WorkspaceKit

/// Closing a workspace window or tab (`docs/window-state-gates.md` §6.2, WD8 in
/// `docs/decisions/2026-10-29-windows-wd8-hybrid-blocked-close.md`).
///
/// `approveWindowClose` runs from `windowShouldClose`, while AppKit can still keep the window
/// open, and does everything that can fail: the preflight, saving the document, and releasing
/// the root. `finishWindowClose` runs from `willClose` and cannot fail.
@MainActor
extension AppState {
    /// Returns false, with the reason shown in this window, when the window must stay open.
    func approveWindowClose() -> Bool {
        guard WindowOpenAdmission.admits(windowState) else { return true }
        do {
            try preflightWindowClose()
            try flushShownDocumentBeforeClose()
            try releaseWorkspaceRootBeforeClose()
        } catch {
            present(error, title: "Could Not Close Window")
            return false
        }
        KeyWindowRouter.shared.noteCloseApproved(self)
        return true
    }

    /// §6.2 steps 3–5 for a window AppKit is closing. A close that skipped
    /// `windowShouldClose` (a blank window this app closes itself) still leaves its root here.
    func finishWindowClose() {
        if workspaceRootURL != nil {
            if workspaceRootContext.facades.contains(where: { $0 !== self }) {
                detachSharedWorkspaceRoot()
            } else if (try? closeWorkspaceForReplacement()) == nil {
                detachSharedWorkspaceRoot()
            }
        }
        // Step 5: this window's own work.
        teardownWorkspaceSearch()
        completionWorkspaceTask?.cancel()
        completionWorkspaceTask = nil
        cancelPendingEditorNavigationIfNeeded()
        notifyEditorFindWorkspaceDidClose()
        // Step 3: release this window's editor installations and its writer now, instead of
        // whenever SwiftUI dismantles the editor. A later dismantle finds nothing to revoke.
        for (installation, session) in editorBindingInstallations
            where editorInstallationWindows[installation]?.window === windowState
        {
            revokeEditorDocumentBinding(installation, session: session, expectedBindingID: installation.bindingID)
        }
        // The window leaves `.windowDocuments`, so its document stops counting as installed and
        // the LRU trims it like any warm session. The façade keeps no document: the app-owned
        // façade reopens as an empty window.
        let previous = shownSession
        registry.unregister(windowState)
        shownSession = DocumentSession()
        observeCurrentDocument()
        notifyEditorFindDocumentDidSwitch()
        releaseUnreferencedSessionOwnership(for: previous)
        reconcileSessionPolicyAfterEditorLeaseChange()
        WindowPreviewControllers.invalidate(for: windowState)
    }

    /// The app-owned façade is shown again (Dock reopen, a file command, New Window): it rejoins
    /// every inventory as an empty window. Its blank owns nothing, so it takes no record.
    func reconnectReclaimedWindow() {
        WindowOpenAdmission.set(windowState, admits: true)
        registry.register(windowState)
    }

    /// WD8: whether a dirty document that cannot be saved may close and stay warm. The registry
    /// must keep its text (a warm session or a text-recovery copy), its authority (a retained
    /// location), and the state its prompt is rebuilt from when a window shows it again (a
    /// missing file, a change on disk, or a recovery record). The LRU cannot drop it while it
    /// stays dirty, because eviction saves first and that save is refused.
    func hasCloseRetentionProof(for session: DocumentSession) -> Bool {
        let sessionIdentity = ObjectIdentifier(session)
        if workspaceMutationTextRecoveryContexts[sessionIdentity] != nil,
           registry.contains(session, in: [.textRecovery])
        {
            return true
        }
        guard let url = sessionStateURL(for: session),
              registry.isWarmSession(session, at: url),
              retainedManagedSessionLocation(for: session) != nil
        else {
            return false
        }
        return detachedSessionURLs.contains(url)
            || pendingExternalTexts[url] != nil
            || pendingExternalFileVersions[url] != nil
    }

    /// Transient work and quarantine refuse the close; the user closes again once it settles.
    private func preflightWindowClose() throws {
        let session = shownSession
        let sessionIdentity = ObjectIdentifier(session)
        let url = sessionStateURL(for: session) ?? session.fileURL ?? workspaceRootURL
            ?? URL(fileURLWithPath: "Untitled")
        if hasPendingEditorSource(for: session) {
            throw AppStateError.pendingEditorSource(url)
        }
        if isSaving || externalReloadTasks[sessionIdentity] != nil
            || externalDiskInspectionTasks[sessionIdentity] != nil
            || pendingExternalReloadApplications[sessionIdentity] != nil
        {
            throw AppStateError.fileWorkInProgress(url)
        }
        if workspaceMutationNamespaceDepth > 0 {
            throw AppStateError.workspaceMutationInProgress(url)
        }
        if let insertion = registry.activeImageInsertions.values.first(where: { $0.window.window === windowState }) {
            throw AppStateError.workspaceMutationInProgress(insertion.rootURL)
        }
        if let write = indeterminateSessionWrites[sessionIdentity] {
            throw MarkdownFileStoreError.writeRequiresReconciliation(
                indeterminateSessionWriteContexts[sessionIdentity]?.location.fileURL ?? url,
                write
            )
        }
        if indeterminateWorkspaceMutationSessions.contains(sessionIdentity)
            || workspaceMutationWriteFences.contains(sessionIdentity)
        {
            throw WorkspaceMutationError.indeterminateSession(url)
        }
    }

    /// Step 2: a dirty document that can be saved is saved; a failed save keeps the window open.
    private func flushShownDocumentBeforeClose() throws {
        let session = shownSession
        guard session.isDirty else { return }
        if canAutosave(session: session) {
            try save(session: session)
            return
        }
        guard hasCloseRetentionProof(for: session) else {
            throw AppStateError.unsavedChangesPreventWindowClose(
                sessionStateURL(for: session) ?? session.fileURL ?? URL(fileURLWithPath: "Untitled")
            )
        }
    }

    /// Step 4: the last window on a root releases it (D1b); any other window leaves it
    /// (D1c). The release preflights, saves, and may refuse, so it runs before the close.
    private func releaseWorkspaceRootBeforeClose() throws {
        guard workspaceRootURL != nil else { return }
        if workspaceRootContext.facades.contains(where: { $0 !== self }) {
            detachSharedWorkspaceRoot()
            return
        }
        try closeWorkspaceForReplacement()
    }
}
