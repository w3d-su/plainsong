import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    func canonicalSessionURL(for url: URL) throws -> URL {
        // Standalone sessions establish their descriptor-bound parent authority in
        // `activateFileSession`. Do not normalize the panel URL first:
        // `standardizedFileURL` silently decomposes NFC path components to NFD before that
        // capture can preserve the literal leaf spelling.
        guard workspaceRootURL != nil else {
            return url
        }
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        if let workspaceRootURL {
            _ = try WorkspaceRootContainment.relativePath(
                for: resolvedURL,
                rootURL: workspaceRootURL
            )
        }
        return resolvedURL
    }

    func synchronizeWorkspaceTreeSelection(for session: DocumentSession) {
        guard let rootAuthority = workspaceSearchRootAuthority,
              workspaceInstalledCaptureGeneration == workspaceGeneration,
              let location = retainedManagedSessionLocation(for: session),
              location.rootAuthority == rootAuthority,
              var tree = workspaceTree,
              let node = firstNode(
                  in: tree.root,
                  canonicalRelativePath: location.relativePath,
                  rootURL: rootAuthority.originalRootURL
              )
        else {
            return
        }

        tree.selectNode(id: node.id)
        workspaceTree = tree
    }

    func beginEditorDocumentSessionRetirement(
        canonicalURL: URL,
        session: DocumentSession,
        installations: Set<EditorDocumentBindingInstallation>,
        securityScopedAuthorityOwner: RetiredWorkspaceAuthorityOwner?
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        let shouldRestartDiskInspection = externalDiskInspectionTasks[sessionIdentity] != nil
        let bindingIDs = Set(installations.map(\.bindingID))
        var retirement: RetiredEditorDocumentSession
        if let existing = retiredEditorDocumentSessions[canonicalURL] {
            guard existing.session === session else {
                preconditionFailure("Duplicate active/retired session ownership for \(canonicalURL.path)")
            }
            retirement = existing
            retirement.bindingIDs.formUnion(bindingIDs)
            retirement.awaitingInstallations.formUnion(installations)
        } else {
            retirement = RetiredEditorDocumentSession(
                canonicalURL: canonicalURL,
                session: session,
                bindingIDs: bindingIDs,
                awaitingInstallations: installations,
                securityScopedAuthorityOwners: []
            )
        }

        if let securityScopedAuthorityOwner,
           !retirement.securityScopedAuthorityOwners.contains(where: {
               $0 === securityScopedAuthorityOwner
           })
        {
            securityScopedAuthorityOwner.retain(session)
            retirement.securityScopedAuthorityOwners.append(securityScopedAuthorityOwner)
        }
        retiredEditorDocumentSessions[canonicalURL] = retirement
        _ = advanceSessionLifecycle(for: session)
        if shouldRestartDiskInspection || deferredExternalChangeResolutions[canonicalURL] != nil {
            handleExternalChange(for: session, advancingDiskEvent: false)
        }
        moveCurrentAutosaveToBackground(for: session)
        moveCurrentStatisticsToBackground(for: session)
    }

    func retiredEditorDocumentSession(
        for canonicalURL: URL
    ) -> RetiredEditorDocumentSession? {
        retiredEditorDocumentSessions[canonicalURL]
    }

    func validateCanonicalSessionOwnership(
        at canonicalURL: URL,
        cachedSession: DocumentSession?
    ) throws {
        guard let retirement = retiredEditorDocumentSessions[canonicalURL] else { return }
        if let cachedSession, cachedSession !== retirement.session {
            assertionFailure("Duplicate active and retired sessions share one physical URL")
            throw AppStateError.duplicateSessionOwnership(canonicalURL)
        }
        if sessionStateURL(for: currentDocument).map({
            exactFileURLSpellingMatches($0, canonicalURL)
        }) == true,
            currentDocument !== retirement.session
        {
            assertionFailure("Current and retired sessions share one physical URL")
            throw AppStateError.duplicateSessionOwnership(canonicalURL)
        }
    }

    func discardRetiredEditorDocumentSession(
        _ session: DocumentSession,
        canonicalURL: URL
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        guard !indeterminateWorkspaceMutationSessions.contains(sessionIdentity) else {
            cancelAutosave(for: session)
            return
        }
        if let retirement = retiredEditorDocumentSessions[canonicalURL],
           retirement.session === session
        {
            retiredEditorDocumentSessions[canonicalURL] = nil
            for owner in retirement.securityScopedAuthorityOwners {
                owner.release(session)
            }
        }

        let discardedInstallations = Set(editorBindingInstallations.compactMap { installation, owner in
            owner === session ? installation : nil
        })
        for installation in discardedInstallations {
            pendingEditorSourceInstallations[installation] = nil
            editorBindingInstallations[installation] = nil
        }
        editorWriterInstallations[sessionIdentity] = nil
        externalDiskInspectionTasks.removeValue(forKey: sessionIdentity)?.task.cancel()
        externalReloadTasks.removeValue(forKey: sessionIdentity)?.task.cancel()
        pendingExternalReloadApplications[sessionIdentity] = nil
        deferredExternalChangeResolutions[canonicalURL] = nil
        externalResolutionIntentCaptures[canonicalURL] = nil
        clearExternalChangeConflict(at: canonicalURL)
        detachedSessionURLs.remove(canonicalURL)
        anchoredSessionFileBindings[sessionIdentity] = nil
        unanchoredManagedSessionOwnershipProofs[sessionIdentity] = nil
        discardEditorImageAssetDocumentAuthority(for: session)
        indeterminateSessionWrites[sessionIdentity] = nil
        indeterminateSessionWriteContexts[sessionIdentity] = nil
        indeterminateWorkspaceMutationSessions.remove(sessionIdentity)
        removeEditorDocumentBindingRegistration(for: session)
    }

    func firstUnretirableExternalConflict(
        excluding retiredSessions: Set<ObjectIdentifier>
    ) -> URL? {
        var sessions = Array(sessionCache.values)
        if currentDocument.fileURL != nil {
            sessions.append(currentDocument)
        }
        var seen: Set<ObjectIdentifier> = []
        return sessions
            .filter { session in
                let identity = ObjectIdentifier(session)
                return !retiredSessions.contains(identity) && seen.insert(identity).inserted
            }
            .compactMap { session -> URL? in
                guard session.isDirty,
                      let url = sessionStateURL(for: session),
                      pendingExternalTexts[url] != nil || pendingExternalFileVersions[url] != nil
                else {
                    return nil
                }
                return url
            }
            .sorted { $0.absoluteString < $1.absoluteString }
            .first
    }

    func cancelWorkspaceSessionTasks(excluding retainedSessions: Set<ObjectIdentifier>) {
        var retainedIdentities = retainedSessions
        retainedIdentities.formUnion(retiredEditorDocumentSessions.values.map {
            ObjectIdentifier($0.session)
        })

        let autosaveIdentities = sessionAutosaveTasks.keys.filter {
            !retainedIdentities.contains($0)
        }
        for identity in autosaveIdentities {
            sessionAutosaveTasks.removeValue(forKey: identity)?.task.cancel()
        }

        let statisticsIdentities = sessionStatisticsTasks.keys.filter {
            !retainedIdentities.contains($0)
        }
        for identity in statisticsIdentities {
            sessionStatisticsTasks.removeValue(forKey: identity)?.task.cancel()
        }
    }

    func recoverRetiredSession(
        for canonicalURL: URL,
        matching candidateLocation: WorkspaceFileSystemLocation
    ) -> DocumentSession? {
        let matches = retiredEditorDocumentSessions.compactMap { key, retirement in
            if retainedManagedSessionLocation(for: retirement.session) == candidateLocation,
               let retiredURL = sessionStateURL(for: retirement.session),
               exactFileURLSpellingMatches(retiredURL, canonicalURL)
            {
                return (key, retirement)
            }
            return nil
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        // #85 releases a fully ended standalone retirement at activation. WS3B's
        // multi-window extension keeps the record only while exact installations
        // are still live, so their late commits and revocations remain authorized.
        if match.1.awaitingInstallations.isEmpty {
            retiredEditorDocumentSessions[match.0] = nil
            for owner in match.1.securityScopedAuthorityOwners {
                owner.release(match.1.session)
            }
        }
        return match.1.session
    }

    /// `pendingExternal*` and `detachedSessionURLs` intentionally use the exact retained URL
    /// spelling as their App-state key. Before another session can use that same lexical key,
    /// prove that any stateful owner has the same retained authority; a replacement parent B
    /// must never inherit or clear A's conflict/detachment/quarantine state merely because the
    /// pathname is identical.
    func hasStatefulRetainedAuthorityCollision(
        at canonicalURL: URL,
        candidateLocation: WorkspaceFileSystemLocation,
        excludingRecoveryID: UUID? = nil
    ) -> Bool {
        if isWorkspaceMutationRecoveryCandidate(
            candidateLocation,
            excludingRecoveryID: excludingRecoveryID
        ) {
            return true
        }
        let hasURLKeyedState = pendingExternalTexts[canonicalURL] != nil
            || pendingExternalFileVersions[canonicalURL] != nil
            || detachedSessionURLs.contains(canonicalURL)
        var sessions = Array(sessionCache.values)
        sessions.append(contentsOf: retiredEditorDocumentSessions.values.map(\.session))
        sessions.append(contentsOf: editorDocumentBindingSessions.values)
        sessions.append(contentsOf: editorBindingInstallations.values)
        sessions.append(contentsOf: workspaceMutationRetainedRecoverySessions())
        if currentDocument.fileURL != nil {
            sessions.append(currentDocument)
        }

        var seen: Set<ObjectIdentifier> = []
        var foundURLKeyedStateOwner = false
        for session in sessions where seen.insert(ObjectIdentifier(session)).inserted {
            let sessionIdentity = ObjectIdentifier(session)
            guard let stateURL = sessionStateURL(for: session),
                  exactFileURLSpellingMatches(stateURL, canonicalURL)
            else {
                continue
            }
            if hasURLKeyedState {
                foundURLKeyedStateOwner = true
            }
            let hasSessionState = hasURLKeyedState
                || indeterminateSessionWrites[sessionIdentity] != nil
                || indeterminateSessionWriteContexts[sessionIdentity] != nil
                || indeterminateWorkspaceMutationSessions.contains(sessionIdentity)
            guard hasSessionState else { continue }

            if indeterminateWorkspaceMutationSessions.contains(sessionIdentity) {
                return true
            }

            guard let retainedLocation = retainedManagedSessionLocation(for: session) else {
                // An unavailable proof cannot establish that B is distinct from the stateful A.
                return true
            }
            if retainedLocation != candidateLocation {
                return true
            }
        }
        // A URL-keyed fence with no retained owner is itself unprovable authority state; do not
        // let a new capture consume it just because no mutable session URL happened to match.
        return hasURLKeyedState && !foundURLKeyedStateOwner
    }

    /// The only authority location eligible to identify an already-managed session. This never
    /// reconstructs a location from the mutable display URL: a cache/retirement hit without a
    /// retained proof must fail closed rather than bind a replacement namespace.
    func retainedManagedSessionLocation(
        for session: DocumentSession
    ) -> WorkspaceFileSystemLocation? {
        if let location = retainedAnchoredSessionLocation(for: session) {
            return location
        }
        if case let .proven(proof)? = unanchoredManagedSessionOwnershipProofs[
            ObjectIdentifier(session)
        ] {
            return proof.location
        }
        return nil
    }

    func hasConflictingPhysicalSessionOwnership(
        _ expectedIdentity: WorkspaceFileSystemIdentity,
        excluding candidateSession: DocumentSession
    ) -> Bool {
        var sessions = Array(sessionCache.values)
        sessions.append(contentsOf: retiredEditorDocumentSessions.values.map(\.session))
        sessions.append(contentsOf: editorDocumentBindingSessions.values)
        sessions.append(contentsOf: editorBindingInstallations.values)
        if currentDocument.fileURL != nil {
            sessions.append(currentDocument)
        }

        var seen: Set<ObjectIdentifier> = []
        for session in sessions where session !== candidateSession {
            let sessionIdentity = ObjectIdentifier(session)
            guard seen.insert(sessionIdentity).inserted else { continue }
            if anchoredSessionFileBindings[sessionIdentity]?.identity == expectedIdentity {
                return true
            }
            if case let .proven(proof)? =
                unanchoredManagedSessionOwnershipProofs[sessionIdentity],
                proof.identity == expectedIdentity
            {
                return true
            }
        }
        return false
    }

    func retainMetadataOnlyForRetiredEditorSessions() {
        var retainedSessions = retiredEditorDocumentSessions.values.map(\.session)
        retainedSessions.append(contentsOf: workspaceMutationRetainedRecoverySessions())
        if currentDocument.fileURL != nil {
            retainedSessions.append(currentDocument)
        }
        var managedSessions = Array(sessionCache.values)
        managedSessions.append(contentsOf: editorDocumentBindingSessions.values)
        managedSessions.append(contentsOf: editorBindingInstallations.values)
        managedSessions.append(contentsOf: workspaceMutationRetainedRecoverySessions())
        var seenManagedSessionIdentities = Set<ObjectIdentifier>()
        retainedSessions.append(contentsOf: managedSessions.filter { session in
            let identity = ObjectIdentifier(session)
            return seenManagedSessionIdentities.insert(identity).inserted
                && indeterminateWorkspaceMutationSessions.contains(identity)
        })
        let retainedURLs = Set(retainedSessions.compactMap(sessionStateURL(for:)))
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
        let retainedSessionIdentities = Set(retainedSessions.map(ObjectIdentifier.init))
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

    func handleSessionEvictions(_ evictions: [WorkspaceSessionEviction]) {
        for eviction in evictions {
            guard let session = sessionCache[eviction.url] else { continue }
            finishSessionEviction(eviction, session: session)
        }
    }

    func reconcileSessionPolicyAfterEditorLeaseChange() {
        handleSessionEvictions(sessionPolicy.trim(protectedURLs: protectedSessionURLs()))
    }

    func protectedSessionURLs() -> Set<URL> {
        var urls = Set(retiredEditorDocumentSessions.keys)
        if let currentURL = sessionStateURL(for: currentDocument) {
            urls.insert(currentURL)
        }
        for session in editorBindingInstallations.values {
            if let installedURL = sessionStateURL(for: session) {
                urls.insert(installedURL)
            }
        }
        for (sessionIdentity, context) in indeterminateSessionWriteContexts
            where indeterminateSessionWrites[sessionIdentity] != nil
        {
            urls.insert(context.location.fileURL)
        }
        var managedSessions = Array(sessionCache.values)
        managedSessions.append(contentsOf: retiredEditorDocumentSessions.values.map(\.session))
        managedSessions.append(contentsOf: editorDocumentBindingSessions.values)
        managedSessions.append(contentsOf: editorBindingInstallations.values)
        if currentDocument.fileURL != nil {
            managedSessions.append(currentDocument)
        }
        var seenSessionIdentities = Set<ObjectIdentifier>()
        for session in managedSessions {
            let identity = ObjectIdentifier(session)
            guard seenSessionIdentities.insert(identity).inserted,
                  indeterminateWorkspaceMutationSessions.contains(identity)
                  || workspaceMutationWriteFences.contains(identity),
                  let stateURL = sessionStateURL(for: session)
            else {
                continue
            }
            urls.insert(stateURL)
        }
        return urls
    }

    func nodeForCurrentDocument(in tree: WorkspaceFileTree) -> WorkspaceFileNode? {
        guard let location = retainedManagedSessionLocation(for: currentDocument),
              let authority = workspaceSearchRootAuthority,
              workspaceInstalledCaptureGeneration == workspaceGeneration,
              location.rootAuthority == authority
        else {
            return nil
        }
        return firstNode(
            in: tree.root,
            canonicalRelativePath: location.relativePath,
            rootURL: authority.originalRootURL
        )
    }

    func firstNode(
        in node: WorkspaceFileNode,
        canonicalRelativePath: String,
        rootURL: URL
    ) -> WorkspaceFileNode? {
        if let exactNode = firstNode(in: node, relativePath: canonicalRelativePath) {
            return exactNode
        }
        return firstNodeResolvingAlias(
            in: node,
            canonicalRelativePath: canonicalRelativePath,
            rootURL: rootURL
        )
    }

    func firstNode(in node: WorkspaceFileNode, relativePath: String) -> WorkspaceFileNode? {
        if ExactSourceText.matches(node.relativePath, relativePath) {
            return node
        }

        for child in node.children {
            if let match = firstNode(in: child, relativePath: relativePath) {
                return match
            }
        }
        return nil
    }
}

@MainActor
private extension AppState {
    func finishSessionEviction(
        _ eviction: WorkspaceSessionEviction,
        session: DocumentSession
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        if indeterminateSessionWrites[sessionIdentity] != nil ||
            indeterminateWorkspaceMutationSessions.contains(sessionIdentity) ||
            workspaceMutationWriteFences.contains(sessionIdentity)
        {
            _ = sessionPolicy.access(
                eviction.url,
                isDirty: session.isDirty,
                protectedURLs: protectedSessionURLs().union([eviction.url])
            )
            return
        }
        if eviction.requiresSave {
            do {
                try save(session: session)
            } catch {
                present(error, title: "Could Not Save Warm File")
                var protectedURLs = protectedSessionURLs()
                protectedURLs.insert(eviction.url)
                handleSessionEvictions(sessionPolicy.access(
                    eviction.url,
                    isDirty: session.isDirty,
                    protectedURLs: protectedURLs
                ))
                return
            }
        }
        cancelAutosave(for: session)
        anchoredSessionFileBindings[sessionIdentity] = nil
        unanchoredManagedSessionOwnershipProofs[sessionIdentity] = nil
        discardEditorImageAssetDocumentAuthority(for: session)
        indeterminateSessionWrites[sessionIdentity] = nil
        indeterminateSessionWriteContexts[sessionIdentity] = nil
        indeterminateWorkspaceMutationSessions.remove(sessionIdentity)
        sessionCache[eviction.url] = nil
        if !isRetiredEditorSession(session) {
            removeEditorDocumentBindingRegistration(for: session)
        }
    }

    func firstNodeResolvingAlias(
        in node: WorkspaceFileNode,
        canonicalRelativePath: String,
        rootURL: URL
    ) -> WorkspaceFileNode? {
        if node.isEditableMarkdown,
           let nodeURL = try? WorkspaceRootContainment.containedURL(
               rootURL: rootURL,
               relativePath: node.relativePath
           ),
           let nodePath = try? WorkspaceRootContainment.relativePath(
               for: nodeURL,
               rootURL: rootURL
           ),
           ExactSourceText.matches(nodePath, canonicalRelativePath)
        {
            return node
        }

        for child in node.children {
            if let match = firstNodeResolvingAlias(
                in: child,
                canonicalRelativePath: canonicalRelativePath,
                rootURL: rootURL
            ) {
                return match
            }
        }
        return nil
    }
}
