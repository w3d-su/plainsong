import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    func scheduleWorkspaceReload(
        root: URL,
        selectFirstIfNeeded: Bool,
        errorTitle: String
    ) {
        let selectedRoot = root
        let generation = advanceWorkspaceGeneration()
        let scanner = directoryScanner
        let pruning = workspaceScanPruning(root: selectedRoot)
        // The watcher drops batches inside the subtrees this scan skips (M10), so it must
        // learn each new pruning, including the chains kept for open documents.
        workspaceWatcher?.setEventPathFilter(WorkspaceEventPathFilter(rootURL: selectedRoot, pruning: pruning))
        workspaceReloadTask?.cancel()

        let context = workspaceRootContext
        // The root owns the task. Resolve a live participant after each suspension so the
        // scan survives the initiating window leaving a root that another window still owns.
        workspaceReloadTask = Task { @MainActor [weak self, weak context, scanner] in
            do {
                let capture = try await scanner.snapshotCapture(root: selectedRoot, pruning: pruning)
                while let context, !Task.isCancelled, context.workspaceGeneration == generation {
                    guard let facade = context.facades.first ?? self,
                          facade.workspaceRootContext === context
                    else { return }
                    do {
                        try await facade.reloadWorkspaceCapture(
                            root: selectedRoot,
                            scanner: scanner,
                            initialCapture: capture,
                            generation: generation,
                            selectFirstIfNeeded: selectFirstIfNeeded && facade === self
                        )
                        return
                    } catch is CancellationError {
                        guard facade.workspaceRootContext !== context || facade.workspaceRootURL == nil else {
                            return
                        }
                    }
                }
            } catch is CancellationError {
                // A newer reload or the last root release invalidated this scan.
            } catch {
                guard let context,
                      let facade = context.facades.first ?? self,
                      facade.workspaceRootContext === context,
                      facade.isCurrentWorkspaceReload(root: selectedRoot, generation: generation)
                else { return }
                facade.present(error, title: errorTitle)
            }
        }
    }

    /// Direct callers receive their own generation so a slower scan cannot apply stale state.
    func reloadWorkspaceTree(root: URL, selectFirstIfNeeded: Bool) async throws {
        let selectedRoot = root
        let generation = advanceWorkspaceGeneration()
        let capture = try await directoryScanner.snapshotCapture(
            root: selectedRoot,
            pruning: workspaceScanPruning(root: selectedRoot)
        )
        try await reloadWorkspaceCapture(
            root: selectedRoot,
            scanner: directoryScanner,
            initialCapture: capture,
            generation: generation,
            selectFirstIfNeeded: selectFirstIfNeeded
        )
    }

    func reloadWorkspaceCapture(
        root: URL,
        scanner: any WorkspaceDirectoryScanning,
        initialCapture: WorkspaceDirectorySnapshotCapture,
        generation: UInt64,
        selectFirstIfNeeded: Bool
    ) async throws {
        var shouldSelectFirst = selectFirstIfNeeded
        var capture = initialCapture
        while true {
            guard isCurrentWorkspaceReload(root: root, generation: generation) else {
                throw CancellationError()
            }
            do {
                try await applyWorkspaceReload(
                    root: root,
                    capture: capture,
                    generation: generation,
                    selectFirstIfNeeded: shouldSelectFirst
                )
                return
            } catch WorkspaceReloadRetry.documentStateChanged {
                // The same reload still owns this generation. Re-capture and prepare
                // against the user's newest session instead of leaving readiness fenced.
                shouldSelectFirst = false
                guard isCurrentWorkspaceReload(root: root, generation: generation) else {
                    throw CancellationError()
                }
                capture = try await scanner.snapshotCapture(
                    root: root,
                    pruning: workspaceScanPruning(root: root)
                )
            }
        }
    }

    /// "Show all files" off skips generated and vendored directories (`node_modules`,
    /// `dist`, …) at scan time, except the chain down to a managed session's file: an open
    /// document there must not look missing after the rescan.
    ///
    /// Only paths inside `root` count. During a workspace switch the outgoing workspace's
    /// current document and its anchored binding are still installed until the new root's
    /// first file activates; their root-relative paths name the *old* root and must not
    /// keep, say, `node_modules/pkg` alive in the new one.
    func workspaceScanPruning(root: URL) -> WorkspaceScanPruning {
        guard !sharedWorkspaceFacades.contains(where: \.showAllFiles) else { return .none }
        let rootPrefixes = Set(Self.pathSpellings(of: root).map { $0.hasSuffix("/") ? $0 : $0 + "/" })
        func namesScannedRoot(_ authority: WorkspaceFileSystemRootAuthority) -> Bool {
            [authority.originalRootURL, authority.canonicalRootURL].contains { url in
                let path = url.standardizedFileURL.path(percentEncoded: false)
                return rootPrefixes.contains(path.hasSuffix("/") ? path : path + "/")
            }
        }
        let installedAuthority = workspaceSearchRootAuthority.flatMap { namesScannedRoot($0) ? $0 : nil }
        var retained: Set<String> = []
        for session in registry.sessions(from: [.windowDocuments, .warmCache]) {
            // Every spelling that may name the session inside this root; extra entries only
            // make the scan enumerate more.
            if let location = retainedAnchoredSessionLocation(for: session),
               namesScannedRoot(location.rootAuthority)
            {
                retained.insert(location.relativePath)
            }
            guard let fileURL = sessionStateURL(for: session) else { continue }
            if let installedAuthority, let relativePath = try? installedAuthority.relativePath(forFileURL: fileURL) {
                retained.insert(relativePath)
            }
            for filePath in Self.pathSpellings(of: fileURL) {
                for rootPrefix in rootPrefixes where filePath.hasPrefix(rootPrefix) {
                    retained.insert(String(filePath.dropFirst(rootPrefix.count)))
                }
            }
        }
        return .ignoredDirectories(retaining: retained)
    }

    /// Gives the watcher the current pruning, so a document just opened inside an ignored
    /// directory keeps receiving its external changes before the next rescan.
    func refreshWorkspaceWatcherEventFilter() {
        guard let workspaceRootURL, let workspaceWatcher else { return }
        workspaceWatcher.setEventPathFilter(WorkspaceEventPathFilter(
            rootURL: workspaceRootURL,
            pruning: workspaceScanPruning(root: workspaceRootURL)
        ))
    }

    /// `url`'s standardized and symlink-resolved paths.
    static func pathSpellings(of url: URL) -> Set<String> {
        Set([url.standardizedFileURL, url.resolvingSymlinksInPath()].map { $0.path(percentEncoded: false) })
    }

    func advanceWorkspaceGeneration() -> UInt64 {
        let facades = sharedWorkspaceFacades
        for facade in facades {
            facade.retainActiveWorkspaceSearchRefreshIntent()
            facade.invalidateWorkspaceSearchForWorkspaceGenerationAdvance()
        }
        precondition(workspaceGeneration < .max, "Workspace generation exhausted")
        workspaceGeneration += 1
        for facade in facades {
            facade.rebindPendingWorkspaceSearchUIResumeAfterGenerationAdvance()
        }
        return workspaceGeneration
    }

    func retainActiveWorkspaceSearchRefreshIntent() {
        guard let query = workspaceSearchState.activeQuery,
              let rootAuthority = workspaceSearchRootAuthority,
              workspaceSearchAuthorityMatchesCurrentRoot(rootAuthority),
              let rootURL = workspaceRootURL
        else {
            return
        }

        workspaceSearchRefreshIntent = WorkspaceSearchRefreshIntent(
            query: query,
            rootURL: rootURL,
            rootExpectation: rootAuthority.directoryMutationExpectation
        )
    }

    func workspaceReloadCurrentSessionState() -> WorkspaceReloadCurrentSessionState {
        let session = shownSession
        let sessionIdentity = ObjectIdentifier(session)
        let stateURL = sessionStateURL(for: session)
        return WorkspaceReloadCurrentSessionState(
            version: session.version,
            fileURL: session.fileURL,
            fileKind: session.fileKind,
            isDirty: session.isDirty,
            stateURL: stateURL,
            binding: anchoredSessionFileBindings[sessionIdentity],
            indeterminateWrite: indeterminateSessionWrites[sessionIdentity],
            indeterminateContext: indeterminateSessionWriteContexts[sessionIdentity],
            isDetached: stateURL.map(detachedSessionURLs.contains) ?? false,
            pendingExternalText: stateURL.flatMap { pendingExternalTexts[$0] },
            pendingExternalVersion: stateURL.flatMap { pendingExternalFileVersions[$0] },
            lastKnownDiskHash: stateURL.flatMap { lastKnownDiskHashes[$0] },
            lastKnownDiskModificationDate: stateURL.flatMap { lastKnownDiskModificationDates[$0] },
            externalChangeURL: externalChangePrompt?.fileURL,
            missingFileURL: missingFilePrompt?.fileURL
        )
    }

    func isCurrentWorkspaceReload(root: URL, generation: UInt64) -> Bool {
        !Task.isCancelled
            && workspaceGeneration == generation
            && workspaceRootURL.map { exactFileURLSpellingMatches($0, root) } == true
    }
}
