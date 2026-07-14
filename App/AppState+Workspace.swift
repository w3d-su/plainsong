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
        guard let workspaceRootURL else {
            handleCurrentDocumentExternalChange()
            return
        }

        scheduleWorkspaceReload(
            root: workspaceRootURL,
            selectFirstIfNeeded: false,
            errorTitle: "Could Not Refresh Workspace"
        )
    }

    func selectWorkspaceNode(id nodeID: WorkspaceFileNode.ID) {
        guard var tree = workspaceTree,
              let node = tree.node(id: nodeID),
              node.isEditableMarkdown,
              let workspaceRootURL
        else {
            return
        }

        tree.selectNode(id: nodeID)
        workspaceTree = tree
        openWorkspaceFile(
            workspaceRootURL.appendingPathComponent(node.relativePath, isDirectory: false)
        )
    }

    func setWorkspaceNodeExpanded(_ isExpanded: Bool, id nodeID: WorkspaceFileNode.ID) {
        workspaceTree?.setExpanded(isExpanded, for: nodeID)
    }

    func createWorkspaceFile(named name: String, inDirectoryID directoryID: WorkspaceFileNode.ID?) {
        performWorkspaceOperation(openCreatedFile: true, directoryID: directoryID) { root, directory in
            try fileOperations.createFile(named: name, in: directory ?? root)
        }
    }

    func createWorkspaceFolder(named name: String, inDirectoryID directoryID: WorkspaceFileNode.ID?) {
        performWorkspaceOperation(openCreatedFile: false, directoryID: directoryID) { root, directory in
            try fileOperations.createFolder(named: name, in: directory ?? root)
        }
    }

    func renameWorkspaceItem(id nodeID: WorkspaceFileNode.ID, to newName: String) {
        guard let url = workspaceURL(for: nodeID) else { return }
        performWorkspaceOperation(openCreatedFile: false, directoryID: nil) { _, _ in
            try fileOperations.rename(url, to: newName)
        }
    }

    func moveWorkspaceItem(id nodeID: WorkspaceFileNode.ID, toDirectoryID directoryID: WorkspaceFileNode.ID) {
        guard let sourceURL = workspaceURL(for: nodeID),
              let directoryURL = workspaceURL(for: directoryID)
        else {
            return
        }
        performWorkspaceOperation(openCreatedFile: false, directoryID: nil) { _, _ in
            try fileOperations.move(sourceURL, toDirectory: directoryURL)
        }
    }

    func trashWorkspaceItem(id nodeID: WorkspaceFileNode.ID) {
        guard let url = workspaceURL(for: nodeID) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await fileOperations.trash(url)
                refreshWorkspaceAfterFileSystemChange()
            } catch {
                present(error, title: "Could Not Move to Trash")
            }
        }
    }

    func open(url: URL, rememberAsLastOpened: Bool, preserveWorkspace: Bool) throws {
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

    func saveCurrentDocument() throws {
        try save(session: currentDocument)
    }
}

extension AppState {
    func openWorkspace(url: URL, rememberAsLastOpened: Bool) throws {
        let root = url.standardizedFileURL
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
                      workspaceRootURL?.standardizedFileURL == root
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
        let key = try canonicalSessionURL(for: url)
        if let cachedSession = sessionCache[key] {
            if cachedSession === currentDocument {
                synchronizeWorkspaceTreeSelection(for: cachedSession)
                handleSessionAccess(url: key, isDirty: cachedSession.isDirty)
                return
            }
            guard let cachedURL = cachedSession.fileURL,
                  try canonicalSessionURL(for: cachedURL) == key
            else {
                throw AppStateError.invalidSessionIdentity(key)
            }
            guard !detachedSessionURLs.contains(key) else {
                throw AppStateError.missingFile(key)
            }
            _ = try fileStore.load(url: key)
            cancelForegroundDocumentTasks()
            setCurrentDocument(cachedSession)
            handleExternalChange(for: cachedSession)
            handleSessionAccess(url: key, isDirty: cachedSession.isDirty)
            return
        }

        let file = try fileStore.load(url: key)
        let recoveredSession = recoverRetiredSession(for: key)
        let session = recoveredSession ?? DocumentSession(
            text: file.text,
            url: file.url,
            fileKind: file.fileKind,
            isDirty: false
        )
        cancelForegroundDocumentTasks()
        sessionCache[key] = session
        detachedSessionURLs.remove(key)
        if missingFilePrompt?.fileURL.standardizedFileURL == key {
            missingFilePrompt = nil
        }
        if recoveredSession == nil {
            recordKnownDiskText(file.text, for: key)
        }
        setCurrentDocument(session)
        if recoveredSession != nil {
            handleExternalChange(for: session)
        }
        handleSessionAccess(url: key, isDirty: session.isDirty)
    }

