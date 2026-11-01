import EditorKit
import Foundation
import MarkdownCore
import SwiftUI

@MainActor
extension AppState {
    func installEditorDocumentBinding(
        _ installation: EditorDocumentBindingInstallation,
        session: DocumentSession,
        expectedBindingID: EditorDocumentBindingID
    ) {
        guard installation.bindingID == expectedBindingID,
              isRegisteredEditorDocumentBinding(expectedBindingID, session: session),
              isManagedEditorSession(session) || retirementOwnsBinding(
                  expectedBindingID,
                  session: session
              )
        else {
            return
        }

        if let existingOwner = editorBindingInstallations[installation] {
            guard existingOwner === session else {
                assertionFailure("One exact editor installation cannot own two sessions")
                return
            }
            return
        }

        editorInstallationWindows[installation] = RegisteredWindowState(window: windowState)
        editorBindingInstallations[installation] = session
        let sessionIdentity = ObjectIdentifier(session)
        if shownSession === session {
            transferEditorWriterForAdoption(of: session)
        }
        if editorWriterInstallations[sessionIdentity] == nil,
           !supersededEditorWriterInstallations.contains(installation)
        {
            editorWriterInstallations[sessionIdentity] = installation
        }
        assertSingleCrossWindowEditorInstallation(for: session)
        if let canonicalURL = retiredCanonicalURL(for: session),
           var retirement = retiredEditorDocumentSessions[canonicalURL]
        {
            retirement.bindingIDs.insert(expectedBindingID)
            retirement.awaitingInstallations.insert(installation)
            retiredEditorDocumentSessions[canonicalURL] = retirement
        }
        reconcileSessionPolicyAfterEditorLeaseChange()
    }

    func revokeEditorDocumentBinding(
        _ installation: EditorDocumentBindingInstallation,
        session: DocumentSession,
        expectedBindingID: EditorDocumentBindingID
    ) {
        guard installation.bindingID == expectedBindingID,
              editorBindingInstallations[installation] === session
        else {
            return
        }

        let sessionIdentity = ObjectIdentifier(session)
        let endedPendingSource = pendingEditorSourceInstallations.removeValue(
            forKey: installation
        ) === session
        if editorWriterInstallations[sessionIdentity] == installation {
            editorWriterInstallations[sessionIdentity] = nil
        }
        editorDocumentSourceSynchronizers[installation] = nil
        editorBindingInstallations[installation] = nil
        editorInstallationWindows[installation] = nil
        supersededEditorWriterInstallations.remove(installation)
        if editorWriterInstallations[sessionIdentity] == nil {
            restoreShownWriterIfUnowned(session)
        }
        // Keep main's retired-cold cleanup. Also drop a registration only when it
        // is the last reference holding a retained root scope. An unshown untitled
        // or recovery session keeps its registration.
        let retiredCold = retiredCanonicalURL(for: session).map {
            !registry.isWarmSession(session, at: $0)
        } ?? false
        let holdsRetainedRootScope = registry.retainedWorkspaceAuthorityOwners[sessionIdentity] != nil
        if !isEditorDocumentBindingInstalled(expectedBindingID, session: session),
           retiredCold || (
               holdsRetainedRootScope &&
                   !registry.isWarmSession(session) &&
                   (isRetiredEditorSession(session) || !registry.isShownByAnyWindow(session))
           )
        {
            removeEditorDocumentBindingRegistration(
                for: session,
                bindingID: expectedBindingID
            )
        }
        if let canonicalURL = retiredCanonicalURL(for: session),
           var retirement = retiredEditorDocumentSessions[canonicalURL]
        {
            retirement.awaitingInstallations.remove(installation)
            retiredEditorDocumentSessions[canonicalURL] = retirement
        }
        reconcileSessionPolicyAfterEditorLeaseChange()
        synchronizePendingExternalReloadIfPossible(for: session)
        finishRetiredEditorDocumentSessionIfPossible(for: session)
        releaseRetainedWorkspaceAuthorityIfUnreferenced(for: session)
        if endedPendingSource {
            resolveDeferredExternalChangeIfPossible(for: session)
            if session.isDirty, canAutosave(session: session) {
                scheduleAutosave(for: session)
            }
        }
    }

