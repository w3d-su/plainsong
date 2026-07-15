import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    func closeWorkspace() {
        do {
            try closeWorkspaceForReplacement()
        } catch {
            present(error, title: "Could Not Close Workspace")
        }
    }

    func closeWorkspaceForReplacement() throws {
        let sessionsToClose = workspaceSessionsForClosure()
        let retirementPlans = workspaceRetirementPlans(for: sessionsToClose)
        var retiringSessionIdentities = Set(retirementPlans.map {
            ObjectIdentifier($0.session)
        })
        retiringSessionIdentities.formUnion(retiredEditorDocumentSessions.values.map {
            ObjectIdentifier($0.session)
        })

        if let conflictURL = firstUnretirableExternalConflict(
            excluding: retiringSessionIdentities
        ) {
            throw AppStateError.unresolvedExternalChange(conflictURL)
        }

        if let quarantinedSession = sessionsToClose.first(where: { session in
            !retiringSessionIdentities.contains(ObjectIdentifier(session))
                && indeterminateSessionWrites[ObjectIdentifier(session)] != nil
        }) {
            let sessionIdentity = ObjectIdentifier(quarantinedSession)
            let result = indeterminateSessionWrites[sessionIdentity]!
            guard let context = indeterminateSessionWriteContexts[sessionIdentity] else {
                throw AppStateError.invalidSessionIdentity(
                    sessionStateURL(for: quarantinedSession)
                        ?? quarantinedSession.fileURL
                        ?? URL(fileURLWithPath: "/")
                )
            }
            throw MarkdownFileStoreError.writeRequiresReconciliation(
                context.location.fileURL,
                result
            )
        }
        if let detachedPlan = retirementPlans.first(where: { plan in
            detachedSessionURLs.contains(plan.canonicalURL)
        }) {
            throw AppStateError.missingFile(detachedPlan.canonicalURL)
        }

        for session in sessionsToClose
            where !retiringSessionIdentities.contains(ObjectIdentifier(session)) && session.isDirty
        {
            try save(session: session)
        }
        commitWorkspaceClosure(
            sessions: sessionsToClose,
            retirementPlans: retirementPlans
        )
    }
}

@MainActor
private extension AppState {
    func workspaceSessionsForClosure() -> [DocumentSession] {
        var sessions = Array(sessionCache.values)
        sessions.append(contentsOf: retiredEditorDocumentSessions.values.map(\.session))
        sessions.append(contentsOf: editorDocumentBindingSessions.values)
        sessions.append(contentsOf: editorBindingInstallations.values)
        if currentDocument.fileURL != nil {
            sessions.append(currentDocument)
        }
        var seenSessions: Set<ObjectIdentifier> = []
        return sessions.filter { session in
            seenSessions.insert(ObjectIdentifier(session)).inserted
        }.sorted { first, second in
            sessionClosureIdentity(first).utf8.lexicographicallyPrecedes(
                sessionClosureIdentity(second).utf8
            )
        }
    }

    func sessionClosureIdentity(_ session: DocumentSession) -> String {
        sessionStateURL(for: session)?.absoluteString ?? ""
    }

    func workspaceRetirementPlans(
        for sessions: [DocumentSession]
    ) -> [EditorDocumentRetirementPlan] {
        let workspaceAuthority = workspaceSearchRootAuthority
        return sessions.compactMap { session in
            let sessionIdentity = ObjectIdentifier(session)
            guard let canonicalURL = sessionStateURL(for: session),
                  let retainedLocation = retainedManagedSessionLocation(for: session)
            else {
                return nil
            }

            let installations = editorBindingInstallations.reduce(
                into: Set<EditorDocumentBindingInstallation>()
            ) { result, entry in
                let (installation, owner) = entry
                guard owner === session,
                      editorDocumentBindingIDs[sessionIdentity] == installation.bindingID,
                      editorDocumentBindingSessions[installation.bindingID] === session
                else {
                    return
                }
                result.insert(installation)
            }
            guard !installations.isEmpty else { return nil }
            let requiresWorkspaceAuthority: Bool = if retainedLocation.rootAuthority == workspaceAuthority {
                true
            } else if case let .proven(proof)? =
                unanchoredManagedSessionOwnershipProofs[sessionIdentity]
            {
                proof.installedWorkspaceLocation?.rootAuthority ==
                    workspaceAuthority
            } else {
                false
            }
            if let existingRetirement = retiredEditorDocumentSessions[canonicalURL],
               existingRetirement.session === session,
               installations.isSubset(of: existingRetirement.awaitingInstallations),
               !requiresWorkspaceAuthority
            {
                // A later standalone replacement can enumerate an already-retired
                // session through its still-live editor registrations. With no new
                // installation or workspace authority to transfer, this is not a new
                // lifecycle boundary and must not supersede the reactivation read.
                return nil
            }
            return EditorDocumentRetirementPlan(
                canonicalURL: canonicalURL,
                session: session,
                installations: installations,
                requiresWorkspaceAuthority: requiresWorkspaceAuthority
            )
        }
    }

