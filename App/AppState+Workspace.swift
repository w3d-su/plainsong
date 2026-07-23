import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    func toggleShowAllFiles() {
        showAllFiles.toggle()
        refreshWorkspaceAfterFileSystemChange()
    }

    func refreshWorkspaceAfterFileSystemChange() {
        guard workspaceMutationNamespaceDepth == 0 else {
            workspaceMutationRefreshPending = true
            workspaceMutationExternalRefreshPending = true
            if let rootAuthority = workspaceMutationRefreshRootAuthority
                ?? workspaceSearchRootAuthority
            {
                supersedeManagedWorkspaceSessionsExternalWork(
                    rootAuthority: rootAuthority
                )
            }
            return
        }
        guard let workspaceRootURL else {
            handleCurrentDocumentExternalChange()
            return
        }

        // A watcher notification is itself the ordering boundary for physical
        // document reads. Advance the per-session disk generation immediately so a
        // slow directory snapshot cannot allow an older Reload / Keep Mine read to
        // commit before the newer event is observed.
        handleManagedWorkspaceSessionsExternalChange()

        scheduleWorkspaceReload(
            root: workspaceRootURL,
            selectFirstIfNeeded: false,
            errorTitle: "Could Not Refresh Workspace"
        )
    }

    func refreshWorkspaceAfterNamespaceMutation(
        using retainedRootAuthority: WorkspaceFileSystemRootAuthority,
        inspectManagedSessions: Bool
    ) {
        guard workspaceMutationNamespaceDepth == 0 else {
            workspaceMutationRefreshPending = true
            workspaceMutationExternalRefreshPending =
                workspaceMutationExternalRefreshPending || inspectManagedSessions
            return
        }
        guard let workspaceRootURL else {
            if inspectManagedSessions {
                handleCurrentDocumentExternalChange()
            }
            return
        }

        if inspectManagedSessions {
            if workspaceSearchRootAuthority == retainedRootAuthority {
                handleManagedWorkspaceSessionsExternalChange(
                    rootAuthority: retainedRootAuthority
                )
            } else {
                handleCurrentDocumentExternalChange()
            }
        }
        scheduleWorkspaceReload(
            root: workspaceRootURL,
            selectFirstIfNeeded: false,
            errorTitle: "Could Not Refresh Workspace"
        )
    }

    private func handleManagedWorkspaceSessionsExternalChange() {
        guard let rootAuthority = workspaceSearchRootAuthority,
              workspaceInstalledCaptureGeneration == workspaceGeneration
        else {
            handleCurrentDocumentExternalChange()
            return
        }

        handleManagedWorkspaceSessionsExternalChange(rootAuthority: rootAuthority)
    }

    private func handleManagedWorkspaceSessionsExternalChange(
        rootAuthority: WorkspaceFileSystemRootAuthority
    ) {
        for session in managedWorkspaceSessions(rootAuthority: rootAuthority) {
            handleExternalChange(for: session)
        }
    }

    private func supersedeManagedWorkspaceSessionsExternalWork(
        rootAuthority: WorkspaceFileSystemRootAuthority
    ) {
        for session in managedWorkspaceSessions(rootAuthority: rootAuthority) {
            let sessionIdentity = ObjectIdentifier(session)
            guard !indeterminateWorkspaceMutationSessions.contains(sessionIdentity) else {
                continue
            }
            workspaceMutationWriteFences.insert(sessionIdentity)
            _ = advanceExternalDiskEventGeneration(for: session)
            externalDiskInspectionTasks.removeValue(forKey: sessionIdentity)?.task.cancel()
            supersedeExternalResolutionRead(for: session)
        }
    }

    private func managedWorkspaceSessions(
        rootAuthority: WorkspaceFileSystemRootAuthority
    ) -> [DocumentSession] {
        var sessions = workspaceMutationManagedSessions().filter { session in
            if retainedManagedSessionLocation(for: session)?.rootAuthority == rootAuthority {
                return true
            }
            if case let .proven(proof)? = unanchoredManagedSessionOwnershipProofs[
                ObjectIdentifier(session)
            ] {
                return proof.installedWorkspaceLocation?.rootAuthority == rootAuthority
            }
            return false
        }
        sessions.sort {
            (sessionStateURL(for: $0)?.absoluteString ?? "").utf8.lexicographicallyPrecedes(
                (sessionStateURL(for: $1)?.absoluteString ?? "").utf8
            )
        }
        return sessions
    }

    func selectWorkspaceNode(id nodeID: WorkspaceFileNode.ID) {
        guard var tree = workspaceTree,
              let node = tree.node(id: nodeID),
              node.isEditableMarkdown,
              let rootAuthority = workspaceSearchRootAuthority,
              workspaceInstalledCaptureGeneration == workspaceGeneration,
              let fileURL = try? rootAuthority.location(relativePath: node.relativePath).fileURL
        else {
            return
        }

        tree.selectNode(id: nodeID)
        workspaceTree = tree
        openWorkspaceFile(fileURL)
    }

    func setWorkspaceNodeExpanded(_ isExpanded: Bool, id nodeID: WorkspaceFileNode.ID) {
        workspaceTree?.setExpanded(isExpanded, for: nodeID)
    }

    func createWorkspaceFile(named name: String, inDirectoryID directoryID: WorkspaceFileNode.ID?) {
        performWorkspaceCreation(
            named: name,
            kind: .file,
            directoryID: directoryID
        )
    }

    func createWorkspaceFolder(named name: String, inDirectoryID directoryID: WorkspaceFileNode.ID?) {
        performWorkspaceCreation(
            named: name,
            kind: .folder,
            directoryID: directoryID
        )
    }

    func renameWorkspaceItem(id nodeID: WorkspaceFileNode.ID, to newName: String) {
        guard let tree = workspaceTree,
              let node = tree.node(id: nodeID),
              let expectation = node.mutationExpectation,
              let rootAuthority = workspaceSearchRootAuthority,
              let sourceParentExpectation = workspaceMutationParentExpectation(
                  for: node.relativePath,
                  tree: tree,
                  rootAuthority: rootAuthority
              ),
              workspaceInstalledCaptureGeneration == workspaceGeneration
        else {
            return
        }
        do {
            try renameWorkspaceItem(
                at: rootAuthority.location(relativePath: node.relativePath),
                to: newName,
                expecting: expectation,
                sourceParentExpectation: sourceParentExpectation
            )
        } catch {
            present(error, title: "Could Not Rename Item")
        }
    }

    func moveWorkspaceItem(id nodeID: WorkspaceFileNode.ID, toDirectoryID directoryID: WorkspaceFileNode.ID) {
        guard let tree = workspaceTree,
              let sourceNode = tree.node(id: nodeID),
              let destinationNode = tree.node(id: directoryID),
              destinationNode.isDirectory,
              let expectation = sourceNode.mutationExpectation,
              let rootAuthority = workspaceSearchRootAuthority,
              let sourceParentExpectation = workspaceMutationParentExpectation(
                  for: sourceNode.relativePath,
                  tree: tree,
                  rootAuthority: rootAuthority
              ),
              let destinationParentExpectation = destinationNode.relativePath.isEmpty
              ? rootAuthority.directoryMutationExpectation
              : destinationNode.mutationExpectation,
              workspaceInstalledCaptureGeneration == workspaceGeneration
        else {
            return
        }
        do {
            try moveWorkspaceItem(
                at: rootAuthority.location(relativePath: sourceNode.relativePath),
                toDirectoryRelativePath: destinationNode.relativePath,
                expecting: expectation,
                sourceParentExpectation: sourceParentExpectation,
                destinationParentExpectation: destinationParentExpectation
            )
        } catch {
            present(error, title: "Could Not Move Item")
        }
    }

    func trashWorkspaceItem(id nodeID: WorkspaceFileNode.ID) {
        guard let tree = workspaceTree,
              let node = tree.node(id: nodeID),
              let expectation = node.mutationExpectation,
              let rootAuthority = workspaceSearchRootAuthority,
              let sourceParentExpectation = workspaceMutationParentExpectation(
                  for: node.relativePath,
                  tree: tree,
                  rootAuthority: rootAuthority
              ),
              workspaceInstalledCaptureGeneration == workspaceGeneration,
              let source = try? rootAuthority.location(relativePath: node.relativePath)
        else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await trashWorkspaceItem(
                    at: source,
                    expecting: expectation,
                    sourceParentExpectation: sourceParentExpectation
                )
            } catch {
                present(error, title: "Could Not Move to Trash")
            }
        }
    }

    func open(url: URL, rememberAsLastOpened: Bool, preserveWorkspace: Bool) throws {
        try validateWorkspaceMutationRecoveryStoresLoaded(at: url)
        let isDirectory = try SecurityScopedAccess.withAccess(to: url) {
            try Self.isDirectory(url)
        }

        if isDirectory {
            try openWorkspace(url: url, rememberAsLastOpened: rememberAsLastOpened)
            return
        }

        guard FileKind(url: url) != nil else {
            throw AppStateError.unsupportedFile(url)
        }

        if !preserveWorkspace {
            try closeWorkspaceForReplacement()
        }
        try activateFileSession(url: url)

        if rememberAsLastOpened {
            rememberLastOpenedFile(url)
            rememberRecentItem(url)
        }
    }

    func openWorkspaceFile(_ url: URL) {
        do {
            try validateWorkspaceMutationRecoveryStoresLoaded(at: url)
            if workspaceRootURL != nil {
                guard let rootAuthority = workspaceSearchRootAuthority,
                      workspaceInstalledCaptureGeneration == workspaceGeneration
                else {
                    throw WorkspaceAnchoredFileSystemError.namespaceChanged
                }
                let location = try rootAuthority.canonicalizedLocation(forFileURL: url)
                try activateAnchoredFileSession(at: location)
            } else {
                try activateFileSession(url: url)
            }
        } catch {
            present(error, title: "Could Not Open File")
        }
    }

    #if DEBUG
        /// Opens the app-container-owned XCUITest fixture through production workspace setup
        /// without leaking its temporary URL into user last-opened or recent-item stores.
        func openDebugWorkspaceSearchFixture(_ url: URL) {
            do {
                try open(url: url, rememberAsLastOpened: false, preserveWorkspace: false)
            } catch {
                present(error, title: "Could Not Open UI Test Fixture")
            }
        }
    #endif

    func saveCurrentDocument() throws {
        try save(session: currentDocument)
    }
}

