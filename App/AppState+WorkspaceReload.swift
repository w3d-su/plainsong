import Foundation
import MarkdownCore
import WorkspaceKit

struct WorkspaceSearchRefreshIntent: Equatable {
    let query: TextSearchQuery
    let rootURL: URL
    let rootExpectation: WorkspaceItemMutationExpectation
}

@MainActor
extension AppState {
    func setWorkspaceSearchQuery(_ query: TextSearchQuery) {
        guard !query.pattern.isEmpty else {
            clearWorkspaceSearch()
            return
        }

        if let refreshIntent = workspaceSearchRefreshIntent,
           !isWorkspaceSearchReady
        {
            cancelWorkspaceSearchTask()
            cancelPendingEditorNavigationIfNeeded()
            workspaceSearchRefreshIntent = WorkspaceSearchRefreshIntent(
                query: query,
                rootURL: refreshIntent.rootURL,
                rootExpectation: refreshIntent.rootExpectation
            )
            workspaceSearchState = WorkspaceSearchState(
                queryGeneration: workspaceSearchQueryGeneration
            )
            return
        }

        workspaceSearchRefreshIntent = nil
        startWorkspaceSearch(query, cancellingPendingEditorNavigation: true)
    }

    func clearWorkspaceSearch() {
        workspaceSearchRefreshIntent = nil
        cancelWorkspaceSearchTask()
        cancelPendingEditorNavigationIfNeeded()
        workspaceSearchState = WorkspaceSearchState(
            queryGeneration: workspaceSearchQueryGeneration
        )
    }

    func teardownWorkspaceSearch() {
        clearWorkspaceSearch()
        resetWorkspaceSearchUIState()
    }

    func restartActiveWorkspaceSearchWithFreshOverlays() {
        guard let query = workspaceSearchState.activeQuery else { return }
        startWorkspaceSearch(query, cancellingPendingEditorNavigation: false)
    }

    func restartActiveWorkspaceSearchAfterRelevantEdit(in session: DocumentSession) {
        guard workspaceSearchState.activeQuery != nil,
              let rootAuthority = workspaceSearchRootAuthority,
              workspaceSearchAuthorityMatchesCurrentRoot(rootAuthority),
              session === currentDocument || sessionCache.values.contains(where: { $0 === session })
        else {
            return
        }

        let sessionIdentity = ObjectIdentifier(session)
        let unanchoredWorkspaceLocation: WorkspaceFileSystemLocation? =
            if case let .proven(proof)? =
            unanchoredManagedSessionOwnershipProofs[sessionIdentity] {
                proof.installedWorkspaceLocation
            } else {
                nil
            }
        let retainedLocation = anchoredSessionFileBinding(for: session)?.location
            ?? unanchoredWorkspaceLocation
        guard retainedLocation?.rootAuthority == rootAuthority,
              let fileURL = retainedLocation?.fileURL,
              !detachedSessionURLs.contains(fileURL),
              let inferredKind = FileKind(url: fileURL),
              inferredKind == session.fileKind
        else {
            return
        }

        restartActiveWorkspaceSearchWithFreshOverlays()
    }

    func invalidateWorkspaceSearchForWorkspaceGenerationAdvance() {
        cancelWorkspaceSearchTask()
        cancelPendingEditorNavigationIfNeeded()
        workspaceSearchState = WorkspaceSearchState(
            queryGeneration: workspaceSearchQueryGeneration
        )
    }

    func scheduleWorkspaceReload(
        root: URL,
        selectFirstIfNeeded: Bool,
        errorTitle: String
    ) {
        let selectedRoot = root
        let generation = advanceWorkspaceGeneration()
        let scanner = directoryScanner
        workspaceReloadTask?.cancel()

        workspaceReloadTask = Task { @MainActor [weak self, scanner] in
            do {
                let capture = try await scanner.snapshotCapture(root: selectedRoot)
                guard let self else { return }
                try await applyWorkspaceReload(
                    root: selectedRoot,
                    capture: capture,
                    generation: generation,
                    selectFirstIfNeeded: selectFirstIfNeeded
                )
                guard isCurrentWorkspaceReload(root: selectedRoot, generation: generation) else {
                    return
                }
            } catch is CancellationError {
                // A newer reload, workspace switch, or close invalidated this scan.
            } catch {
                guard let self else { return }
                guard isCurrentWorkspaceReload(root: selectedRoot, generation: generation) else {
                    return
                }
                present(error, title: errorTitle)
            }
        }
    }

