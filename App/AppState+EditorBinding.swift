import EditorKit
import Foundation
import MarkdownCore
import SwiftUI

@MainActor
extension AppState {
    func editorDocumentBinding(for session: DocumentSession) -> AppEditorDocumentBinding {
        let sessionIdentity = ObjectIdentifier(session)
        let bindingID: EditorDocumentBindingID
        if let existing = registeredEditorDocumentBindingID(for: session) {
            bindingID = existing
        } else {
            if let staleID = editorDocumentBindingIDs[sessionIdentity] {
                editorDocumentBindingSessions[staleID] = nil
            }
            bindingID = EditorDocumentBindingID()
            editorDocumentBindingIDs[sessionIdentity] = bindingID
            editorDocumentBindingSessions[bindingID] = session
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
        switch event {
        case let .installed(installedID):
            guard installedID == bindingID,
                  isRegisteredEditorDocumentBinding(bindingID, session: session),
                  isManagedEditorSession(session) || isRetiredEditorDocumentBinding(
                      bindingID,
                      session: session
                  )
            else {
                return
            }
            let previousLease = installedEditorDocumentBindingLease
            if previousLease?.id == bindingID, previousLease?.session === session {
                return
            }
            installedEditorDocumentBindingLease = InstalledEditorDocumentBindingLease(
                id: bindingID,
                session: session
            )
            if let previousLease,
               previousLease.id != bindingID || previousLease.session !== session
            {
                markRetiredEditorDocumentBindingEnded(
                    previousLease.id,
                    session: previousLease.session
                )
                reconcileSessionPolicyAfterEditorLeaseChange()
            }
        case let .revoked(revokedID):
            guard revokedID == bindingID else { return }

            var didHandleExactRevocation = false
            if let lease = installedEditorDocumentBindingLease,
               lease.id == bindingID,
               lease.session === session
            {
                installedEditorDocumentBindingLease = nil
                didHandleExactRevocation = true
            }

            if markRetiredEditorDocumentBindingEnded(bindingID, session: session) {
                didHandleExactRevocation = true
            }

            guard didHandleExactRevocation else { return }
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
        guard let bindingID = registeredEditorDocumentBindingID(for: session) else { return }
        removeEditorDocumentBindingRegistration(for: session, bindingID: bindingID)
    }

    func removeEditorDocumentBindingRegistration(
        for session: DocumentSession,
        bindingID: EditorDocumentBindingID
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        guard editorDocumentBindingIDs[sessionIdentity] == bindingID,
              editorDocumentBindingSessions[bindingID] === session
        else {
            return
        }

        editorDocumentBindingIDs[sessionIdentity] = nil
        editorDocumentBindingSessions[bindingID] = nil
    }

    func isRetiredEditorSession(_ session: DocumentSession) -> Bool {
        retiredEditorDocumentBindings.values.contains { retirement in
            retirement.session === session
        }
    }

    func finishRetiredEditorDocumentBindingsIfPossible(for session: DocumentSession) {
        let bindingIDs = retiredEditorDocumentBindings.compactMap { bindingID, retirement in
            retirement.session === session && !retirement.isAwaitingBindingEnd ? bindingID : nil
        }
        for bindingID in bindingIDs {
            finishRetiredEditorDocumentBindingIfPossible(bindingID)
        }
    }

    private func isAuthorizedEditorDocumentBinding(
        _ bindingID: EditorDocumentBindingID,
        session: DocumentSession
    ) -> Bool {
        guard let lease = installedEditorDocumentBindingLease,
              lease.id == bindingID,
              lease.session === session,
              isRegisteredEditorDocumentBinding(bindingID, session: session)
        else {
            return false
        }
        return isManagedEditorSession(session) || isRetiredEditorDocumentBinding(
            bindingID,
            session: session
        )
    }

    private func registeredEditorDocumentBindingID(
        for session: DocumentSession
    ) -> EditorDocumentBindingID? {
        let sessionIdentity = ObjectIdentifier(session)
        guard let bindingID = editorDocumentBindingIDs[sessionIdentity] else { return nil }
        guard editorDocumentBindingSessions[bindingID] === session else {
            if editorDocumentBindingSessions[bindingID] == nil {
                editorDocumentBindingIDs[sessionIdentity] = nil
            }
            return nil
        }
        return bindingID
    }

    private func isRegisteredEditorDocumentBinding(
        _ bindingID: EditorDocumentBindingID,
        session: DocumentSession
    ) -> Bool {
        registeredEditorDocumentBindingID(for: session) == bindingID
    }

    private func isRetiredEditorDocumentBinding(
        _ bindingID: EditorDocumentBindingID,
        session: DocumentSession
    ) -> Bool {
        guard let retirement = retiredEditorDocumentBindings[bindingID] else { return false }
        return retirement.id == bindingID && retirement.session === session
    }

    @discardableResult
    private func markRetiredEditorDocumentBindingEnded(
        _ bindingID: EditorDocumentBindingID,
        session: DocumentSession
    ) -> Bool {
        guard var retirement = retiredEditorDocumentBindings[bindingID],
              retirement.session === session,
              retirement.isAwaitingBindingEnd
        else {
            return false
        }

        retirement.isAwaitingBindingEnd = false
        retiredEditorDocumentBindings[bindingID] = retirement
        removeEditorDocumentBindingRegistration(for: session, bindingID: bindingID)
        finishRetiredEditorDocumentBindingIfPossible(bindingID)
        return true
    }

    private func finishRetiredEditorDocumentBindingIfPossible(
        _ bindingID: EditorDocumentBindingID
    ) {
        guard let retirement = retiredEditorDocumentBindings[bindingID],
              !retirement.isAwaitingBindingEnd
        else {
            return
        }

        let session = retirement.session
        let canonicalURL = session.fileURL?.standardizedFileURL.resolvingSymlinksInPath()
        if let canonicalURL, pendingExternalTexts[canonicalURL] != nil {
            cancelAutosave(for: session)
            return
        }

        if session.isDirty {
            do {
                try save(session: session)
            } catch {
                present(error, title: "Could Not Save Retired File")
                return
            }
        }

        cancelAutosave(for: session)
        cancelStatisticsRefresh(for: session)
        retiredEditorDocumentBindings[bindingID] = nil
        retirement.securityScopedAuthority?.stop()
        removeEditorDocumentBindingRegistration(for: session, bindingID: bindingID)
        clearRetiredSessionMetadataIfUnreferenced(
            for: canonicalURL,
            session: session
        )
    }

    private func clearRetiredSessionMetadataIfUnreferenced(
        for canonicalURL: URL?,
        session: DocumentSession
    ) {
        guard let canonicalURL,
              currentDocument !== session,
              sessionCache[canonicalURL] !== session,
              !retiredEditorDocumentBindings.values.contains(where: { retirement in
                  retirement.session === session
              })
        else {
            return
        }

        lastKnownDiskHashes[canonicalURL] = nil
        lastKnownDiskModificationDates[canonicalURL] = nil
        pendingExternalTexts[canonicalURL] = nil
        detachedSessionURLs.remove(canonicalURL)
    }
}

struct AppEditorDocumentBinding {
    let id: EditorDocumentBindingID
    let text: Binding<String>
    let onLifecycle: (EditorDocumentBindingLifecycleEvent) -> Void
}
