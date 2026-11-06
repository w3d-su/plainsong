import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

extension AppState {
    func openWorkspace(url: URL, rememberAsLastOpened: Bool) throws {
        try refuseWindowFileOpenIfNeeded()
        if let shared = matchingWorkspaceRoot(for: url) {
            if shared === workspaceRootContext, workspaceRootURL != nil {
                rememberWorkspaceIfNeeded(url, remember: rememberAsLastOpened)
                return
            }
            guard let rootAuthority = shared.registrationAuthority else {
                throw CocoaError(.fileNoSuchFile)
            }
            try validateWorkspaceRootInstallation(url: url, sharing: shared)
            try closeWorkspaceForReplacement()
            workspaceRootContext = shared
            connectWorkspaceRootContext()
            let root = rootAuthority.originalRootURL
            workspaceRootURL = root
            shared.attach(self)
            installSharedWorkspaceTreeIfReady()
            rememberWorkspaceIfNeeded(url, remember: rememberAsLastOpened)
            return
        }

        // Preflight before retiring the outgoing workspace or starting the new scope.
        try validateWorkspaceRootInstallation(url: url, sharing: nil)
        let access = registry.workspaceScopeStarter(url)
        let authority: WorkspaceFileSystemRootAuthority
        do {
            authority = try WorkspaceFileSystemRootAuthority(rootURL: url)
            try validateWorkspaceRootInstallation(url: authority.canonicalRootURL, sharing: nil)
            try closeWorkspaceForReplacement()
        } catch {
            access.stop()
            throw error
        }
        let context = workspaceRootContext
        context.registrationAuthority = authority
        registry.workspaceRoots[authority] = WorkspaceRootReference(context: context)
        workspaceAccess = access
        workspaceRootURL = url
        context.attach(self)
        workspaceTree = WorkspaceFileTree(
            root: WorkspaceFileNode(
                id: "__workspace_root__",
                name: url.lastPathComponent,
                relativePath: "",
                kind: .directory,
                contentModificationDate: nil
            )
        )
        rememberWorkspaceIfNeeded(url, remember: rememberAsLastOpened)
        startSharedWorkspaceWatcher(root: url)
        scheduleWorkspaceReload(
            root: url,
            selectFirstIfNeeded: true,
            errorTitle: "Could Not Open Workspace"
        )
    }

    private func rememberWorkspaceIfNeeded(_ root: URL, remember: Bool) {
        guard remember else { return }
        rememberLastOpenedFile(root)
        rememberRecentItem(root)
    }

    func activateFileSession(url: URL) throws {
        let requestedURL = try canonicalSessionURL(for: url)
        // The candidate location is only a cache discriminator. A cached or retired session
        // must match it through its existing retained authority; its new authority/metadata is
        // never adopted from this capture before external-change arbitration.
        let location = try WorkspaceFileSystemLocation(fileURL: requestedURL)
        let key = location.fileURL
        // URL-keyed prompt/detachment state is only safe while it belongs to the same retained
        // authority. Do not let a replacement parent B install at A's lexical spelling and
        // inherit, clear, or overwrite a still-stateful retired/current A session.
        guard !hasStatefulRetainedAuthorityCollision(
            at: key,
            candidateLocation: location
        ) else {
            throw AppStateError.invalidSessionIdentity(key)
        }
        if let cachedSession = registry.warmSession(at: key) {
            guard retainedManagedSessionLocation(for: cachedSession) == location else {
                throw AppStateError.invalidSessionIdentity(key)
            }
            guard let cachedURL = sessionStateURL(for: cachedSession),
                  exactFileURLSpellingMatches(cachedURL, key)
            else {
                throw AppStateError.invalidSessionIdentity(key)
            }
            if cachedSession === shownSession {
                synchronizeWorkspaceTreeSelection(for: cachedSession)
                handleSessionAccess(url: key, isDirty: cachedSession.isDirty)
                return
            }
            moveCurrentDocumentWorkToBackgroundBeforeSwitch()
            setCurrentDocument(cachedSession)
            handleExternalChange(for: cachedSession, advancingDiskEvent: false)
            handleSessionAccess(url: key, isDirty: cachedSession.isDirty)
            return
        }

        if let retiredSession = recoverRetiredSession(
            for: key,
            matching: location
        ) {
            activateRetiredFileSession(retiredSession, canonicalURL: key)
            return
        }

        let loadLocation = if let installedAuthority = workspaceSearchRootAuthority,
                              workspaceInstalledCaptureGeneration == workspaceGeneration,
                              let installedLocation = try? installedAuthority.canonicalizedLocation(
                                  forFileURL: requestedURL
                              )
        {
            installedLocation
        } else {
            location
        }
        let preparedRead = try prepareEditorImageAssetDocumentRead(
            fileStore: fileStore,
            at: loadLocation
        )
        let loaded = preparedRead.result
        let file = loaded.file
        let session = DocumentSession(
            text: file.text,
            url: file.url,
            fileKind: file.fileKind,
            isDirty: false
        )
        moveCurrentDocumentWorkToBackgroundBeforeSwitch()
        retainUnanchoredManagedSessionOwnership(
            for: session,
            location: loadLocation,
            identity: loaded.metadata.identity,
            sha256Digest: loaded.sha256Digest,
            preparedImageAssetAuthority: preparedRead.preparedAuthority
        )
        registry.setWarmSession(session, at: key)
        detachedSessionURLs.remove(key)
        if let prompt = missingFilePrompt,
           exactFileURLSpellingMatches(prompt.fileURL, key)
        {
            missingFilePrompt = nil
        }
        recordKnownDiskText(file.text, for: key)
        setCurrentDocument(session)
        handleSessionAccess(url: key, isDirty: session.isDirty)
    }

