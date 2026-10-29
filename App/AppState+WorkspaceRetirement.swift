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
        try validateWorkspaceMutationRecoveryStoresLoaded(
            at: workspaceRootURL ?? sessionStateURL(for: shownSession)
        )
        guard workspaceMutationNamespaceDepth == 0 else {
            throw AppStateError.workspaceMutationInProgress(
                workspaceRootURL ?? sessionStateURL(for: shownSession) ?? shownSession.fileURL
                    ?? URL(fileURLWithPath: "/")
            )
        }
        if let recovery = nextWorkspaceMutationRecovery() {
            throw WorkspaceMutationError.indeterminateSession(recovery.sourceURL)
        }
        // D1b: preflight and release only this root. Another root's fence, quarantine,
        // or conflict must not block, and must not be swept up with this close.
        let rootSessions = workspaceSessionsForRootPreflight()
        let sessionsToClose = rootSessions.filter { !isPreservedForAnotherWindow($0) }
        let preservedSessions = rootSessions.filter { isPreservedForAnotherWindow($0) }
        if let quarantinedSession = rootSessions.first(where: {
            indeterminateWorkspaceMutationSessions.contains(ObjectIdentifier($0))
        }) {
            throw WorkspaceMutationError.indeterminateSession(
                sessionStateURL(for: quarantinedSession)
                    ?? quarantinedSession.fileURL
                    ?? workspaceRootURL
                    ?? URL(fileURLWithPath: "/")
            )
        }
        let retirementPlans = workspaceRetirementPlans(for: sessionsToClose)
        var retiringSessionIdentities = Set(retirementPlans.map {
            ObjectIdentifier($0.session)
        })
        retiringSessionIdentities.formUnion(retiredEditorDocumentSessions.values.compactMap { retirement in
            sessionsToClose.contains { $0 === retirement.session } ? ObjectIdentifier(retirement.session) : nil
        })

        if let conflictURL = firstUnretirableExternalConflict(
            excluding: retiringSessionIdentities,
            among: rootSessions
        ) {
            throw AppStateError.unresolvedExternalChange(conflictURL)
        }

        if let quarantinedSession = rootSessions.first(where: { session in
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

        for session in rootSessions
            where !retiringSessionIdentities.contains(ObjectIdentifier(session)) && session.isDirty
        {
            try save(session: session)
        }
        commitWorkspaceClosure(
            sessions: sessionsToClose,
            retirementPlans: retirementPlans,
            preserving: preservedSessions
        )
    }
}

@MainActor
private extension AppState {
    /// Root closure covers its preserved sessions as well as the release set. Without
    /// a root, replacement retires only this window's shown and installed documents.
    func workspaceSessionsForRootPreflight() -> [DocumentSession] {
        registry.sessions(from: [
            .warmCache, .retired, .editorBindings, .editorInstallations, .mutationRecovery, .fileBackedWindowDocuments,
        ]).filter { session in
            sessionBelongsToClosingRoot(session)
        }.sorted { first, second in
            sessionClosureIdentity(first).utf8.lexicographicallyPrecedes(
                sessionClosureIdentity(second).utf8
            )
        }
    }

    func sessionBelongsToClosingRoot(_ session: DocumentSession) -> Bool {
        guard let authority = workspaceSearchRootAuthority else {
            if session === shownSession { return true }
            return editorBindingInstallations.contains { installation, owner in
                owner === session && registry.editorInstallationWindows[installation]?.window === windowState
            }
        }
        if let location = retainedManagedSessionLocation(for: session),
           location.rootAuthority == authority
        {
            return true
        }
        if case let .proven(proof)? = unanchoredManagedSessionOwnershipProofs[ObjectIdentifier(session)],
           proof.installedWorkspaceLocation?.rootAuthority == authority
        {
            return true
        }
        return false
    }

