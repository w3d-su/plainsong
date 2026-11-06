import Foundation
import MarkdownCore
import WorkspaceKit

/// The §5.2 "Same rule as Open" (`docs/window-state-gates.md`): WD1 focuses a window that
/// already shows the file, WD2 and §4.3 decide a root's context, and WD7 picks the window. An
/// empty target (no document and no root) takes the open; otherwise a new window does.
@MainActor
extension AppState {
    /// Opens `url` for a request this window received: File › Open…, Open Recent, the empty
    /// state, a preview link to a file outside this window's root, or New File's save panel.
    /// Finder, the Dock, and `open -a` arrive through `openExternalFile`, which first picks
    /// the frontmost workspace window by z-order.
    func routeOpen(_ url: URL) {
        do {
            try validateWorkspaceMutationRecoveryStoresLoaded(at: url)
            let isDirectory = try SecurityScopedAccess.withAccess(to: url) {
                try Self.isDirectory(url)
            }
            if !isDirectory {
                guard FileKind(url: url) != nil else {
                    throw AppStateError.unsupportedFile(url)
                }
                // WD1, across every window including this one.
                if let owner = windowShowingFile(at: url) {
                    focusWindowShowingDocument(DocumentShownInAnotherWindow(
                        fileURL: url,
                        target: RegisteredWindowState(window: owner)
                    ))
                    return
                }
            }
            guard !isEmptyWorkspaceWindow,
                  WorkspaceWindowRequests.shared.canOpenNewWindow(for: registry)
            else {
                // WD7: an empty window takes the open. Hosted fixtures have no scene for their
                // registry, so they keep opening here, as every window did before PR D2.
                try openInThisWindow(url)
                return
            }
            if isDirectory {
                // Refuse an overlapping root before a window appears for it (§4.3). When this
                // window is the only conflict (a folder inside its own root, or around its own
                // standalone file), no new window can take the folder, so it opens here,
                // replacing this window's workspace as Open did before PR D2.
                do {
                    try validateWorkspaceRootInstallation(
                        url: url,
                        sharing: matchingWorkspaceRoot(for: url),
                        installingWindow: nil
                    )
                } catch let conflict as WorkspaceRootOpenConflict where conflict.target.window === windowState {
                    try openInThisWindow(url)
                    return
                }
            }
            WorkspaceWindowRequests.shared.openNewWindow(
                on: registry,
                then: { [weak self] facade in facade.openInRequestedWindow(url, origin: self) },
                ifItNeverOpens: { [weak self] in
                    self?.present(AppStateError.newWindowDidNotOpen(url), title: "Could Not Open File")
                }
            )
        } catch {
            present(error, title: "Could Not Open File")
        }
    }

    /// Opens `url` in this window. A single file inside a root another window has open opens
    /// as a document of that root: this window attaches to the shared root context (WD2) and
    /// shows the file anchored there (§4.3, W6 bullet 8b).
    func openInThisWindow(_ url: URL) throws {
        let isDirectory = try SecurityScopedAccess.withAccess(to: url) {
            try Self.isDirectory(url)
        }
        guard !isDirectory, let context = openWorkspaceRoot(containing: url),
              let authority = context.registrationAuthority
        else {
            try open(url: url, rememberAsLastOpened: true, preserveWorkspace: false)
            return
        }
        try refuseWindowFileOpenIfNeeded()
        let location = try authority.canonicalizedLocation(forFileURL: url)
        if workspaceRootContext !== context || workspaceRootURL == nil {
            try openWorkspace(url: authority.originalRootURL, rememberAsLastOpened: false)
        }
        try activateAnchoredFileSession(at: location)
        synchronizeWorkspaceTreeSelection(for: shownSession)
        rememberLastOpenedFile(url)
        rememberRecentItem(url)
    }

    /// Runs in the new window a `routeOpen` requested. If the open fails there, the new window
    /// closes and the error appears in the window the request came from, so no blank window is
    /// left behind (WD7).
    func openInRequestedWindow(_ url: URL, origin: AppState?) {
        do {
            try openInThisWindow(url)
        } catch {
            let origin = origin.flatMap { origin in
                origin !== self && KeyWindowRouter.shared.hasAttachedWindow(origin) ? origin : nil
            }
            // With the requesting window gone, keep this window and show the error in it,
            // unless WD1 found the file in another window: then nothing needs this one.
            guard origin != nil || error is DocumentShownInAnotherWindow else {
                present(error, title: "Could Not Open File")
                return
            }
            KeyWindowRouter.shared.closeAttachedWindow(of: self, skippingCloseChecks: true)
            // WD1's focus, or its fallback refusal, also runs from the requesting window.
            let reporter = origin ?? KeyWindowRouter.shared.home(for: registry) ?? self
            reporter.present(error, title: "Could Not Open File")
        }
    }

    /// The live root context, open in some window, whose root contains `url`.
    func openWorkspaceRoot(containing url: URL) -> WorkspaceRootContext? {
        registry.activeWorkspaceRoots.first { context in
            guard !context.facades.isEmpty, let authority = context.registrationAuthority else {
                return false
            }
            return (try? authority.canonicalizedLocation(forFileURL: url)) != nil
        }
    }
}
