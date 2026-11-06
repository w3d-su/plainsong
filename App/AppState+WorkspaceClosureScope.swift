import Foundation
import MarkdownCore
import WorkspaceKit

/// Which sessions and recoveries one window's workspace closure covers (Windows D1b).
@MainActor
extension AppState {
    /// The closure preflights the closing window's own document and live installations,
    /// wherever they live, and every session the closing root's authority proves it owns,
    /// including sessions another window keeps.
    func isCoveredByWorkspaceClosure(_ session: DocumentSession) -> Bool {
        isOwnedByClosingWindow(session) || sessionBelongsToClosingRoot(session)
    }

    /// The document this window shows and any installation it still holds leave the window
    /// with the replacement, so the closure saves or retires them even outside the root.
    func isOwnedByClosingWindow(_ session: DocumentSession) -> Bool {
        if session === shownSession { return true }
        return editorBindingInstallations.contains { installation, owner in
            owner === session && registry.editorInstallationWindows[installation]?.window === windowState
        }
    }

    /// Membership that the closing root's authority proves. Before the first scan installs
    /// that authority nothing is proven, so no session can take the root's grant.
    func sessionBelongsToClosingRoot(_ session: DocumentSession) -> Bool {
        guard let authority = workspaceSearchRootAuthority else { return false }
        if let location = retainedManagedSessionLocation(for: session),
           location.rootAuthority == authority
        {
            return true
        }
        if case let .proven(proof)? = unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(session)],
           proof.installedWorkspaceLocation?.rootAuthority == authority
        {
            return true
        }
        return false
    }

    /// The first operation recovery this closure must not outrun, in
    /// `nextWorkspaceMutationRecovery()` order. A recovery fences the root its recorded
    /// locations name and the sessions it still holds, so another root's recovery stays with
    /// that root (W6 bullet 6). An unavailable record names no authority and still refuses
    /// every closure.
    func nextWorkspaceMutationRecoveryBlockingClosure() -> WorkspaceMutationRecoveryContext? {
        let authority = workspaceSearchRootAuthority
        return workspaceMutationRecoveries.values.filter { recovery in
            if case .unavailable = recovery { return true }
            if let authority,
               recovery.retainedCandidateLocations.contains(where: { $0.rootAuthority == authority })
            {
                return true
            }
            return recovery.remainingSessions.contains { isCoveredByWorkspaceClosure($0) }
        }.min { first, second in
            if first.sourceURL.absoluteString == second.sourceURL.absoluteString {
                return first.id.uuidString < second.id.uuidString
            }
            return first.sourceURL.absoluteString < second.sourceURL.absoluteString
        }
    }
}