    /// Direct callers receive their own generation so a slower scan cannot apply stale state.
    func reloadWorkspaceTree(root: URL, selectFirstIfNeeded: Bool) async throws {
        let selectedRoot = root
        let generation = advanceWorkspaceGeneration()
        let capture = try await directoryScanner.snapshotCapture(root: selectedRoot)
        try await applyWorkspaceReload(
            root: selectedRoot,
            capture: capture,
            generation: generation,
            selectFirstIfNeeded: selectFirstIfNeeded
        )
    }

    func advanceWorkspaceGeneration() -> UInt64 {
        retainActiveWorkspaceSearchRefreshIntent()
        invalidateWorkspaceSearchForWorkspaceGenerationAdvance()
        precondition(workspaceGeneration < .max, "Workspace generation exhausted")
        workspaceGeneration += 1
        // Only rebind an already-pending pre-authority query; active-query reload refresh is
        // carried separately by `workspaceSearchRefreshIntent`, never inferred from UI text.
        rebindPendingWorkspaceSearchUIResumeAfterGenerationAdvance()
        return workspaceGeneration
    }

    private func retainActiveWorkspaceSearchRefreshIntent() {
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

    private func applyWorkspaceReload(
        root: URL,
        capture: WorkspaceDirectorySnapshotCapture,
        generation: UInt64,
        selectFirstIfNeeded: Bool
    ) async throws {
        try Task.checkCancellation()
        let snapshot = capture.snapshot
        try Task.checkCancellation()
        guard isCurrentWorkspaceReload(root: root, generation: generation) else {
            throw CancellationError()
        }

        // Off-main proof that the currently selected root spelling still names the captured
        // physical root. Reject stale captures rather than installing authority A while the
        // mutable selected spelling now opens B (and auto-activation would follow B).
        try await proveSelectedRootStillNamesCapture(
            selectedRoot: root,
            rootAuthority: capture.rootAuthority
        )
        try Task.checkCancellation()
        guard isCurrentWorkspaceReload(root: root, generation: generation) else {
            throw CancellationError()
        }

        let currentDocumentAtPreparation = currentDocument
        let currentDocumentStateAtPreparation = workspaceReloadCurrentSessionState()

        var tree = WorkspaceFileTree.reconcile(
            previous: workspaceTree,
            snapshot: snapshot,
            options: .init(showAllFiles: showAllFiles)
        )
        let currentDocumentDisposition = try await prepareWorkspaceReloadCurrentDocumentDisposition(
            tree: tree,
            rootAuthority: capture.rootAuthority
        )

        if selectFirstIfNeeded {
            tree.selectNode(id: firstEditableNode(in: tree.root)?.id)
        } else {
            switch currentDocumentDisposition {
            case let .present(nodeID):
                tree.selectNode(id: nodeID)
            case .missing:
                tree.selectNode(id: nil)
            case .unrelated:
                if tree.selectedNode == nil {
                    tree.selectNode(id: firstEditableNode(in: tree.root)?.id)
                }
            }
        }

        guard isCurrentWorkspaceReload(root: root, generation: generation) else {
            throw CancellationError()
        }

        let preparedFile = try await prepareWorkspaceReloadFile(
            selectedNode: tree.selectedNode,
            rootAuthority: capture.rootAuthority,
            selectedRoot: root,
            generation: generation
        )
        try workspaceReloadPostPrepareHook?()

        // The activation load may suspend. Re-prove the selected spelling immediately before
        // the uninterrupted App-state commit so a root moved/replaced during that load is
        // rejected instead of publishing capture A under a spelling that now names B.
        try await proveSelectedRootStillNamesCapture(
            selectedRoot: root,
            rootAuthority: capture.rootAuthority
        )

        guard isCurrentWorkspaceReload(root: root, generation: generation) else {
            throw CancellationError()
        }
        guard currentDocument === currentDocumentAtPreparation,
              workspaceReloadCurrentSessionState() == currentDocumentStateAtPreparation
        else {
            // User/session lifecycle work won the suspension. Do not apply a tree selection,
            // missing-file disposition, or activation prepared for the superseded document.
            throw CancellationError()
        }

        // Cache and retirement state can change while the final root proof suspends. Re-derive the
        // activation source now, then commit it without another suspension so a stale cached or
        // retired source can neither be resurrected nor trip a commit precondition.
        let preparedActivation = try preparedFile.map { preparedFile in
            try prepareAnchoredFileSessionActivation(
                file: preparedFile.file,
                at: preparedFile.location,
                metadata: preparedFile.metadata,
                sha256Digest: preparedFile.sha256Digest,
                preparedImageAssetAuthority: preparedFile.preparedImageAssetAuthority
            )
        }

        // Every throwing filesystem and cache validation is complete. From here through capture
        // installation there is no suspension or throwing operation, so activation and the
        // snapshot/authority/tree become visible as one main-actor transaction.
        if case let .missing(session, key) = currentDocumentDisposition {
            markSessionDetachedFromMissingFile(session, url: key)
        }
        if let preparedActivation {
            commitAnchoredFileSessionActivation(preparedActivation)
        }
        let previousSnapshot = workspaceSnapshot
        workspaceSnapshot = snapshot
        workspaceSearchRootAuthority = capture.rootAuthority
        workspaceInstalledCaptureGeneration = generation
        refreshEditorImageThumbnails(
            previousSnapshot: previousSnapshot,
            currentSnapshot: snapshot
        )
        workspaceTree = tree
        scheduleCompletionWorkspaceRefresh(workspaceGeneration: generation)
        // A newer explicit pre-authority query is resumed first and clears any older retained
        // refresh intent. A merely non-empty inactive field has neither mechanism and stays idle.
        resumePendingWorkspaceSearchFromUIIfNeeded()
        resumeWorkspaceSearchRefreshIntentIfNeeded(
            installedRootAuthority: capture.rootAuthority
        )
    }

    private func resumeWorkspaceSearchRefreshIntentIfNeeded(
        installedRootAuthority: WorkspaceFileSystemRootAuthority
    ) {
        guard let intent = workspaceSearchRefreshIntent else { return }
        guard exactFileURLSpellingMatches(intent.rootURL, installedRootAuthority.originalRootURL),
              intent.rootExpectation == installedRootAuthority.directoryMutationExpectation,
              workspaceSearchAuthorityMatchesCurrentRoot(installedRootAuthority)
        else {
            workspaceSearchRefreshIntent = nil
            return
        }

        workspaceSearchRefreshIntent = nil
        startWorkspaceSearch(intent.query, cancellingPendingEditorNavigation: false)
    }

    private func prepareWorkspaceReloadFile(
        selectedNode: WorkspaceFileNode?,
        rootAuthority: WorkspaceFileSystemRootAuthority,
        selectedRoot: URL,
        generation: UInt64
    ) async throws -> PreparedWorkspaceReloadFile? {
        guard let selectedNode, selectedNode.isEditableMarkdown else { return nil }

        // This is the exact post-proof/pre-activation boundary. The production hook is nil;
        // tests replace the selected spelling here to prove the anchored activation fails
        // without installing any part of this capture.
        try workspaceReloadPostProofHook?()
        try Task.checkCancellation()
        guard isCurrentWorkspaceReload(root: selectedRoot, generation: generation) else {
            throw CancellationError()
        }

        // Activation paths use the captured authority's canonical spelling, never a retargeted
        // selected symlink that slipped past a failed proof. The candidate URL is built through
        // `location(relativePath:)`, never `appendingPathComponent`, which silently decomposes
        // precomposed Unicode (NFC) in the leaf into decomposed form (NFD) via CoreFoundation's
        // file-system-representation bridging before `canonicalizedLocation` ever sees it.
        let preparedFile = try await prepareAnchoredWorkspaceReloadFile(
            rootAuthority: rootAuthority,
            candidateURL: rootAuthority.location(
                relativePath: selectedNode.relativePath
            ).fileURL
        )
        try workspaceReloadPostLoadHook?()
        try Task.checkCancellation()
        guard isCurrentWorkspaceReload(root: selectedRoot, generation: generation) else {
            throw CancellationError()
        }
        return preparedFile
    }

    private func prepareWorkspaceReloadCurrentDocumentDisposition(
        tree: WorkspaceFileTree,
        rootAuthority: WorkspaceFileSystemRootAuthority
    ) async throws -> PreparedWorkspaceReloadCurrentDocumentDisposition {
        let session = currentDocument
        guard let fileURL = sessionStateURL(for: session) else {
            return .unrelated
        }

        let unanchoredWorkspaceLocation: WorkspaceFileSystemLocation? =
            if case let .proven(proof)? = unanchoredManagedSessionOwnershipProofs[
                ObjectIdentifier(session)
            ] {
                proof.installedWorkspaceLocation
            } else {
                nil
            }
        let retainedLocation = retainedAnchoredSessionLocation(for: session)
            ?? unanchoredWorkspaceLocation
        if let retainedLocation, retainedLocation.rootAuthority != rootAuthority {
            // A workspace-to-workspace switch deliberately retains the outgoing editor
            // session until its view is dismantled. If that exact A location is outside B,
            // it is unrelated to B's first snapshot and must not block selecting B's first
            // editable file. A lexical collision inside B remains fail-closed: only the
            // retained A authority may authorize I/O for that session URL.
            guard (try? rootAuthority.relativePath(
                forFileURL: retainedLocation.fileURL
            )) != nil else {
                return .unrelated
            }
            throw AppStateError.invalidSessionIdentity(fileURL)
        }
        let lexicalRelativePath: String
        if let retainedLocation {
            lexicalRelativePath = retainedLocation.relativePath
        } else {
            guard let relativePath = try? rootAuthority.relativePath(forFileURL: fileURL) else {
                return .unrelated
            }
            lexicalRelativePath = relativePath
        }
        let key = retainedLocation?.fileURL ?? fileURL
        let currentLocation = retainedLocation?.rootAuthority == rootAuthority
            ? retainedLocation
            : try rootAuthority.location(relativePath: lexicalRelativePath)

        if let exactNode = firstNode(in: tree.root, relativePath: lexicalRelativePath),
           exactNode.isEditableMarkdown
        {
            return .present(nodeID: exactNode.id)
        }

        let editableNodes = editableWorkspaceNodes(in: tree.root)
        let canonicalRelativePath = retainedLocation?.rootAuthority == rootAuthority
            ? retainedLocation?.relativePath
            : nil
        let matchingNodeID = await Task.detached(priority: .utility) { () -> WorkspaceFileNode.ID? in
            let targetRelativePath = canonicalRelativePath
                ?? (try? rootAuthority.canonicalizedLocation(forFileURL: fileURL).relativePath)
                ?? lexicalRelativePath
            for node in editableNodes {
                // Built through `location(relativePath:)`, never `appendingPathComponent`,
                // which silently decomposes precomposed Unicode (NFC) in `node.relativePath`
                // into decomposed form (NFD) before `canonicalizedLocation` ever sees it.
                guard
                    let candidateURL = try? rootAuthority.location(
                        relativePath: node.relativePath
                    ).fileURL,
                    let location = try? rootAuthority.canonicalizedLocation(
                        forFileURL: candidateURL
                    )
                else {
                    continue
                }
                if ExactSourceText.matches(location.relativePath, targetRelativePath) {
                    return node.id
                }
            }
            return nil
        }.value

        if let matchingNodeID {
            return .present(nodeID: matchingNodeID)
        }
        guard let currentLocation else {
            return .unrelated
        }
        let status = await Task.detached(priority: .utility) {
            WorkspaceNoFollowFileInspector.status(at: currentLocation)
        }.value
        switch status {
        case .missing:
            return .missing(session: session, key: key)
        case .regular:
            // Enumeration may legitimately skip an unreadable entry. Absence from the
            // snapshot alone is not proof that the current file disappeared.
            return .unrelated
        case .symbolicLink:
            throw WorkspaceAnchoredFileSystemError.symbolicLink
        case .notRegularFile:
            throw WorkspaceAnchoredFileSystemError.notRegularFile
        case .unreadable:
            throw WorkspaceAnchoredFileSystemError.unreadable
        }
    }

    private func editableWorkspaceNodes(in root: WorkspaceFileNode) -> [WorkspaceFileNode] {
        var result: [WorkspaceFileNode] = []
        if root.isEditableMarkdown {
            result.append(root)
        }
        for child in root.children {
            result.append(contentsOf: editableWorkspaceNodes(in: child))
        }
        return result
    }

    private func workspaceReloadCurrentSessionState() -> WorkspaceReloadCurrentSessionState {
        let session = currentDocument
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

    private func isCurrentWorkspaceReload(root: URL, generation: UInt64) -> Bool {
        !Task.isCancelled
            && workspaceGeneration == generation
            && workspaceRootURL.map { exactFileURLSpellingMatches($0, root) } == true
    }
}

private enum PreparedWorkspaceReloadCurrentDocumentDisposition {
    case present(nodeID: WorkspaceFileNode.ID)
    case missing(session: DocumentSession, key: URL)
    case unrelated
}

private struct WorkspaceReloadCurrentSessionState: Equatable {
    let version: Int
    let fileURL: URL?
    let fileKind: FileKind
    let isDirty: Bool
    let stateURL: URL?
    let binding: AnchoredWorkspaceSessionFileBinding?
    let indeterminateWrite: WorkspaceIndeterminateFileWrite?
    let indeterminateContext: IndeterminateSessionWriteContext?
    let isDetached: Bool
    let pendingExternalText: String?
    let pendingExternalVersion: ObservedRetainedFileVersion?
    let lastKnownDiskHash: String?
    let lastKnownDiskModificationDate: Date?
    let externalChangeURL: URL?
    let missingFileURL: URL?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version
            && exactPathMatches(lhs.fileURL, rhs.fileURL)
            && lhs.fileKind == rhs.fileKind
            && lhs.isDirty == rhs.isDirty
            && exactPathMatches(lhs.stateURL, rhs.stateURL)
            && lhs.binding == rhs.binding
            && lhs.indeterminateWrite == rhs.indeterminateWrite
            && lhs.indeterminateContext == rhs.indeterminateContext
            && lhs.isDetached == rhs.isDetached
            && exactTextMatches(lhs.pendingExternalText, rhs.pendingExternalText)
            && lhs.pendingExternalVersion == rhs.pendingExternalVersion
            && lhs.lastKnownDiskHash == rhs.lastKnownDiskHash
            && lhs.lastKnownDiskModificationDate == rhs.lastKnownDiskModificationDate
            && exactPathMatches(lhs.externalChangeURL, rhs.externalChangeURL)
            && exactPathMatches(lhs.missingFileURL, rhs.missingFileURL)
    }

    private static func exactPathMatches(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        guard lhs.isFileURL, rhs.isFileURL else { return false }
        return lhs.path(percentEncoded: false).utf8.elementsEqual(
            rhs.path(percentEncoded: false).utf8
        )
    }

    private static func exactTextMatches(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            ExactSourceText.matches(lhs, rhs)
        case (nil, nil):
            true
        default:
            false
        }
    }
}

