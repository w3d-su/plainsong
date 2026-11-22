import MarkdownCore
@testable import Plainsong

@MainActor
extension AppState {
    /// Every reason `isEmptyWorkspaceWindow` is false, one name per condition of
    /// `isPristineEmptyDocument`, so a failing WD7 test says which state the blank kept.
    func emptyWorkspaceWindowObstructions() -> [String] {
        let session = shownSession
        let identity = ObjectIdentifier(session)
        var reasons: [String] = []
        func check(_ name: String, _ obstructs: Bool) {
            guard obstructs else { return }
            reasons.append(name)
        }
        check("workspaceRootURL", workspaceRootURL != nil)
        check("fileURL", session.fileURL != nil)
        check("text", !session.text.isEmpty)
        check("isDirty", session.isDirty)
        check("version", session.version != 0)
        check("sessionStateURL", sessionStateURL(for: session) != nil)
        check("anchoredSessionFileBinding", anchoredSessionFileBindings[identity] != nil)
        switch unanchoredManagedSessionOwnershipProofs[identity] {
        case .none, .unavailable(fileURL: .none):
            break
        default:
            reasons.append("unanchoredManagedSessionOwnershipProof")
        }
        check("warmSession", registry.isWarmSession(session))
        check("retiredEditorSession", isRetiredEditorSession(session))
        check("editorDocumentBinding", editorDocumentBindingSessions.values.contains { $0 === session })
        check("editorBindingInstallation", editorBindingInstallations.values.contains { $0 === session })
        check("pendingEditorSource", pendingEditorSourceInstallations.values.contains { $0 === session })
        check(
            "workspaceMutationRetainedRecovery",
            workspaceMutationRetainedRecoverySessions().contains { $0 === session }
        )
        check("workspaceMutationRecoveryID", workspaceMutationRecoveryIDBySession[identity] != nil)
        check("workspaceMutationTextRecovery", workspaceMutationTextRecoveryContexts[identity] != nil)
        check("externalDiskInspection", externalDiskInspectionTasks[identity] != nil)
        check("externalReload", externalReloadTasks[identity] != nil)
        check("pendingExternalReload", pendingExternalReloadApplications[identity] != nil)
        check("indeterminateSessionWrite", indeterminateSessionWrites[identity] != nil)
        check("indeterminateSessionWriteContext", indeterminateSessionWriteContexts[identity] != nil)
        check("indeterminateWorkspaceMutation", indeterminateWorkspaceMutationSessions.contains(identity))
        check("workspaceMutationWriteFence", workspaceMutationWriteFences.contains(identity))
        return reasons
    }
}
