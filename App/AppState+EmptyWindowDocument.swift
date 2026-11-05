import Foundation
import MarkdownCore

/// The document of an empty workspace window (PR D2, `docs/window-state-gates.md` W3 bullet 5
/// evidence and §6.1).
@MainActor
extension AppState {
    /// Whether `session` is still exactly what `DocumentSession()` created: no file, no text,
    /// never edited, and no App state of its own. Launch, File › New Window, and a closed
    /// window's façade show one.
    ///
    /// It owns no file, so the Save Copy and export owner walks skip it. Every other
    /// document without a file still fails those walks closed: one that holds text or was
    /// ever edited, a text-recovery copy (which keeps its original URL), a session whose
    /// read failed, and anything with a binding, recovery record, external read, or fence.
    func isPristineEmptyDocument(_ session: DocumentSession) -> Bool {
        let identity = ObjectIdentifier(session)
        guard session.fileURL == nil,
              session.text.isEmpty,
              !session.isDirty,
              session.version == 0,
              sessionStateURL(for: session) == nil,
              anchoredSessionFileBindings[identity] == nil
        else {
            return false
        }
        switch unanchoredManagedSessionOwnershipProofs[identity] {
        case .none, .unavailable(fileURL: .none):
            break
        default:
            return false
        }
        return !registry.isWarmSession(session)
            && !isRetiredEditorSession(session)
            && !editorDocumentBindingSessions.values.contains { $0 === session }
            && !editorBindingInstallations.values.contains { $0 === session }
            && !pendingEditorSourceInstallations.values.contains { $0 === session }
            && !workspaceMutationRetainedRecoverySessions().contains { $0 === session }
            && workspaceMutationRecoveryIDBySession[identity] == nil
            && workspaceMutationTextRecoveryContexts[identity] == nil
            && externalDiskInspectionTasks[identity] == nil
            && externalReloadTasks[identity] == nil
            && pendingExternalReloadApplications[identity] == nil
            && indeterminateSessionWrites[identity] == nil
            && indeterminateSessionWriteContexts[identity] == nil
            && !indeterminateWorkspaceMutationSessions.contains(identity)
            && !workspaceMutationWriteFences.contains(identity)
    }

    /// No document and no root (WD7's reusable target, §5.2).
    var isEmptyWorkspaceWindow: Bool {
        workspaceRootURL == nil && isPristineEmptyDocument(shownSession)
    }
}