    func setCurrentDocument(
        _ session: DocumentSession,
        synchronizingWorkspaceTree: Bool = true,
        requestingEditorFocus: Bool = WorkspaceSelectionFocus.requestsEditorFocus
    ) {
        guard shownSession !== session else { return }
        let previousSession = shownSession
        moveCurrentDocumentWorkToBackgroundBeforeSwitch()
        if requestingEditorFocus {
            requestEditorFocus()
        }
        if synchronizingWorkspaceTree {
            synchronizeWorkspaceTreeSelection(for: session)
        }
        cancelPendingEditorNavigationIfNeeded()
        transferEditorWriterForAdoption(of: session)
        shownSession = session
        releaseUnreferencedSessionOwnership(for: previousSession)
        refreshWorkspaceWatcherEventFilter()
        clearPromptsNotMatchingCurrentDocument()
        restoreRecoveryPrompt(for: session)
        if indeterminateSessionWrites[ObjectIdentifier(session)] != nil {
            refreshIndeterminateFileWriteReconciliation(for: session)
        }
        observeCurrentDocument()
        scheduleCompletionWorkspaceRefresh()
        notifyEditorFindDocumentDidSwitch()
    }

    func handleSessionAccess(url: URL, isDirty: Bool) {
        let evictions = sessionPolicy.access(
            url,
            isDirty: isDirty,
            protectedURLs: protectedSessionURLs(),
            installedURLs: installedSessionURLs()
        )
        handleSessionEvictions(evictions)
    }

    private func activateRetiredFileSession(
        _ session: DocumentSession,
        canonicalURL: URL
    ) {
        _ = advanceSessionLifecycle(for: session)
        if session !== shownSession {
            moveCurrentDocumentWorkToBackgroundBeforeSwitch()
            registry.setWarmSession(session, at: canonicalURL)
            setCurrentDocument(session)
        } else {
            registry.setWarmSession(session, at: canonicalURL)
            synchronizeWorkspaceTreeSelection(for: session)
        }
        handleExternalChange(for: session, advancingDiskEvent: false)
        restoreRecoveryPrompt(for: session)
        handleSessionAccess(url: canonicalURL, isDirty: session.isDirty)
    }

    func rememberLastOpenedFile(_ url: URL) {
        do {
            try lastOpenedFileStore.save(url)
        } catch {
            present(error, title: "Could Not Remember Last File")
        }
    }

    func rememberRecentItem(_ url: URL) {
        do {
            try recentItemStore.save(url)
            recentItemURLs = try recentItemStore.restore()
        } catch {
            recentItemURLs = (try? recentItemStore.restore()) ?? recentItemURLs
        }
    }
}
