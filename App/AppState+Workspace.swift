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

        workspaceReloadTask?.cancel()
        workspaceReloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await reloadWorkspaceTree(root: workspaceRootURL, selectFirstIfNeeded: false)
                handleCurrentDocumentExternalChange()
            } catch {
                present(error, title: "Could Not Refresh Workspace")
            }
        }
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
            closeWorkspace()
        }
        try activateFileSession(url: url)

        if rememberAsLastOpened {
            rememberLastOpenedFile(url)
            rememberRecentItem(url)
        }
    }

    func openWorkspaceFile(_ url: URL) {
        do {
            try activateFileSession(url: url)
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
        closeWorkspace()
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

        workspaceWatcher = WorkspaceEventWatcher(rootURL: root) { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshWorkspaceAfterFileSystemChange()
            }
        }
        workspaceWatcher?.start()

        workspaceReloadTask?.cancel()
        workspaceReloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await reloadWorkspaceTree(root: root, selectFirstIfNeeded: true)
            } catch {
                present(error, title: "Could Not Open Workspace")
            }
        }
    }

    func closeWorkspace() {
        workspaceReloadTask?.cancel()
        workspaceReloadTask = nil
        completionWorkspaceTask?.cancel()
        completionWorkspaceTask = nil
        workspaceWatcher?.stop()
        workspaceWatcher = nil
        for session in sessionCache.values where session.isDirty {
            do {
                try save(session: session)
            } catch {
                present(error, title: "Could Not Save Workspace File")
            }
        }
        workspaceAccess?.stop()
        workspaceAccess = nil
        workspaceRootURL = nil
        workspaceTree = nil
        completionWorkspace = .empty
        sessionCache.removeAll()
        sessionPolicy = WorkspaceSessionLRUPolicy(limit: 8)
        pendingExternalTexts.removeAll()
        lastKnownDiskHashes.removeAll()
        lastKnownDiskModificationDates.removeAll()
        detachedSessionURLs.removeAll()
        externalChangePrompt = nil
        missingFilePrompt = nil
    }

    func reloadWorkspaceTree(root: URL, selectFirstIfNeeded: Bool) async throws {
        let snapshot = try await directoryScanner.snapshot(root: root)
        var tree = WorkspaceFileTree.reconcile(
            previous: workspaceTree,
            snapshot: snapshot,
            options: .init(showAllFiles: showAllFiles)
        )

        if tree.selectedNode == nil || selectFirstIfNeeded {
            tree.selectNode(id: firstEditableNode(in: tree.root)?.id)
        }

        workspaceTree = tree
        scheduleCompletionWorkspaceRefresh()

        if let selectedNode = tree.selectedNode, selectedNode.isEditableMarkdown {
            try activateFileSession(
                url: root.appendingPathComponent(selectedNode.relativePath, isDirectory: false)
            )
        }
    }

    func activateFileSession(url: URL) throws {
        let key = url.standardizedFileURL
        autosaveTask?.cancel()
        statisticsTask?.cancel()

        if let cachedSession = sessionCache[key] {
            setCurrentDocument(cachedSession)
            handleExternalChange(for: cachedSession)
            handleSessionAccess(url: key, isDirty: cachedSession.isDirty)
            return
        }

        let file = try fileStore.load(url: key)
        let session = DocumentSession(
            text: file.text,
            url: file.url,
            fileKind: file.fileKind,
            isDirty: false
        )
        sessionCache[key] = session
        detachedSessionURLs.remove(key)
        if missingFilePrompt?.fileURL.standardizedFileURL == key {
            missingFilePrompt = nil
        }
        recordKnownDiskText(file.text, for: key)
        setCurrentDocument(session)
        handleSessionAccess(url: key, isDirty: false)
    }

    func setCurrentDocument(_ session: DocumentSession) {
        guard currentDocument !== session else {
            scheduleCompletionWorkspaceRefresh()
            return
        }
        currentDocument = session
        clearPromptsNotMatchingCurrentDocument()
        observeCurrentDocument()
        scheduleCompletionWorkspaceRefresh()
    }

    func handleSessionAccess(url: URL, isDirty: Bool) {
        let evictions = sessionPolicy.access(url, isDirty: isDirty)
        handleSessionEvictions(evictions)
    }

    func handleSessionEvictions(_ evictions: [WorkspaceSessionEviction]) {
        for eviction in evictions {
            guard let session = sessionCache[eviction.url] else { continue }
            if eviction.requiresSave {
                do {
                    try save(session: session)
                } catch {
                    present(error, title: "Could Not Save Warm File")
                    handleSessionEvictions(sessionPolicy.access(eviction.url, isDirty: session.isDirty))
                    continue
                }
            }
            sessionCache[eviction.url] = nil
        }
    }

    func save(session: DocumentSession) throws {
        guard let url = session.fileURL?.standardizedFileURL else { return }
        guard !detachedSessionURLs.contains(url),
              missingFilePrompt?.fileURL.standardizedFileURL != url
        else {
            throw AppStateError.missingFile(url)
        }
        guard externalChangePrompt?.fileURL.standardizedFileURL != url else {
            throw AppStateError.unresolvedExternalChange(url)
        }

        autosaveTask?.cancel()
        isSaving = true
        defer { isSaving = false }

        let text = session.text
        try SecurityScopedAccess.withAccess(to: url) {
            try fileStore.save(text: text, to: url)
        }
        session.markSaved(text: text, url: url)
        sessionPolicy.updateDirtyState(for: url, isDirty: false)
        detachedSessionURLs.remove(url)
        recordKnownDiskText(text, for: url)
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
            refreshWorkspaceAfterFileSystemChange()

            if openCreatedFile, FileKind(url: resultingURL) != nil {
                openWorkspaceFile(resultingURL)
            }
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
}