private struct ManagedSessionWriteContext {
    let sessionIdentity: ObjectIdentifier
    let stateURL: URL
    let location: WorkspaceFileSystemLocation
    let expectedIdentity: WorkspaceFileSystemIdentity
    let expectation: WorkspaceNoFollowFileWriteExpectation
}

extension AppState {
    func openWorkspace(url: URL, rememberAsLastOpened: Bool) throws {
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

        workspaceWatcher = WorkspaceEventWatcher(rootURL: root) { [weak self, root] in
            Task { @MainActor [weak self] in
                guard let self,
                      let currentRoot = workspaceRootURL,
                      exactFileURLSpellingMatches(currentRoot, root)
                else {
                    return
                }
                refreshWorkspaceAfterFileSystemChange()
            }
        }
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
        if let cachedSession = sessionCache[key] {
            guard retainedManagedSessionLocation(for: cachedSession) == location else {
                throw AppStateError.invalidSessionIdentity(key)
            }
            guard let cachedURL = sessionStateURL(for: cachedSession),
                  exactFileURLSpellingMatches(cachedURL, key)
            else {
                throw AppStateError.invalidSessionIdentity(key)
            }
            if cachedSession === currentDocument {
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
        sessionCache[key] = session
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
        synchronizingWorkspaceTree: Bool = true
    ) {
        guard currentDocument !== session else { return }
        moveCurrentDocumentWorkToBackgroundBeforeSwitch()
        requestEditorFocus()
        if synchronizingWorkspaceTree {
            synchronizeWorkspaceTreeSelection(for: session)
        }
        cancelPendingEditorNavigationIfNeeded()
        currentDocument = session
        clearPromptsNotMatchingCurrentDocument()
        restoreRecoveryPrompt(for: session)
        if indeterminateSessionWrites[ObjectIdentifier(session)] != nil {
            refreshIndeterminateFileWriteReconciliation(for: session)
        }
        observeCurrentDocument()
        scheduleCompletionWorkspaceRefresh()
    }

    func handleSessionAccess(url: URL, isDirty: Bool) {
        let evictions = sessionPolicy.access(
            url,
            isDirty: isDirty,
            protectedURLs: protectedSessionURLs()
        )
        handleSessionEvictions(evictions)
    }

    func save(session: DocumentSession) throws {
        try validateWorkspaceMutationRecoveryStoresLoaded(
            at: sessionStateURL(for: session) ?? session.fileURL
        )
        guard let writeContext = try managedSessionWriteContext(for: session) else { return }
        let sessionIdentity = writeContext.sessionIdentity
        let url = writeContext.stateURL
        guard !workspaceMutationWriteFences.contains(sessionIdentity),
              !indeterminateWorkspaceMutationSessions.contains(sessionIdentity)
        else {
            throw AppStateError.workspaceMutationInProgress(url)
        }
        guard !hasPendingEditorSource(for: session) else {
            throw AppStateError.pendingEditorSource(url)
        }
        if let indeterminate = indeterminateSessionWrites[sessionIdentity] {
            let reconciliationURL = indeterminateSessionWriteContexts[sessionIdentity]?.location.fileURL
                ?? url
            throw MarkdownFileStoreError.writeRequiresReconciliation(reconciliationURL, indeterminate)
        }
        let hasMatchingMissingPrompt = missingFilePrompt.map {
            exactFileURLSpellingMatches($0.fileURL, url)
        } ?? false
        guard !detachedSessionURLs.contains(url), !hasMatchingMissingPrompt else {
            throw AppStateError.missingFile(url)
        }
        let hasMatchingExternalChangePrompt = externalChangePrompt.map {
            exactFileURLSpellingMatches($0.fileURL, url)
        } ?? false
        guard pendingExternalTexts[url] == nil,
              pendingExternalFileVersions[url] == nil,
              !hasMatchingExternalChangePrompt,
              externalReloadTasks[sessionIdentity] == nil,
              pendingExternalReloadApplications[sessionIdentity] == nil,
              deferredExternalChangeResolutions[url] == nil,
              externalDiskInspectionTasks[sessionIdentity] == nil
        else {
            throw AppStateError.unresolvedExternalChange(url)
        }

        cancelAutosave(for: session)
        isSaving = true
        defer { isSaving = false }

        let text = session.text
        if hasConflictingPhysicalSessionOwnership(
            writeContext.expectedIdentity,
            excluding: session
        ) {
            throw AppStateError.duplicateSessionOwnership(url)
        }
        let destination = writeContext.location.fileURL
        let outcome = try performAnchoredFileSave(
            text: text,
            at: writeContext.location,
            expecting: writeContext.expectation
        )
        let cleanupResult: WorkspaceDurableFileWrite?
        switch outcome {
        case let .committedAndDurable(result):
            cleanupResult = result.cleanupState == .none ? nil : result
            indeterminateSessionWrites[sessionIdentity] = nil
            indeterminateSessionWriteContexts[sessionIdentity] = nil
            let preparedImageAssetAuthority =
                rebindEditorImageAssetDocumentAuthorityAfterSave(
                    for: session,
                    location: writeContext.location,
                    replacing: writeContext.expectedIdentity,
                    with: result.metadata.identity
                )
            adoptAnchoredFileBinding(
                AnchoredWorkspaceSessionFileBinding(
                    location: writeContext.location,
                    identity: result.metadata.identity,
                    sha256Digest: WorkspaceSearchContentFingerprint(text: text).sha256Digest
                ),
                for: session,
                preparedImageAssetAuthority: preparedImageAssetAuthority
            )
        case let .notCommitted(result):
            handleExternalWritePreconditionFailure(result, for: session)
            throw notCommittedFileWriteError(result, destinationURL: destination)
        case let .committedButIndeterminate(result):
            indeterminateSessionWrites[sessionIdentity] = result
            indeterminateSessionWriteContexts[sessionIdentity] = IndeterminateSessionWriteContext(
                location: writeContext.location,
                preparedSHA256Digest: WorkspaceSearchContentFingerprint(
                    text: text
                ).sha256Digest
            )
            cancelAutosave(for: session)
            refreshIndeterminateFileWriteReconciliation(for: session)
            throw MarkdownFileStoreError.writeRequiresReconciliation(destination, result)
        }
        session.markSaved(text: text, url: destination)
        _ = clearWorkspaceMutationTextRecovery(for: session)
        sessionPolicy.updateDirtyState(for: destination, isDirty: false)
        detachedSessionURLs.remove(destination)
        lastKnownDiskHashes[destination] = Self.contentHash(text)
        lastKnownDiskModificationDates[destination] = nil
        if let cleanupResult {
            presentCommittedFileWriteCleanup(cleanupResult, destinationURL: destination)
        }
    }

    private func managedSessionWriteContext(
        for session: DocumentSession
    ) throws -> ManagedSessionWriteContext? {
        guard session.fileURL != nil else { return nil }
        let sessionIdentity = ObjectIdentifier(session)
        if let binding = anchoredSessionFileBinding(for: session) {
            return ManagedSessionWriteContext(
                sessionIdentity: sessionIdentity,
                stateURL: binding.location.fileURL,
                location: binding.location,
                expectedIdentity: binding.identity,
                expectation: .existingContent(
                    binding.identity,
                    sha256Digest: binding.sha256Digest
                )
            )
        }
        if case let .proven(proof)? =
            unanchoredManagedSessionOwnershipProofs[sessionIdentity]
        {
            return ManagedSessionWriteContext(
                sessionIdentity: sessionIdentity,
                stateURL: proof.location.fileURL,
                location: proof.location,
                expectedIdentity: proof.identity,
                expectation: .existingContent(
                    proof.identity,
                    sha256Digest: proof.sha256Digest
                )
            )
        }
        guard let stateURL = sessionStateURL(for: session) else { return nil }
        throw AppStateError.invalidSessionIdentity(stateURL)
    }

    func performAnchoredFileSave(
        text: String,
        at location: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceNoFollowFileWriteExpectation
    ) throws -> WorkspaceFileWriteOutcome {
        if let anchoredFileSaveOverride {
            return try anchoredFileSaveOverride(text, location, expectation)
        }
        return try fileStore.save(text: text, at: location, expecting: expectation)
    }

    func notCommittedFileWriteError(
        _ result: WorkspaceNotCommittedFileWrite,
        destinationURL: URL
    ) -> MarkdownFileStoreError {
        guard result.artifactState != .none else {
            return .unwritable(destinationURL)
        }
        retainFileWriteArtifactNotice(
            destinationURL: destinationURL,
            destinationWasCommitted: false,
            artifactState: result.artifactState
        )
        return .writeNotCommittedWithCleanupRequired(destinationURL, result)
    }

    /// A typed writer precondition can discover the same external B version before an FSEvent
    /// reaches `handleExternalChange`. Treat identity/content disagreement as the session-scoped
    /// arbitration event, not merely an unwritable save: one fresh retained-authority
    /// observation records the conflict and preserves A's proof.
    private func handleExternalWritePreconditionFailure(
        _ result: WorkspaceNotCommittedFileWrite,
        for session: DocumentSession
    ) {
        switch result.reason {
        case .changedIdentity, .changedContent:
            handleExternalChange(for: session)
        default:
            break
        }
    }

    func presentCommittedFileWriteCleanup(
        _ result: WorkspaceDurableFileWrite,
        destinationURL: URL
    ) {
        guard result.cleanupState != .none else { return }
        retainCommittedFileWriteCleanupNotice(
            result,
            destinationURL: destinationURL
        )
        present(
            MarkdownFileStoreError.committedWithCleanupRequired(destinationURL, result),
            title: "File Saved; Cleanup Required"
        )
    }

    func retainCommittedFileWriteCleanupNotice(
        _ result: WorkspaceDurableFileWrite,
        destinationURL: URL
    ) {
        guard result.cleanupState != .none else { return }
        retainFileWriteArtifactNotice(
            destinationURL: destinationURL,
            destinationWasCommitted: true,
            artifactState: result.cleanupState
        )
    }

    private func retainFileWriteArtifactNotice(
        destinationURL: URL,
        destinationWasCommitted: Bool,
        artifactState: WorkspaceFileWriteArtifactState
    ) {
        guard artifactState != .none else { return }
        let notice = FileWriteArtifactNotice(
            destinationURL: destinationURL.standardizedFileURL,
            destinationWasCommitted: destinationWasCommitted,
            artifactState: artifactState
        )
        guard !fileWriteArtifactNotices.contains(notice) else { return }
        fileWriteArtifactNotices.append(notice)
    }

    /// Acknowledges one retained cleanup artifact without mutating the artifact itself. Removing
    /// the notice also releases the notice's exact filesystem authority when no other owner needs it.
    func acknowledgeFileWriteArtifactNotice(id: FileWriteArtifactNotice.ID) {
        fileWriteArtifactNotices.removeAll { $0.id == id }
    }

    func cancelForegroundDocumentTasks() {
        autosaveTask?.cancel()
        autosaveTask = nil
        statisticsTask?.cancel()
        statisticsTask = nil
    }

    func moveCurrentDocumentWorkToBackgroundBeforeSwitch() {
        let previousSession = currentDocument
        moveCurrentAutosaveToBackground(for: previousSession)
        moveCurrentStatisticsToBackground(for: previousSession)
    }

    private func activateRetiredFileSession(
        _ session: DocumentSession,
        canonicalURL: URL
    ) {
        _ = advanceSessionLifecycle(for: session)
        if session !== currentDocument {
            moveCurrentDocumentWorkToBackgroundBeforeSwitch()
            sessionCache[canonicalURL] = session
            setCurrentDocument(session)
        } else {
            sessionCache[canonicalURL] = session
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

    func performWorkspaceCreation(
        named name: String,
        kind: WorkspaceCreationKind,
        directoryID: WorkspaceFileNode.ID?
    ) {
        do {
            try validateWorkspaceMutationRecoveryStoresLoaded()
            guard workspaceMutationNamespaceDepth == 0 else {
                throw WorkspaceMutationError.operationAlreadyInProgress
            }
            guard workspaceImageAssetInsertionCount == 0 else {
                throw WorkspaceMutationError.imageInsertionInProgress
            }
            guard let tree = workspaceTree,
                  let rootAuthority = workspaceSearchRootAuthority,
                  workspaceInstalledCaptureGeneration == workspaceGeneration
            else {
                throw WorkspaceMutationError.unavailableWorkspaceDirectory
            }
            let directory = try workspaceCreationDirectory(
                directoryID: directoryID,
                tree: tree,
                rootAuthority: rootAuthority
            )
            let creationPlan = switch kind {
            case .file:
                try fileOperations.makeFileCreationPlan(
                    named: name,
                    inDirectoryRelativePath: directory.relativePath,
                    rootAuthority: rootAuthority,
                    expectingDirectory: directory.expectation
                )
            case .folder:
                try fileOperations.makeFolderCreationPlan(
                    named: name,
                    inDirectoryRelativePath: directory.relativePath,
                    rootAuthority: rootAuthority,
                    expectingDirectory: directory.expectation
                )
            }
            try validateWorkspaceMutationDestinationOwnership(creationPlan.destination)

            let fencedSessions: [DocumentSession] = []
            try beginWorkspaceNamespaceMutation(fencedSessions)
            var mutationEnded = false
            defer {
                if !mutationEnded {
                    endWorkspaceNamespaceMutation(fencedSessions)
                    drainWorkspaceMutationRefreshIfNeeded()
                }
            }
            var recoveryIntent = try prepareWorkspaceCreationRecoveryIntent(
                plan: creationPlan,
                kind: kind
            )
            let outcome = switch kind {
            case .file:
                fileOperations.createFile(
                    using: creationPlan,
                    recordingCreatedArtifact: { artifact in
                        try self.recordWorkspaceCreatedArtifact(
                            artifact,
                            recoveryIntent: &recoveryIntent
                        )
                    }
                )
            case .folder:
                fileOperations.createFolder(
                    using: creationPlan,
                    recordingCreatedArtifact: { artifact in
                        try self.recordWorkspaceCreatedArtifact(
                            artifact,
                            recoveryIntent: &recoveryIntent
                        )
                    }
                )
            }
            endWorkspaceNamespaceMutation(fencedSessions)
            mutationEnded = true
            drainWorkspaceMutationRefreshIfNeeded()
            try finishWorkspaceCreation(outcome, recoveryIntent: recoveryIntent)
        } catch {
            present(error, title: "Workspace Operation Failed")
        }
    }

    func firstEditableNode(in node: WorkspaceFileNode) -> WorkspaceFileNode? {
        if node.isEditableMarkdown {
            return node
        }

        for child in node.children {
            if let match = firstEditableNode(in: child) {
                return match
            }
        }

        return nil
    }

    static func isDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        return values.isDirectory == true
    }
}

extension AppState {
    static func isDescendant(_ url: URL, of directory: URL) -> Bool {
        let candidatePath = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let rootPath = normalizedDirectoryPath(
            directory.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        )
        return candidatePath == rootPath || candidatePath.hasPrefix("\(rootPath)/")
    }

    static func normalizedDirectoryPath(_ path: String) -> String {
        guard path != "/" else { return path }
        var normalized = path
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    static func workspaceRelativePath(for url: URL, root: URL) -> String? {
        try? WorkspaceRootContainment.relativePath(for: url, rootURL: root)
    }
}