@MainActor
extension AppState {
    func startWorkspaceSearch(
        _ query: TextSearchQuery,
        cancellingPendingEditorNavigation: Bool
    ) {
        cancelWorkspaceSearchTask()
        if cancellingPendingEditorNavigation {
            cancelPendingEditorNavigationIfNeeded()
        }

        guard workspaceSnapshot != nil,
              let rootAuthority = workspaceSearchRootAuthority,
              workspaceSearchAuthorityMatchesCurrentRoot(rootAuthority)
        else {
            workspaceSearchState = WorkspaceSearchState(
                queryGeneration: workspaceSearchQueryGeneration
            )
            return
        }

        let context = beginWorkspaceSearch(query: query, rootAuthority: rootAuthority)
        installWorkspaceSearchTask(query: query, context: context)
    }

    func beginWorkspaceSearch(
        query: TextSearchQuery,
        rootAuthority: WorkspaceFileSystemRootAuthority
    ) -> WorkspaceSearchContext {
        let queryGeneration = advanceWorkspaceSearchQueryGeneration()
        let context = WorkspaceSearchContext(
            rootIdentity: Self.workspaceSearchRootIdentity(for: rootAuthority),
            workspaceGeneration: workspaceGeneration,
            queryGeneration: queryGeneration
        )
        workspaceSearchState = WorkspaceSearchState(
            activeQuery: query,
            queryGeneration: queryGeneration,
            activeContext: context,
            phase: .debouncing
        )
        return context
    }

