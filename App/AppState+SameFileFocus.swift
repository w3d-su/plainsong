import Foundation
import MarkdownCore
import WorkspaceKit

/// A request would make a file current in this window while another window already shows it
/// (WD1, `docs/window-state-gates.md` §4.1). Activation throws this before any side effect;
/// `present(_:title:)` turns it into focusing that window.
struct DocumentShownInAnotherWindow: LocalizedError, @unchecked Sendable {
    let fileURL: URL
    let target: RegisteredWindowState

    var errorDescription: String? {
        "\(fileURL.lastPathComponent) is already open in another window, which cannot be shown right now."
    }
}

@MainActor
extension AppState {
    /// Another connected window whose shown document is this file: the same session, the same
    /// state URL spelling or retained location, or the same physical file (a hard link, or a
    /// case or normalization alias). Warm sessions belong to no window, so they never match.
    /// `includingSelf` also considers this window.
    func otherWindowShowingFile(
        location: WorkspaceFileSystemLocation?,
        fileURL: URL?,
        identity: WorkspaceFileSystemIdentity?,
        session candidate: DocumentSession? = nil,
        includingSelf: Bool = false
    ) -> WindowState? {
        for window in registry.connectedWindows where includingSelf || window !== windowState {
            let shown = window.shownSession
            if let candidate, shown === candidate {
                return window
            }
            guard shown.fileURL != nil || sessionStateURL(for: shown) != nil else { continue }
            if let fileURL, let stateURL = sessionStateURL(for: shown),
               exactFileURLSpellingMatches(stateURL, fileURL)
            {
                return window
            }
            if let location, retainedManagedSessionLocation(for: shown) == location {
                return window
            }
            if let identity, retainedPhysicalIdentity(of: shown) == identity {
                return window
            }
        }
        return nil
    }

    /// The window a path-based open (Open…, Open Recent, Finder, Dock, a preview link to a file
    /// outside the root, launch restore) must focus instead of opening `url` (WD1). With
    /// `includingSelf`, this window counts too, so an alias of its own document is not
    /// opened a second time.
    func windowShowingFile(at url: URL, includingSelf: Bool = true) -> WindowState? {
        guard let location = try? WorkspaceFileSystemLocation(fileURL: url) else {
            return otherWindowShowingFile(
                location: nil,
                fileURL: url,
                identity: nil,
                includingSelf: includingSelf
            )
        }
        let identity: WorkspaceFileSystemIdentity? = switch (
            try? WorkspaceNoFollowFileInspector.inspectFileTarget(at: location)
        )?.state {
        case let .regular(identity): identity
        case .missing, nil: nil
        }
        return otherWindowShowingFile(
            location: location,
            fileURL: location.fileURL,
            identity: identity,
            session: registry.warmSession(at: location.fileURL),
            includingSelf: includingSelf
        )
    }

    /// Throws when another window shows the file, so the open has no side effect here.
    func refuseIfShownInAnotherWindow(
        location: WorkspaceFileSystemLocation?,
        fileURL: URL,
        identity: WorkspaceFileSystemIdentity?,
        session: DocumentSession? = nil
    ) throws {
        guard let owner = otherWindowShowingFile(
            location: location,
            fileURL: fileURL,
            identity: identity,
            session: session
        ) else {
            return
        }
        throw DocumentShownInAnotherWindow(fileURL: fileURL, target: RegisteredWindowState(window: owner))
    }

    /// WD1: bring the window that shows the file forward. When that window cannot come forward
    /// (it is closing or presenting a sheet), refuse here instead, without changing either window.
    func focusWindowShowingDocument(_ shown: DocumentShownInAnotherWindow) {
        if let window = shown.target.window, KeyWindowRouter.shared.focusIfPossible(window) {
            return
        }
        presentedError = UserVisibleError(
            title: "Already Open in Another Window",
            message: shown.errorDescription ?? ""
        )
    }

    /// A recovery action that would show `session` here focuses the window already showing
    /// it instead. Returns whether it did (or refused because that window cannot come forward).
    func focusOtherWindowShowing(_ session: DocumentSession) -> Bool {
        guard let owner = otherWindowShowingFile(location: nil, fileURL: nil, identity: nil, session: session)
        else {
            return false
        }
        focusWindowShowingDocument(DocumentShownInAnotherWindow(
            fileURL: sessionStateURL(for: session) ?? session.fileURL ?? URL(fileURLWithPath: "/"),
            target: RegisteredWindowState(window: owner)
        ))
        return true
    }

    private func retainedPhysicalIdentity(of session: DocumentSession) -> WorkspaceFileSystemIdentity? {
        let sessionIdentity = ObjectIdentifier(session)
        if let binding = anchoredSessionFileBindings[sessionIdentity] {
            return binding.identity
        }
        if case let .proven(proof)? = unanchoredManagedSessionOwnershipProofs[sessionIdentity] {
            return proof.identity
        }
        return nil
    }
}
