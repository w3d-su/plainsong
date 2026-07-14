import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    func canonicalSessionURL(for url: URL) throws -> URL {
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
        guard let rootURL = workspaceRootURL,
              let fileURL = session.fileURL,
              let relativePath = try? WorkspaceRootContainment.relativePath(
                  for: fileURL,
                  rootURL: rootURL
              ),
              var tree = workspaceTree,
              let node = firstNode(
                  in: tree.root,
                  canonicalRelativePath: relativePath,
                  rootURL: rootURL
              )
        else {
            return
        }

        tree.selectNode(id: node.id)
        workspaceTree = tree
    }

    func editorDocumentBindingLeaseEligibleForRetirement() -> InstalledEditorDocumentBindingLease? {
        guard let lease = installedEditorDocumentBindingLease,
              editorDocumentBindingIDs[ObjectIdentifier(lease.session)] == lease.id,
              editorDocumentBindingSessions[lease.id] === lease.session
        else {
            return nil
        }

        if lease.session === currentDocument {
            return lease
        }
        guard let fileURL = sessionStateURL(for: lease.session),
              sessionCache[fileURL] === lease.session
        else {
            return nil
        }
        return lease
    }

    func beginEditorDocumentBindingRetirement(
        _ lease: InstalledEditorDocumentBindingLease,
        securityScopedAuthority: SecurityScopedResourceAccess?
    ) {
        if let existing = retiredEditorDocumentBindings[lease.id],
           existing.session === lease.session
        {
            if let existingAuthority = existing.securityScopedAuthority {
                if let securityScopedAuthority,
                   securityScopedAuthority !== existingAuthority
                {
                    securityScopedAuthority.stop()
                }
            } else if let securityScopedAuthority {
                retiredEditorDocumentBindings[lease.id] = RetiredEditorDocumentBinding(
                    id: existing.id,
                    session: existing.session,
                    securityScopedAuthority: securityScopedAuthority,
                    isAwaitingBindingEnd: existing.isAwaitingBindingEnd
                )
            }
            moveCurrentAutosaveToBackground(for: lease.session)
            moveCurrentStatisticsToBackground(for: lease.session)
            return
        }

        retiredEditorDocumentBindings[lease.id] = RetiredEditorDocumentBinding(
            id: lease.id,
            session: lease.session,
            securityScopedAuthority: securityScopedAuthority,
            isAwaitingBindingEnd: true
        )
        moveCurrentAutosaveToBackground(for: lease.session)
        moveCurrentStatisticsToBackground(for: lease.session)
    }

    func firstUnretirableExternalConflict(
        excluding retiredSession: DocumentSession?
    ) -> URL? {
        var sessions = Array(sessionCache.values)
        if currentDocument.fileURL != nil {
            sessions.append(currentDocument)
        }
        var seen: Set<ObjectIdentifier> = []
        return sessions
            .filter { session in
                session !== retiredSession && seen.insert(ObjectIdentifier(session)).inserted
            }
            .compactMap { session -> URL? in
                guard session.isDirty,
                      let url = sessionStateURL(for: session),
                      pendingExternalTexts[url] != nil
                else {
                    return nil
                }
                return url
            }
            .sorted { $0.absoluteString < $1.absoluteString }
            .first
    }

    func recoverRetiredSession(for canonicalURL: URL) -> DocumentSession? {
        var matches: [(EditorDocumentBindingID, RetiredEditorDocumentBinding)] = []
        for (bindingID, retirement) in retiredEditorDocumentBindings {
            if !retirement.isAwaitingBindingEnd,
               let retiredURL = sessionStateURL(for: retirement.session),
               exactFileURLSpellingMatches(retiredURL, canonicalURL)
            {
                matches.append((bindingID, retirement))
            }
        }
        guard matches.count == 1, let match = matches.first else { return nil }

        retiredEditorDocumentBindings[match.0] = nil
        match.1.securityScopedAuthority?.stop()
        return match.1.session
    }

    func cancelWorkspaceSessionTasks(except retainedSession: DocumentSession?) {
        let retainedIdentity = retainedSession.map(ObjectIdentifier.init)
        for (identity, task) in sessionAutosaveTasks {
            guard retainedIdentity != identity else { continue }
            task.task.cancel()
        }
        if let retainedIdentity {
            sessionAutosaveTasks = sessionAutosaveTasks.filter { $0.key == retainedIdentity }
        } else {
            sessionAutosaveTasks.removeAll()
        }
        for (identity, task) in sessionStatisticsTasks {
            guard retainedIdentity != identity else { continue }
            task.task.cancel()
        }
        if let retainedIdentity {
            sessionStatisticsTasks = sessionStatisticsTasks.filter { $0.key == retainedIdentity }
        } else {
            sessionStatisticsTasks.removeAll()
        }
    }

    func retainMetadataOnlyForRetiredEditorSessions() {
        var retainedSessions = retiredEditorDocumentBindings.values.map(\.session)
        if currentDocument.fileURL != nil {
            retainedSessions.append(currentDocument)
        }
        let retainedURLs = Set(retainedSessions.compactMap(sessionStateURL(for:)))
        pendingExternalTexts = pendingExternalTexts.filter { retainedURLs.contains($0.key) }
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
        indeterminateSessionWrites = indeterminateSessionWrites.filter {
            retainedSessionIdentities.contains($0.key)
        }
        indeterminateSessionWriteContexts = indeterminateSessionWriteContexts.filter {
            retainedSessionIdentities.contains($0.key)
        }
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
        var urls: Set<URL> = []
        if let currentURL = sessionStateURL(for: currentDocument) {
            urls.insert(currentURL)
        }
        if let installedSession = installedEditorDocumentBindingLease?.session,
           let installedURL = sessionStateURL(for: installedSession)
        {
            urls.insert(installedURL)
        }
        for (sessionIdentity, context) in indeterminateSessionWriteContexts
            where indeterminateSessionWrites[sessionIdentity] != nil
        {
            urls.insert(context.location.fileURL)
        }
        return urls
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

    private func finishSessionEviction(
        _ eviction: WorkspaceSessionEviction,
        session: DocumentSession
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        if indeterminateSessionWrites[sessionIdentity] != nil {
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
        indeterminateSessionWrites[sessionIdentity] = nil
        indeterminateSessionWriteContexts[sessionIdentity] = nil
        sessionCache[eviction.url] = nil
        removeEditorDocumentBindingRegistration(for: session)
    }

    private func firstNodeResolvingAlias(
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