    func installWorkspaceSearchTask(
        query: TextSearchQuery,
        context: WorkspaceSearchContext
    ) {
        let taskToken = UUID()
        workspaceSearchTaskToken = taskToken
        let debounceNanoseconds = workspaceSearchDebounceNanoseconds
        let provider = workspaceSearchStreamProvider

        workspaceSearchTask = Task { @MainActor [weak self] in
            guard await Self.waitForWorkspaceSearchDebounce(debounceNanoseconds) else {
                self?.finishWorkspaceSearchTask(
                    token: taskToken,
                    context: context,
                    wasCancelled: true
                )
                return
            }

            guard !Task.isCancelled,
                  let rootAuthority = self?.workspaceSearchRootAuthority,
                  self?.workspaceSearchAuthorityMatchesCurrentRoot(rootAuthority) == true
            else {
                self?.finishWorkspaceSearchTask(
                    token: taskToken,
                    context: context,
                    wasCancelled: Task.isCancelled
                )
                return
            }

            let dirtyOverlays: WorkspaceSearchOverlayCollection
            do {
                guard let overlays = try await self?.workspaceSearchDirtyOverlays(
                    rootAuthority: rootAuthority
                ) else {
                    throw CancellationError()
                }
                dirtyOverlays = overlays
            } catch {
                self?.failWorkspaceSearchPreparation(
                    context: context,
                    taskToken: taskToken,
                    wasCancelled: Task.isCancelled || error is CancellationError
                )
                return
            }

            guard !Task.isCancelled,
                  let request = self?.prepareWorkspaceSearchRequest(
                      query: query,
                      context: context,
                      taskToken: taskToken,
                      rootAuthority: rootAuthority,
                      dirtyOverlays: dirtyOverlays
                  )
            else {
                self?.finishWorkspaceSearchTask(
                    token: taskToken,
                    context: context,
                    wasCancelled: Task.isCancelled
                )
                return
            }

            for await event in provider.events(for: request) {
                guard !Task.isCancelled else { break }
                self?.applyWorkspaceSearchEvent(
                    event,
                    expectedContext: context,
                    taskToken: taskToken
                )
            }

            self?.finishWorkspaceSearchTask(
                token: taskToken,
                context: context,
                wasCancelled: Task.isCancelled
            )
        }
    }

