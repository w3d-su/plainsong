import EditorKit
import Foundation
import MarkdownCore
import SwiftUI

@MainActor
extension AppState {
    func editorDocumentBinding(for session: DocumentSession) -> AppEditorDocumentBinding {
        let sessionIdentity = ObjectIdentifier(session)
        let bindingID: EditorDocumentBindingID
        if let existing = editorDocumentBindingIDs[sessionIdentity] {
            bindingID = existing
        } else {
            bindingID = EditorDocumentBindingID()
            editorDocumentBindingIDs[sessionIdentity] = bindingID
        }

        return AppEditorDocumentBinding(
            id: bindingID,
            text: Binding(
                get: { session.text },
                set: { [weak self, weak session] newText in
                    guard let self, let session else { return }
                    replaceDocumentTextFromEditor(
                        newText,
                        in: session,
                        bindingID: bindingID
                    )
                }
            ),
            onLifecycle: { [weak self, weak session] event in
                guard let self, let session else { return }
                handleEditorDocumentBindingLifecycle(
                    event,
                    session: session,
                    bindingID: bindingID
                )
            }
        )
    }

    func replaceDocumentTextFromEditor(
        _ newText: String,
        in session: DocumentSession,
        bindingID: EditorDocumentBindingID
    ) {
        guard isAuthorizedEditorDocumentBinding(
            bindingID,
            session: session
        ), !ExactSourceText.matches(newText, session.text)
        else {
            return
        }

        applyDocumentText(newText, to: session)
    }

    func handleEditorDocumentBindingLifecycle(
        _ event: EditorDocumentBindingLifecycleEvent,
        session: DocumentSession,
        bindingID: EditorDocumentBindingID
    ) {
        guard editorDocumentBindingIDs[ObjectIdentifier(session)] == bindingID else {
            return
        }

        switch event {
        case let .installed(installedID):
            guard installedID == bindingID, isManagedEditorSession(session) else { return }
            let previousLease = installedEditorDocumentBindingLease
            installedEditorDocumentBindingLease = InstalledEditorDocumentBindingLease(
                id: bindingID,
                session: session
            )
            if let previousLease,
               previousLease.id != bindingID || previousLease.session !== session
            {
                reconcileSessionPolicyAfterEditorLeaseChange()
            }
        case let .revoked(revokedID):
            guard revokedID == bindingID,
                  let lease = installedEditorDocumentBindingLease,
                  lease.id == bindingID,
                  lease.session === session
            else {
                return
            }
            installedEditorDocumentBindingLease = nil
            reconcileSessionPolicyAfterEditorLeaseChange()
        }
    }

    func isManagedEditorSession(_ session: DocumentSession) -> Bool {
        guard let fileURL = session.fileURL?.standardizedFileURL.resolvingSymlinksInPath() else {
            return session === currentDocument
        }
        guard !detachedSessionURLs.contains(fileURL) else { return false }
        return session === currentDocument || sessionCache[fileURL] === session
    }

    func removeEditorDocumentBindingRegistration(for session: DocumentSession) {
        editorDocumentBindingIDs[ObjectIdentifier(session)] = nil
    }

    private func isAuthorizedEditorDocumentBinding(
        _ bindingID: EditorDocumentBindingID,
        session: DocumentSession
    ) -> Bool {
        guard let lease = installedEditorDocumentBindingLease,
              lease.id == bindingID,
              lease.session === session,
              editorDocumentBindingIDs[ObjectIdentifier(session)] == bindingID
        else {
            return false
        }
        return isManagedEditorSession(session)
    }
}

struct AppEditorDocumentBinding {
    let id: EditorDocumentBindingID
    let text: Binding<String>
    let onLifecycle: (EditorDocumentBindingLifecycleEvent) -> Void
}
