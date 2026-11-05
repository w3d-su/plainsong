import Foundation
import MarkdownCore

@MainActor
extension AppState {
    /// A last-root release may leave a file installed in a different window. Preserve
    /// its grant independently from retirement, whose teardown must not stop that grant.
    func retainWorkspaceAuthority(_ owner: RetiredWorkspaceAuthorityOwner, for session: DocumentSession) {
        let identity = ObjectIdentifier(session)
        guard !(registry.retainedWorkspaceAuthorityOwners[identity] ?? []).contains(where: { $0 === owner }) else {
            return
        }
        owner.retain(session)
        registry.retainedWorkspaceAuthorityOwners[identity, default: []].append(owner)
    }

    func releaseRetainedWorkspaceAuthorityIfUnreferenced(for session: DocumentSession) {
        let identity = ObjectIdentifier(session)
        guard registry.retainedWorkspaceAuthorityOwners[identity] != nil,
              !registry.contains(session, in: [
                  .windowDocuments, .warmCache, .retired, .editorBindings, .editorInstallations, .mutationRecovery,
              ]),
              !pendingEditorSourceInstallations.values.contains(where: { $0 === session }),
              externalDiskInspectionTasks[identity] == nil,
              externalReloadTasks[identity] == nil,
              pendingExternalReloadApplications[identity] == nil,
              indeterminateSessionWrites[identity] == nil,
              !indeterminateWorkspaceMutationSessions.contains(identity),
              !workspaceMutationWriteFences.contains(identity)
        else { return }
        for owner in registry.retainedWorkspaceAuthorityOwners.removeValue(forKey: identity) ?? [] {
            owner.release(session)
        }
    }
}

@MainActor
extension AppState {
    /// The last revoke keeps a session's registration while another window still shows it.
    /// Once no window shows it and it is cold, not retired, and installed nowhere, that
    /// registration is the last reference on its retained root scope. Dropping it lets the
    /// scope stop, whichever of revoke and switch-away came last.
    func removeRetainedRootScopeRegistrationIfUnreferenced(for session: DocumentSession) {
        let identity = ObjectIdentifier(session)
        guard registry.retainedWorkspaceAuthorityOwners[identity] != nil,
              editorDocumentBindingIDs[identity] != nil,
              !registry.isShownByAnyWindow(session),
              !registry.isWarmSession(session),
              !isRetiredEditorSession(session),
              !editorBindingInstallations.values.contains(where: { $0 === session }),
              !pendingEditorSourceInstallations.values.contains(where: { $0 === session })
        else { return }
        removeEditorDocumentBindingRegistration(for: session)
    }
}