    static func waitForWorkspaceSearchDebounce(_ nanoseconds: UInt64) async -> Bool {
        guard nanoseconds > 0 else { return !Task.isCancelled }
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    func prepareWorkspaceSearchRequest(
        query: TextSearchQuery,
        context: WorkspaceSearchContext,
        taskToken: UUID,
        rootAuthority: WorkspaceFileSystemRootAuthority,
        dirtyOverlays: WorkspaceSearchOverlayCollection
    ) -> WorkspaceSearchRequest? {
        guard workspaceSearchTaskToken == taskToken,
              workspaceSearchQueriesMatch(workspaceSearchState.activeQuery, query),
              workspaceSearchContextsMatch(workspaceSearchState.activeContext, context),
              isActiveWorkspaceSearchContext(context),
              workspaceSearchState.phase == .debouncing,
              workspaceSearchRootAuthority == rootAuthority,
              workspaceSearchAuthorityMatchesCurrentRoot(rootAuthority),
              let snapshot = workspaceSnapshot
        else {
            return nil
        }

        workspaceSearchState.phase = .searching
        return WorkspaceSearchRequest(
            rootAuthority: rootAuthority,
            rootIdentity: context.rootIdentity,
            snapshot: snapshot,
            workspaceGeneration: context.workspaceGeneration,
            queryGeneration: context.queryGeneration,
            query: query,
            dirtyOverlays: dirtyOverlays,
            limits: workspaceSearchLimits
        )
    }

    func failWorkspaceSearchPreparation(
        context: WorkspaceSearchContext,
        taskToken: UUID,
        wasCancelled: Bool
    ) {
        guard workspaceSearchTaskToken == taskToken,
              workspaceSearchContextsMatch(workspaceSearchState.activeContext, context)
        else {
            return
        }
        if !wasCancelled, workspaceSearchState.phase == .debouncing {
            workspaceSearchState.phase = .serviceFailure(.unexpectedProducerFailure)
        }
        finishWorkspaceSearchTask(
            token: taskToken,
            context: context,
            wasCancelled: wasCancelled
        )
    }

    func finishWorkspaceSearchTask(
        token: UUID,
        context: WorkspaceSearchContext,
        wasCancelled: Bool
    ) {
        guard workspaceSearchTaskToken == token,
              workspaceSearchContextsMatch(workspaceSearchState.activeContext, context)
        else {
            return
        }

        workspaceSearchTask = nil
        workspaceSearchTaskToken = nil
        if !wasCancelled,
           workspaceSearchState.phase == .searching || workspaceSearchState.phase == .debouncing
        {
            workspaceSearchState.phase = .serviceFailure(.unexpectedProducerFailure)
        }
    }

    func cancelWorkspaceSearchTask() {
        workspaceSearchTask?.cancel()
        workspaceSearchTask = nil
        workspaceSearchTaskToken = nil
    }

    func advanceWorkspaceSearchQueryGeneration() -> UInt64 {
        precondition(workspaceSearchQueryGeneration < .max, "Workspace search query generation exhausted")
        workspaceSearchQueryGeneration += 1
        return workspaceSearchQueryGeneration
    }

    func isActiveWorkspaceSearchContext(_ context: WorkspaceSearchContext) -> Bool {
        guard let rootAuthority = workspaceSearchRootAuthority,
              workspaceSearchAuthorityMatchesCurrentRoot(rootAuthority),
              workspaceSearchContextsMatch(workspaceSearchState.activeContext, context),
              workspaceSearchState.queryGeneration == context.queryGeneration,
              workspaceGeneration == context.workspaceGeneration,
              ExactSourceText.matches(
                  Self.workspaceSearchRootIdentity(for: rootAuthority),
                  context.rootIdentity
              )
        else {
            return false
        }

        return true
    }

    func workspaceSearchContextsMatch(
        _ first: WorkspaceSearchContext?,
        _ second: WorkspaceSearchContext
    ) -> Bool {
        guard let first else { return false }
        return ExactSourceText.matches(first.rootIdentity, second.rootIdentity)
            && first.workspaceGeneration == second.workspaceGeneration
            && first.queryGeneration == second.queryGeneration
    }

    func workspaceSearchQueriesMatch(
        _ first: TextSearchQuery?,
        _ second: TextSearchQuery
    ) -> Bool {
        guard let first else { return false }
        return ExactSourceText.matches(first.pattern, second.pattern)
            && first.caseSensitivity == second.caseSensitivity
            && first.wholeWord == second.wholeWord
    }

    static func workspaceSearchRootIdentity(
        for rootAuthority: WorkspaceFileSystemRootAuthority
    ) -> String {
        rootAuthority.canonicalRootURL.path(percentEncoded: false)
    }

    func workspaceSearchAuthorityMatchesCurrentRoot(
        _ rootAuthority: WorkspaceFileSystemRootAuthority
    ) -> Bool {
        workspaceRootURL.map {
            exactFileURLSpellingMatches($0, rootAuthority.originalRootURL)
        } == true
            && workspaceInstalledCaptureGeneration == workspaceGeneration
            && workspaceSearchRootAuthority == rootAuthority
    }
}