    func activateEditorDocumentWriter(
        _ installation: EditorDocumentBindingInstallation,
        baseSnapshot: EditorDocumentSourceSnapshot,
        session: DocumentSession,
        expectedBindingID: EditorDocumentBindingID
    ) -> EditorDocumentWriterEventResult {
        let currentSnapshot = EditorDocumentSourceSnapshot(
            source: session.text,
            revision: session.version
        )
        guard installation.bindingID == expectedBindingID,
              !supersededEditorWriterInstallations.contains(installation),
              isAuthorizedEditorDocumentBinding(installation, session: session)
        else {
            return .rejected(currentSnapshot)
        }

        let sessionIdentity = ObjectIdentifier(session)
        guard !isExternalSourceMutationFenced(for: session) ||
            canPublishEditorSourceDuringExternalResolution(installation, session: session)
        else {
            return .rejected(currentSnapshot)
        }
        // `DocumentSession.version` advances for every literal source change. Together
        // with exact installation ownership, an equal revision is the App-owned opaque
        // proof that the coordinator still has the current source. Do not scan either
        // full String on this ordinary pre-mutation path.
        guard baseSnapshot.revision == currentSnapshot.revision else {
            // A stale caller must not retain writer authority merely because it owned
            // the previous revision. The synchronized retry will acquire it again.
            if editorWriterInstallations[sessionIdentity] == installation,
               pendingEditorSourceInstallations[installation] == nil
            {
                editorWriterInstallations[sessionIdentity] = nil
                restoreShownWriterIfUnowned(session)
            }
            return .synchronize(currentSnapshot)
        }

        if let previousWriter = editorWriterInstallations[sessionIdentity],
           previousWriter != installation,
           pendingEditorSourceInstallations[previousWriter] === session
        {
            return .rejected(currentSnapshot)
        }
        editorWriterInstallations[sessionIdentity] = installation
        assertSingleCrossWindowEditorInstallation(for: session)
        return .activated(currentSnapshot)
    }

    func releaseEditorDocumentWriter(
        _ installation: EditorDocumentBindingInstallation,
        session: DocumentSession,
        expectedBindingID: EditorDocumentBindingID
    ) -> Bool {
        guard installation.bindingID == expectedBindingID else { return false }
        let sessionIdentity = ObjectIdentifier(session)
        guard editorWriterInstallations[sessionIdentity] == installation,
              pendingEditorSourceInstallations[installation] == nil
        else {
            return false
        }
        editorWriterInstallations[sessionIdentity] = nil
        restoreShownWriterIfUnowned(session)
        return true
    }

    func beginEditorPendingSource(
        _ installation: EditorDocumentBindingInstallation,
        session: DocumentSession,
        expectedBindingID: EditorDocumentBindingID
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        guard installation.bindingID == expectedBindingID,
              isAuthorizedEditorDocumentBinding(installation, session: session),
              editorWriterInstallations[sessionIdentity] == installation
        else {
            return
        }
        if let existingOwner = pendingEditorSourceInstallations[installation] {
            guard existingOwner === session else {
                assertionFailure("One exact editor installation cannot defer two sessions")
                return
            }
            return
        }
        pendingEditorSourceInstallations[installation] = session
        cancelAutosave(for: session)
    }

    func endEditorPendingSource(
        _ installation: EditorDocumentBindingInstallation,
        session: DocumentSession,
        expectedBindingID: EditorDocumentBindingID
    ) {
        guard installation.bindingID == expectedBindingID,
              pendingEditorSourceInstallations[installation] === session
        else {
            return
        }
        pendingEditorSourceInstallations[installation] = nil
        resolveDeferredExternalChangeIfPossible(for: session)
        if session.isDirty, canAutosave(session: session) {
            scheduleAutosave(for: session)
        }
    }

    func isAuthorizedEditorDocumentBinding(
        _ installation: EditorDocumentBindingInstallation,
        session: DocumentSession
    ) -> Bool {
        guard editorBindingInstallations[installation] === session,
              isRegisteredEditorDocumentBinding(installation.bindingID, session: session)
        else {
            return false
        }
        return isManagedEditorSession(session) || retirementOwnsBinding(
            installation.bindingID,
            session: session
        )
    }
}