    func setCurrentDocument(
        _ session: DocumentSession,
        synchronizingWorkspaceTree: Bool = true
    ) {
        guard currentDocument !== session else { return }
        requestEditorFocus()
        if synchronizingWorkspaceTree {
            synchronizeWorkspaceTreeSelection(for: session)
        }
        cancelPendingEditorNavigationIfNeeded()
        currentDocument = session
        clearPromptsNotMatchingCurrentDocument()
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
        guard let sessionURL = session.fileURL?.standardizedFileURL else { return }
        let sessionIdentity = ObjectIdentifier(session)
        let retainedBinding = anchoredSessionFileBinding(for: session)
        let url = retainedBinding?.location.fileURL ?? sessionURL
        if let indeterminate = indeterminateSessionWrites[sessionIdentity] {
            let reconciliationURL = indeterminateSessionWriteContexts[sessionIdentity]?.location.fileURL
                ?? url
            throw MarkdownFileStoreError.writeRequiresReconciliation(reconciliationURL, indeterminate)
        }
        guard !detachedSessionURLs.contains(url),
              missingFilePrompt?.fileURL.standardizedFileURL != url
        else {
            throw AppStateError.missingFile(url)
        }
        guard pendingExternalTexts[url] == nil,
              externalChangePrompt?.fileURL.standardizedFileURL != url
        else {
            throw AppStateError.unresolvedExternalChange(url)
        }

        cancelAutosave(for: session)
        isSaving = true
        defer { isSaving = false }

        let text = session.text
        let location: WorkspaceFileSystemLocation
        let expectation: WorkspaceNoFollowFileWriteExpectation
        let prewriteBinding: AnchoredWorkspaceSessionFileBinding?
        if let retainedBinding,
           retainedBinding.location.fileURL == sessionURL
        {
            location = retainedBinding.location
            expectation = .existingContent(
                retainedBinding.identity,
                sha256Digest: retainedBinding.sha256Digest
            )
            prewriteBinding = retainedBinding
        } else {
            location = try WorkspaceFileSystemLocation(fileURL: sessionURL)
            let inspection = try WorkspaceNoFollowFileInspector.inspectFileTarget(at: location)
            guard inspection.canonicalLocation == location else {
                throw AppStateError.invalidSessionIdentity(location.fileURL)
            }
            expectation = switch inspection.state {
            case let .regular(identity): .existing(identity)
            case .missing: .missing
            }
            prewriteBinding = nil
        }
        let destination = location.fileURL
        let outcome = try performAnchoredFileSave(
            text: text,
            at: location,
            expecting: expectation
        )
        let cleanupResult: WorkspaceDurableFileWrite?
        switch outcome {
        case let .committedAndDurable(result):
            cleanupResult = result.cleanupState == .none ? nil : result
            indeterminateSessionWrites[sessionIdentity] = nil
            indeterminateSessionWriteContexts[sessionIdentity] = nil
            anchoredSessionFileBindings[sessionIdentity] = AnchoredWorkspaceSessionFileBinding(
                location: location,
                identity: result.metadata.identity,
                sha256Digest: WorkspaceSearchContentFingerprint(text: text).sha256Digest
            )
        case let .notCommitted(result):
            throw notCommittedFileWriteError(result, destinationURL: destination)
        case let .committedButIndeterminate(result):
            if let prewriteBinding {
                indeterminateSessionWrites[sessionIdentity] = result
                indeterminateSessionWriteContexts[sessionIdentity] = IndeterminateSessionWriteContext(
                    location: location,
                    preparedSHA256Digest: WorkspaceSearchContentFingerprint(
                        text: text
                    ).sha256Digest
                )
                cancelAutosave(for: session)
                handleAnchoredExternalChange(for: session, binding: prewriteBinding)
            } else {
                quarantineIndeterminateStandaloneSave(
                    session: session,
                    text: text,
                    location: location,
                    result: result
                )
            }
            throw MarkdownFileStoreError.writeRequiresReconciliation(destination, result)
        }
        session.markSaved(text: text, url: destination)
        sessionPolicy.updateDirtyState(for: destination, isDirty: false)
        detachedSessionURLs.remove(destination)
        lastKnownDiskHashes[destination] = Self.contentHash(text)
        lastKnownDiskModificationDates[destination] = nil
        if let cleanupResult {
            presentCommittedFileWriteCleanup(cleanupResult, destinationURL: destination)
        }
    }

