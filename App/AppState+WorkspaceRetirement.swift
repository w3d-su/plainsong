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
        let retirementLease = editorDocumentBindingLeaseEligibleForRetirement()
        let sessionsToClose = workspaceSessionsForClosure()
        if let quarantinedSession = sessionsToClose.first(where: { session in
            session !== retirementLease?.session
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
        if let conflictURL = firstUnretirableExternalConflict(excluding: retirementLease?.session) {
            throw AppStateError.unresolvedExternalChange(conflictURL)
        }

        if let retirementLease,
           let retirementURL = sessionStateURL(for: retirementLease.session),
           detachedSessionURLs.contains(retirementURL)
        {
            throw AppStateError.missingFile(retirementURL)
        }
        for session in sessionsToClose where session !== retirementLease?.session && session.isDirty {
            try save(session: session)
        }
        commitWorkspaceClosure(
            sessions: sessionsToClose,
            retirementLease: retirementLease
        )
    }
}

@MainActor
private extension AppState {
    func workspaceSessionsForClosure() -> [DocumentSession] {
        var sessions = Array(sessionCache.values)
        sessions.append(contentsOf: retiredEditorDocumentBindings.values.map(\.session))
        sessions.append(contentsOf: editorDocumentBindingSessions.values)
        if let installedSession = installedEditorDocumentBindingLease?.session {
            sessions.append(installedSession)
        }
        if currentDocument.fileURL != nil {
            sessions.append(currentDocument)
        }
        var seenSessions: Set<ObjectIdentifier> = []
        return sessions.filter { session in
            seenSessions.insert(ObjectIdentifier(session)).inserted
        }.sorted { first, second in
            let firstIdentity = sessionClosureIdentity(first)
            let secondIdentity = sessionClosureIdentity(second)
            return firstIdentity.utf8.lexicographicallyPrecedes(secondIdentity.utf8)
        }
    }

    func sessionClosureIdentity(_ session: DocumentSession) -> String {
        sessionStateURL(for: session)?.absoluteString ?? ""
    }

    func commitWorkspaceClosure(
        sessions: [DocumentSession],
        retirementLease: InstalledEditorDocumentBindingLease?
    ) {
        _ = advanceWorkspaceGeneration()
        workspaceReloadTask?.cancel()
        workspaceReloadTask = nil
        completionWorkspaceTask?.cancel()
        completionWorkspaceTask = nil
        workspaceWatcher?.stop()
        workspaceWatcher = nil
        transferWorkspaceAuthority(to: retirementLease)
        clearClosedWorkspaceState(sessions: sessions, retirementLease: retirementLease)
    }

    func transferWorkspaceAuthority(to retirementLease: InstalledEditorDocumentBindingLease?) {
        let activeAuthority = workspaceAccess
        let retiringAuthority = securityScopedAuthority(
            activeAuthority,
            requiredBy: retirementLease
        )
        workspaceAccess = nil

        if let retirementLease {
            beginEditorDocumentBindingRetirement(
                retirementLease,
                securityScopedAuthority: retiringAuthority
            )
            if retiringAuthority == nil {
                activeAuthority?.stop()
            }
        } else {
            activeAuthority?.stop()
        }
    }

    func securityScopedAuthority(
        _ authority: SecurityScopedResourceAccess?,
        requiredBy retirementLease: InstalledEditorDocumentBindingLease?
    ) -> SecurityScopedResourceAccess? {
        guard let retirementLease,
              let installedAuthority = workspaceSearchRootAuthority
        else {
            return nil
        }
        if let retainedLocation = retainedAnchoredSessionLocation(
            for: retirementLease.session
        ) {
            guard retainedLocation.rootAuthority == installedAuthority else { return nil }
            return authority
        }
        let sessionIdentity = ObjectIdentifier(retirementLease.session)
        guard case let .proven(proof) =
            unanchoredManagedSessionOwnershipProofs[sessionIdentity]
        else {
            return nil
        }
        guard proof.installedWorkspaceLocation?.rootAuthority == installedAuthority else {
            return nil
        }
        return authority
    }

    func clearClosedWorkspaceState(
        sessions: [DocumentSession],
        retirementLease: InstalledEditorDocumentBindingLease?
    ) {
        workspaceRootURL = nil
        workspaceTree = nil
        workspaceSnapshot = nil
        workspaceSearchRootAuthority = nil
        workspaceInstalledCaptureGeneration = nil
        completionWorkspace = .empty
        if retirementLease?.session !== currentDocument {
            autosaveTask?.cancel()
            autosaveTask = nil
            statisticsTask?.cancel()
            statisticsTask = nil
        }
        cancelWorkspaceSessionTasks(except: retirementLease?.session)
        for session in sessions where session !== retirementLease?.session {
            removeEditorDocumentBindingRegistration(for: session)
        }
        sessionCache.removeAll()
        sessionPolicy = WorkspaceSessionLRUPolicy(limit: 8)
        retainMetadataOnlyForRetiredEditorSessions()
        externalChangePrompt = nil
        missingFilePrompt = nil
        indeterminateFileWriteReconciliationPrompt = nil
        if let retirementLease,
           retirementLease.session === currentDocument,
           indeterminateSessionWrites[ObjectIdentifier(currentDocument)] != nil
        {
            refreshIndeterminateFileWriteReconciliation(for: currentDocument)
        }
    }
}
