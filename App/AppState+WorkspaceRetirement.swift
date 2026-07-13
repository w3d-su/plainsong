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
        if let conflictURL = firstUnretirableExternalConflict(excluding: retirementLease?.session) {
            throw AppStateError.unresolvedExternalChange(conflictURL)
        }

        let sessionsToClose = workspaceSessionsForClosure()
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
        session.fileURL?.standardizedFileURL.resolvingSymlinksInPath().absoluteString ?? ""
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
              let workspaceRootURL,
              let fileURL = retirementLease.session.fileURL,
              WorkspaceRootContainment.isContained(fileURL, in: workspaceRootURL)
        else {
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
    }
}
