import EditorKit
import Foundation
import MarkdownCore
import SwiftUI

@MainActor
extension AppState {
    func registeredEditorDocumentBindingID(
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

    func isRegisteredEditorDocumentBinding(
        _ bindingID: EditorDocumentBindingID,
        session: DocumentSession
    ) -> Bool {
        registeredEditorDocumentBindingID(for: session) == bindingID
    }

    func retirementOwnsBinding(
        _ bindingID: EditorDocumentBindingID,
        session: DocumentSession
    ) -> Bool {
        retiredEditorDocumentSessions.values.contains { retirement in
            retirement.session === session && retirement.bindingIDs.contains(bindingID)
        }
    }

    func retiredCanonicalURL(for session: DocumentSession) -> URL? {
        let matches = retiredEditorDocumentSessions.compactMap { canonicalURL, retirement in
            retirement.session === session ? canonicalURL : nil
        }
        guard matches.count <= 1 else {
            assertionFailure("One session cannot have multiple retirement identities")
            return nil
        }
        return matches.first
    }

    func finishRetiredEditorDocumentSessionIfPossible(_ canonicalURL: URL) {
        guard let retirement = retiredEditorDocumentSessions[canonicalURL],
              retirement.awaitingInstallations.isEmpty
        else {
            return
        }

        let session = retirement.session
        let sessionIdentity = ObjectIdentifier(session)
        if externalDiskInspectionTasks[sessionIdentity] != nil ||
            externalReloadTasks[sessionIdentity] != nil ||
            pendingExternalReloadApplications[sessionIdentity] != nil ||
            deferredExternalChangeResolutions[canonicalURL] != nil ||
            indeterminateSessionWrites[sessionIdentity] != nil ||
            indeterminateWorkspaceMutationSessions.contains(sessionIdentity) ||
            workspaceMutationWriteFences.contains(sessionIdentity)
        {
            cancelAutosave(for: session)
            return
        }
        if pendingExternalTexts[canonicalURL] != nil ||
            pendingExternalFileVersions[canonicalURL] != nil ||
            detachedSessionURLs.contains(canonicalURL)
        {
            cancelAutosave(for: session)
            restoreRecoveryPrompt(for: session)
            return
        }

        if session.isDirty {
            do {
                try save(session: session)
            } catch {
                restoreRecoveryPrompt(for: session)
                present(error, title: "Could Not Save Retired File")
                return
            }
        }

        retiredEditorDocumentSessions[canonicalURL] = nil
        for owner in retirement.securityScopedAuthorityOwners {
            owner.release(session)
        }

        if liveEditorDocumentBindingInstallations(for: session).isEmpty {
            removeEditorDocumentBindingRegistration(for: session)
        }

        if !isManagedEditorSession(session) {
            cancelAutosave(for: session)
            cancelStatisticsRefresh(for: session)
            removeEditorDocumentBindingRegistration(for: session)
        }
        clearRetiredSessionMetadataIfUnreferenced(
            for: canonicalURL,
            session: session
        )
    }

    func clearRetiredSessionMetadataIfUnreferenced(
        for canonicalURL: URL,
        session: DocumentSession
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        guard indeterminateSessionWrites[sessionIdentity] == nil,
              !indeterminateWorkspaceMutationSessions.contains(sessionIdentity),
              !workspaceMutationWriteFences.contains(sessionIdentity)
        else {
            return
        }
        guard !registry.isShownByAnyWindow(session),
              !registry.isWarmSession(session, at: canonicalURL),
              !retiredEditorDocumentSessions.values.contains(where: { $0.session === session })
        else {
            return
        }

        lastKnownDiskHashes[canonicalURL] = nil
        lastKnownDiskModificationDates[canonicalURL] = nil
        clearExternalChangeConflict(at: canonicalURL)
        deferredExternalChangeResolutions[canonicalURL] = nil
        externalResolutionIntentCaptures[canonicalURL] = nil
        detachedSessionURLs.remove(canonicalURL)
        externalReloadTasks.removeValue(forKey: sessionIdentity)?.task.cancel()
        externalDiskInspectionTasks.removeValue(forKey: sessionIdentity)?.task.cancel()
        pendingExternalReloadApplications[sessionIdentity] = nil
        anchoredSessionFileBindings[sessionIdentity] = nil
        unanchoredManagedSessionOwnershipProofs[sessionIdentity] = nil
        discardEditorImageAssetDocumentAuthority(for: session)
        indeterminateSessionWrites[sessionIdentity] = nil
        indeterminateSessionWriteContexts[sessionIdentity] = nil
        indeterminateWorkspaceMutationSessions.remove(sessionIdentity)
    }
}