    func commitWorkspaceClosure(
        sessions: [DocumentSession],
        retirementPlans: [EditorDocumentRetirementPlan]
    ) {
        _ = advanceWorkspaceGeneration()
        workspaceReloadTask?.cancel()
        workspaceReloadTask = nil
        completionWorkspaceTask?.cancel()
        completionWorkspaceTask = nil
        workspaceWatcher?.stop()
        workspaceWatcher = nil
        transferWorkspaceAuthority(to: retirementPlans)
        clearClosedWorkspaceState(
            sessions: sessions,
            retirementPlans: retirementPlans
        )
    }

    func transferWorkspaceAuthority(
        to retirementPlans: [EditorDocumentRetirementPlan]
    ) {
        let activeAuthority = workspaceAccess
        workspaceAccess = nil
        let authorityOwner = activeAuthority.map(RetiredWorkspaceAuthorityOwner.init(authority:))

        for plan in retirementPlans {
            beginEditorDocumentSessionRetirement(
                canonicalURL: plan.canonicalURL,
                session: plan.session,
                installations: plan.installations,
                securityScopedAuthorityOwner: plan.requiresWorkspaceAuthority ? authorityOwner : nil
            )
        }

        if !retirementPlans.contains(where: \.requiresWorkspaceAuthority) {
            authorityOwner?.stopIfUnused()
        }
    }

    func clearClosedWorkspaceState(
        sessions: [DocumentSession],
        retirementPlans: [EditorDocumentRetirementPlan]
    ) {
        workspaceRootURL = nil
        workspaceTree = nil
        workspaceSnapshot = nil
        workspaceSearchRootAuthority = nil
        workspaceInstalledCaptureGeneration = nil
        completionWorkspace = .empty

        let retainedSessionIdentities = Set(retiredEditorDocumentSessions.values.map {
            ObjectIdentifier($0.session)
        })
        var proofRetainedSessionIdentities = retainedSessionIdentities
        if currentDocument.fileURL != nil {
            proofRetainedSessionIdentities.insert(ObjectIdentifier(currentDocument))
        }
        if !retainedSessionIdentities.contains(ObjectIdentifier(currentDocument)) {
            autosaveTask?.cancel()
            autosaveTask = nil
            statisticsTask?.cancel()
            statisticsTask = nil
        }
        cancelWorkspaceSessionTasks(excluding: retainedSessionIdentities)
        for session in sessions
            where !retainedSessionIdentities.contains(ObjectIdentifier(session))
        {
            removeEditorDocumentBindingRegistration(for: session)
        }
        sessionCache.removeAll()
        for session in sessions
            where !proofRetainedSessionIdentities.contains(ObjectIdentifier(session))
        {
            let sessionIdentity = ObjectIdentifier(session)
            anchoredSessionFileBindings[sessionIdentity] = nil
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] = nil
            indeterminateSessionWrites[sessionIdentity] = nil
            indeterminateSessionWriteContexts[sessionIdentity] = nil
        }
        sessionPolicy = WorkspaceSessionLRUPolicy(limit: 8)
        retainMetadataOnlyForRetiredEditorSessions()
        externalChangePrompt = nil
        missingFilePrompt = nil
        indeterminateFileWriteReconciliationPrompt = nil
        restoreRecoveryPrompt(for: currentDocument)
        if indeterminateSessionWrites[ObjectIdentifier(currentDocument)] != nil {
            refreshIndeterminateFileWriteReconciliation(for: currentDocument)
        }

        for plan in retirementPlans {
            finishRetiredEditorDocumentSessionIfPossible(for: plan.session)
        }
    }
}

private struct EditorDocumentRetirementPlan {
    let canonicalURL: URL
    let session: DocumentSession
    let installations: Set<EditorDocumentBindingInstallation>
    let requiresWorkspaceAuthority: Bool
}
