import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

/// Lets a `WorkspaceEventWatcher` handler refer to the watcher it was installed on,
/// which cannot be captured while the watcher is being initialized. `watcher` is written
/// once on the main actor before `start()` and read on the watcher's serial queue and on
/// the main actor; the only mutation is that single assignment, so the box is sent safely.
private final class WorkspaceEventWatcherBox: @unchecked Sendable {
    weak var watcher: WorkspaceEventWatcher?
}

extension AppState {
    func openWorkspace(url: URL, rememberAsLastOpened: Bool) throws {
        try refuseWindowFileOpenIfNeeded()
        // Keep the chosen root's literal spelling until descriptor capture proves its canonical
        // physical location. Standardizing here loses precomposed Unicode before WS3B's
        // authority layer can retain it.
        let root = url
        try closeWorkspaceForReplacement()
        workspaceAccess = SecurityScopedAccess.startAccessing(root)
        workspaceRootURL = root
        workspaceTree = WorkspaceFileTree(
            root: WorkspaceFileNode(
                id: "__workspace_root__",
                name: root.lastPathComponent,
                relativePath: "",
                kind: .directory,
                contentModificationDate: nil
            )
        )

        if rememberAsLastOpened {
            rememberLastOpenedFile(root)
            rememberRecentItem(root)
        }

        let watcherBox = WorkspaceEventWatcherBox()
        let watcher = WorkspaceEventWatcher(rootURL: root) { [weak self, watcherBox, root] in
            Task { @MainActor [weak self] in
                // The watcher's stop() boundary only guarantees no handler *begins*
                // afterwards; a handler that began just before it still hops here.
                // Drop a delivery whose watcher was replaced or stopped meanwhile.
                guard let self else { return }
                let watcher = watcherBox.watcher
                let dropReason: String? = if watcher !== workspaceWatcher {
                    "replaced"
                } else if watcher == nil || watcher?.isStopped == true {
                    "stopped"
                } else if !(workspaceRootURL.map { self.exactFileURLSpellingMatches($0, root) } ?? false) {
                    "rootChanged"
                } else {
                    nil
                }
                // One call site for the decision trace and the refresh, so the resulting
                // handleExternalChange entry proves the fileID/line forwarding end to end.
                let site: (fileID: StaticString, line: UInt) = (#fileID, #line)
                traceWorkspaceWatcherDelivery(
                    dropReason: dropReason, watcher: watcher, fileID: site.fileID, line: site.line
                )
                guard dropReason == nil else { return }
                refreshWorkspaceAfterFileSystemChange(fileID: site.fileID, line: site.line)
            }
        }
        watcherBox.watcher = watcher
        workspaceWatcher = watcher
        workspaceWatcher?.start()

        scheduleWorkspaceReload(
            root: root,
            selectFirstIfNeeded: true,
            errorTitle: "Could Not Open Workspace"
        )
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
        shownSession = session
        releaseUnreferencedSessionOwnership(for: previousSession)
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