    private func quarantineIndeterminateStandaloneSave(
        session: DocumentSession,
        text: String,
        location: WorkspaceFileSystemLocation,
        result: WorkspaceIndeterminateFileWrite
    ) {
        let sessionIdentity = ObjectIdentifier(session)
        indeterminateSessionWrites[sessionIdentity] = result
        indeterminateSessionWriteContexts[sessionIdentity] = IndeterminateSessionWriteContext(
            location: location,
            preparedSHA256Digest: WorkspaceSearchContentFingerprint(text: text).sha256Digest
        )
        cancelAutosave(for: session)

        if let observed = try? fileStore.loadResult(at: location) {
            let destination = location.fileURL
            anchoredSessionFileBindings[sessionIdentity] = AnchoredWorkspaceSessionFileBinding(
                location: location,
                identity: observed.metadata.identity,
                sha256Digest: observed.sha256Digest
            )
            pendingExternalTexts[destination] = observed.file.text
            lastKnownDiskHashes[destination] = Self.contentHash(observed.file.text)
            lastKnownDiskModificationDates[destination] = nil
            if session === currentDocument {
                missingFilePrompt = nil
                externalChangePrompt = ExternalChangePrompt(fileURL: destination)
            }
        } else if WorkspaceNoFollowFileInspector.status(at: location) == .missing {
            markSessionDetachedFromMissingFile(session, url: location.fileURL)
        }
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

    func presentCommittedFileWriteCleanup(
        _ result: WorkspaceDurableFileWrite,
        destinationURL: URL
    ) {
        guard result.cleanupState != .none else { return }
        retainFileWriteArtifactNotice(
            destinationURL: destinationURL,
            destinationWasCommitted: true,
            artifactState: result.cleanupState
        )
        present(
            MarkdownFileStoreError.committedWithCleanupRequired(destinationURL, result),
            title: "File Saved; Cleanup Required"
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

    func performWorkspaceOperation(
        openCreatedFile: Bool,
        directoryID: WorkspaceFileNode.ID?,
        operation: (URL, URL?) throws -> URL
    ) {
        guard let root = workspaceRootURL else { return }

        do {
            let directoryURL = directoryID.flatMap(workspaceURL(for:))
            let resultingURL = try operation(root, directoryURL)
            if openCreatedFile, FileKind(url: resultingURL) != nil {
                openWorkspaceFile(resultingURL)
            }
            refreshWorkspaceAfterFileSystemChange()
        } catch {
            present(error, title: "Workspace Operation Failed")
        }
    }

    func workspaceURL(for nodeID: WorkspaceFileNode.ID) -> URL? {
        guard let workspaceRootURL,
              let node = workspaceTree?.node(id: nodeID)
        else {
            return nil
        }

        if node.relativePath.isEmpty {
            return workspaceRootURL
        }
        return workspaceRootURL.appendingPathComponent(node.relativePath, isDirectory: node.isDirectory)
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