    /// The closing window's own document still releases with its root. Another window's
    /// shown session, or a live installation that window holds, stays out of the set.
    func isPreservedForAnotherWindow(_ session: DocumentSession) -> Bool {
        if registry.connectedWindows.contains(where: { window in
            window !== windowState && window.shownSession === session
        }) {
            return true
        }
        return editorBindingInstallations.contains { installation, owner in
            guard owner === session,
                  let window = registry.editorInstallationWindows[installation]?.window,
                  window !== windowState
            else { return false }
            return registry.connectedWindows.contains { $0 === window }
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
        retirementPlans: [EditorDocumentRetirementPlan],
        preserving preservedSessions: [DocumentSession]
    ) {
        _ = advanceWorkspaceGeneration()
        workspaceReloadTask?.cancel()
        workspaceReloadTask = nil
        completionWorkspaceTask?.cancel()
        completionWorkspaceTask = nil
        workspaceWatcher?.stop()
        workspaceWatcher = nil
        transferWorkspaceAuthority(to: retirementPlans, preserving: preservedSessions)
        clearClosedWorkspaceState(
            sessions: sessions,
            retirementPlans: retirementPlans
        )
    }

    func transferWorkspaceAuthority(
        to retirementPlans: [EditorDocumentRetirementPlan],
        preserving preservedSessions: [DocumentSession]
    ) {
        let activeAuthority = workspaceAccess
        workspaceAccess = nil
        let authorityOwner = activeAuthority.map(RetiredWorkspaceAuthorityOwner.init(authority:))

        if let authorityOwner {
            for session in preservedSessions {
                retainWorkspaceAuthority(authorityOwner, for: session)
            }
        }
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
        workspaceSearchRefreshIntent = nil
        completionWorkspace = .empty
        completionWorkspaceBaseCache = nil
        // Close/switch clears query chrome and mode; Files/Search mode flip does not.
        resetWorkspaceSearchUIState()
        notifyEditorFindWorkspaceDidClose()

        let retainedSessionIdentities = Set(retiredEditorDocumentSessions.values.map {
            ObjectIdentifier($0.session)
        })
        var proofRetainedSessionIdentities = retainedSessionIdentities
        for session in registry.sessions(from: [.fileBackedWindowDocuments]) {
            proofRetainedSessionIdentities.insert(ObjectIdentifier(session))
        }
        if !retainedSessionIdentities.contains(ObjectIdentifier(shownSession)) {
            autosaveTask?.cancel()
            autosaveTask = nil
            statisticsTask?.cancel()
            statisticsTask = nil
        }
        for session in sessions where !retainedSessionIdentities.contains(ObjectIdentifier(session)) {
            let sessionIdentity = ObjectIdentifier(session)
            sessionAutosaveTasks.removeValue(forKey: sessionIdentity)?.task.cancel()
            sessionStatisticsTasks.removeValue(forKey: sessionIdentity)?.task.cancel()
            removeEditorDocumentBindingRegistration(for: session)
        }
        for session in sessions {
            guard let url = sessionStateURL(for: session) else { continue }
            registry.setWarmSession(nil, at: url)
            sessionPolicy.remove(url)
        }
        for session in sessions
            where !proofRetainedSessionIdentities.contains(ObjectIdentifier(session))
        {
            let sessionIdentity = ObjectIdentifier(session)
            anchoredSessionFileBindings[sessionIdentity] = nil
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] = nil
            discardEditorImageAssetDocumentAuthority(for: session)
            indeterminateSessionWrites[sessionIdentity] = nil
            indeterminateSessionWriteContexts[sessionIdentity] = nil
        }
        pruneMetadataAfterRootRelease(releasing: sessions)
        externalChangePrompt = nil
        missingFilePrompt = nil
        indeterminateFileWriteReconciliationPrompt = nil
        restoreRecoveryPrompt(for: shownSession)
        if indeterminateSessionWrites[ObjectIdentifier(shownSession)] != nil {
            refreshIndeterminateFileWriteReconciliation(for: shownSession)
        }

        for plan in retirementPlans {
            finishRetiredEditorDocumentSessionIfPossible(for: plan.session)
        }
    }

    /// Drops metadata for sessions this root released. Sessions outside the release set
    /// keep fences, bindings, proofs, quarantine, detached URLs, and external versions,
    /// including other roots and standalone warm sessions.
    func pruneMetadataAfterRootRelease(releasing releasedSessions: [DocumentSession]) {
        let releasedIdentities = Set(releasedSessions.map(ObjectIdentifier.init))
        var retainedSessions = registry.sessions(from: [
            .warmCache, .retired, .editorBindings, .editorInstallations,
            .mutationRecovery, .fileBackedWindowDocuments,
        ]).filter { !releasedIdentities.contains(ObjectIdentifier($0)) }
        retainedSessions.append(contentsOf: registry.sessions(from: [
            .retired, .mutationRecovery, .fileBackedWindowDocuments,
        ]))
        retainedSessions.append(contentsOf: registry.sessions(from: [
            .warmCache, .editorBindings, .editorInstallations, .mutationRecovery,
        ]).filter { session in
            indeterminateWorkspaceMutationSessions.contains(ObjectIdentifier(session))
        })
        var seen: Set<ObjectIdentifier> = []
        retainedSessions = retainedSessions.filter { seen.insert(ObjectIdentifier($0)).inserted }
        let retainedURLs = Set(retainedSessions.compactMap(sessionStateURL(for:)))
        let retainedSessionIdentities = Set(retainedSessions.map(ObjectIdentifier.init))
        pendingExternalTexts = pendingExternalTexts.filter { retainedURLs.contains($0.key) }
        pendingExternalFileVersions = pendingExternalFileVersions.filter {
            retainedURLs.contains($0.key)
        }
        deferredExternalChangeResolutions = deferredExternalChangeResolutions.filter {
            retainedURLs.contains($0.key)
        }
        externalResolutionIntentCaptures = externalResolutionIntentCaptures.filter {
            retainedURLs.contains($0.key)
        }
        lastKnownDiskHashes = lastKnownDiskHashes.filter { retainedURLs.contains($0.key) }
        lastKnownDiskModificationDates = lastKnownDiskModificationDates.filter {
            retainedURLs.contains($0.key)
        }
        detachedSessionURLs = Set(detachedSessionURLs.filter(retainedURLs.contains))
        anchoredSessionFileBindings = anchoredSessionFileBindings.filter {
            retainedSessionIdentities.contains($0.key)
        }
        unanchoredManagedSessionOwnershipProofs = unanchoredManagedSessionOwnershipProofs.filter {
            retainedSessionIdentities.contains($0.key)
        }
        editorImageAssetDocumentAuthorities = editorImageAssetDocumentAuthorities.filter {
            retainedSessionIdentities.contains($0.key)
        }
        indeterminateSessionWrites = indeterminateSessionWrites.filter {
            retainedSessionIdentities.contains($0.key)
        }
        indeterminateSessionWriteContexts = indeterminateSessionWriteContexts.filter {
            retainedSessionIdentities.contains($0.key)
        }
        indeterminateWorkspaceMutationSessions = Set(
            indeterminateWorkspaceMutationSessions.filter(retainedSessionIdentities.contains)
        )
    }
}

private struct EditorDocumentRetirementPlan {
    let canonicalURL: URL
    let session: DocumentSession
    let installations: Set<EditorDocumentBindingInstallation>
    let requiresWorkspaceAuthority: Bool
}
