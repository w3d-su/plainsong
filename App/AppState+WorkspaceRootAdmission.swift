import Foundation
import MarkdownCore
import WorkspaceKit

struct WorkspaceRootOpenConflict: LocalizedError, @unchecked Sendable {
    let message: String
    let target: RegisteredWindowState
    var errorDescription: String? {
        message
    }
}

@MainActor
extension AppState {
    /// Validate before touching the outgoing root. Same-root attachment is allowed;
    /// overlapping roots and another window's independent file require the Show action.
    func validateWorkspaceRootInstallation(url: URL, sharing: WorkspaceRootContext?) throws {
        try validateWorkspaceRootInstallation(url: url, sharing: sharing, installingWindow: windowState)
    }

    /// `installingWindow` is the window that would install the root; its own root and files
    /// are not conflicts because it replaces them. Nil checks for a new window (WD7), for which
    /// every open window is another window.
    func validateWorkspaceRootInstallation(
        url: URL,
        sharing: WorkspaceRootContext?,
        installingWindow: WindowState?
    ) throws {
        for context in registry.activeWorkspaceRoots where context !== sharing {
            guard let authority = context.registrationAuthority,
                  let other = context.facades.first(where: { $0.windowState !== installingWindow })
            else { continue }
            if Self.isDescendant(url, of: authority.canonicalRootURL) ||
                Self.isDescendant(authority.canonicalRootURL, of: url)
            {
                throw WorkspaceRootOpenConflict(
                    message: "This folder overlaps a workspace open in another window.",
                    target: RegisteredWindowState(window: other.windowState)
                )
            }
        }
        for window in registry.connectedWindows where window !== installingWindow {
            var sessions = [window.shownSession]
            sessions += registry.editorBindingInstallations.compactMap { installation, session in
                registry.editorInstallationWindows[installation]?.window === window ? session : nil
            }
            for session in sessions {
                guard let file = retainedManagedSessionLocation(for: session)?.fileURL ?? session.fileURL,
                      Self.isDescendant(file, of: url)
                else { continue }
                // Attaching to a root already open does not treat its own files as
                // standalone, even when a former participant still shows one after detach.
                if let sharedRoot = sharing?.registrationAuthority?.canonicalRootURL,
                   Self.isDescendant(file, of: sharedRoot)
                {
                    continue
                }
                // A window can already be on another root while its standalone editor
                // still awaits teardown. Classify the file, not just the window's mode.
                if let installedRoot = window.workspaceRootURL, Self.isDescendant(file, of: installedRoot) {
                    continue
                }
                throw WorkspaceRootOpenConflict(
                    message: "This folder contains a file open independently in another window.",
                    target: RegisteredWindowState(window: window)
                )
            }
        }
    }
}
