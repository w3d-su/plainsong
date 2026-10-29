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

    func refreshWorkspaceAfterFileSystemChange(
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) {
        guard workspaceMutationNamespaceDepth == 0 else {
            workspaceMutationRefreshPending = true
            workspaceMutationExternalRefreshPending = true
            if workspaceMutationRefreshRootAuthority == nil {
                workspaceMutationRefreshRootAuthority = workspaceSearchRootAuthority
            }
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
            handleCurrentDocumentExternalChange(fileID: fileID, line: line)
            return
        }

        // A watcher notification is itself the ordering boundary for physical
        // document reads. Advance the per-session disk generation immediately so a
        // slow directory snapshot cannot allow an older Reload / Keep Mine read to
        // commit before the newer event is observed.
        handleManagedWorkspaceSessionsExternalChange(fileID: fileID, line: line)

        scheduleWorkspaceReload(
            root: workspaceRootURL,
            selectFirstIfNeeded: false,
            errorTitle: "Could Not Refresh Workspace"
        )
    }

    func refreshWorkspaceAfterNamespaceMutation(
        using retainedRootAuthority: WorkspaceFileSystemRootAuthority,
        inspectManagedSessions: Bool,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) {
        guard workspaceMutationNamespaceDepth == 0 else {
            workspaceMutationRefreshPending = true
            workspaceMutationExternalRefreshPending =
                workspaceMutationExternalRefreshPending || inspectManagedSessions
            return
        }
        guard let workspaceRootURL else {
            if inspectManagedSessions {
                handleCurrentDocumentExternalChange(fileID: fileID, line: line)
            }
            return
        }

        if inspectManagedSessions {
            if workspaceSearchRootAuthority == retainedRootAuthority {
                handleManagedWorkspaceSessionsExternalChange(
                    rootAuthority: retainedRootAuthority,
                    fileID: fileID,
                    line: line
                )
            } else {
                handleCurrentDocumentExternalChange(fileID: fileID, line: line)
            }
        }
        scheduleWorkspaceReload(
            root: workspaceRootURL,
            selectFirstIfNeeded: false,
            errorTitle: "Could Not Refresh Workspace"
        )
    }

    private func handleManagedWorkspaceSessionsExternalChange(
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) {
        guard let rootAuthority = workspaceSearchRootAuthority,
              workspaceInstalledCaptureGeneration == workspaceGeneration
        else {
            handleCurrentDocumentExternalChange(fileID: fileID, line: line)
            return
        }

        handleManagedWorkspaceSessionsExternalChange(
            rootAuthority: rootAuthority,
            fileID: fileID,
            line: line
        )
    }

    private func handleManagedWorkspaceSessionsExternalChange(
        rootAuthority: WorkspaceFileSystemRootAuthority,
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) {
        for session in managedWorkspaceSessions(rootAuthority: rootAuthority) {
            handleExternalChange(for: session, fileID: fileID, line: line)
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
        try refuseWindowFileOpenIfNeeded()
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
            try refuseWindowFileOpenIfNeeded()
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
        /// Opens an app-container-owned XCUITest fixture through production workspace setup
        /// without leaking its temporary URL into user last-opened or recent-item stores.
        func openDebugUITestWorkspaceFixture(_ url: URL) {
            do {
                try open(url: url, rememberAsLastOpened: false, preserveWorkspace: false)
            } catch {
                present(error, title: "Could Not Open UI Test Fixture")
            }
        }
    #endif

    func saveCurrentDocument() throws {
        try save(session: shownSession)
    }
}

extension AppState {
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
