import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    func setWorkspaceSearchQuery(_ query: TextSearchQuery) {
        guard !query.pattern.isEmpty else {
            clearWorkspaceSearch()
            return
        }

        startWorkspaceSearch(query, cancellingPendingEditorNavigation: true)
    }

    func clearWorkspaceSearch() {
        cancelWorkspaceSearchTask()
        cancelPendingEditorNavigationIfNeeded()
        workspaceSearchState = WorkspaceSearchState(
            queryGeneration: workspaceSearchQueryGeneration
        )
    }

    func teardownWorkspaceSearch() {
        clearWorkspaceSearch()
    }

    func restartActiveWorkspaceSearchWithFreshOverlays() {
        guard let query = workspaceSearchState.activeQuery else { return }
        startWorkspaceSearch(query, cancellingPendingEditorNavigation: false)
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
        errorTitle: String,
        handlesExternalChanges: Bool = false
    ) {
        let normalizedRoot = root.standardizedFileURL
        let generation = advanceWorkspaceGeneration()
        workspaceReloadTask?.cancel()

        workspaceReloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await applyWorkspaceReload(
                    root: normalizedRoot,
                    generation: generation,
                    selectFirstIfNeeded: selectFirstIfNeeded
                )
                guard isCurrentWorkspaceReload(root: normalizedRoot, generation: generation) else {
                    return
                }
                if handlesExternalChanges {
                    handleCurrentDocumentExternalChange()
                }
            } catch is CancellationError {
                // A newer reload, workspace switch, or close invalidated this scan.
            } catch {
                guard isCurrentWorkspaceReload(root: normalizedRoot, generation: generation) else {
                    return
                }
                present(error, title: errorTitle)
            }
        }
    }

    /// Direct callers receive their own generation so a slower scan cannot apply stale state.
    func reloadWorkspaceTree(root: URL, selectFirstIfNeeded: Bool) async throws {
        let normalizedRoot = root.standardizedFileURL
        let generation = advanceWorkspaceGeneration()
        try await applyWorkspaceReload(
            root: normalizedRoot,
            generation: generation,
            selectFirstIfNeeded: selectFirstIfNeeded
        )
    }

    func advanceWorkspaceGeneration() -> UInt64 {
        invalidateWorkspaceSearchForWorkspaceGenerationAdvance()
        precondition(workspaceGeneration < .max, "Workspace generation exhausted")
        workspaceGeneration += 1
        return workspaceGeneration
    }

    private func applyWorkspaceReload(
        root: URL,
        generation: UInt64,
        selectFirstIfNeeded: Bool
    ) async throws {
        try Task.checkCancellation()
        let snapshot = try await directoryScanner.snapshot(root: root)
        try Task.checkCancellation()
        guard isCurrentWorkspaceReload(root: root, generation: generation) else {
            throw CancellationError()
        }

        var tree = WorkspaceFileTree.reconcile(
            previous: workspaceTree,
            snapshot: snapshot,
            options: .init(showAllFiles: showAllFiles)
        )

        if !selectFirstIfNeeded,
           let currentDocumentNode = nodeForCurrentDocument(in: tree, root: root)
        {
            tree.selectNode(id: currentDocumentNode.id)
        } else if tree.selectedNode == nil || selectFirstIfNeeded {
            tree.selectNode(id: firstEditableNode(in: tree.root)?.id)
        }

        guard isCurrentWorkspaceReload(root: root, generation: generation) else {
            throw CancellationError()
        }
        workspaceSnapshot = snapshot
        workspaceTree = tree
        scheduleCompletionWorkspaceRefresh(workspaceGeneration: generation)

        if let selectedNode = tree.selectedNode, selectedNode.isEditableMarkdown {
            try activateFileSession(
                url: root.appendingPathComponent(selectedNode.relativePath, isDirectory: false)
            )
        }
    }

    private func isCurrentWorkspaceReload(root: URL, generation: UInt64) -> Bool {
        !Task.isCancelled
            && workspaceGeneration == generation
            && workspaceRootURL?.standardizedFileURL == root.standardizedFileURL
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

        guard let rootURL = workspaceRootURL?.standardizedFileURL,
              workspaceSnapshot != nil
        else {
            workspaceSearchState = WorkspaceSearchState(
                queryGeneration: workspaceSearchQueryGeneration
            )
            return
        }

        let context = beginWorkspaceSearch(query: query, rootURL: rootURL)
        installWorkspaceSearchTask(query: query, context: context)
    }

    func beginWorkspaceSearch(
        query: TextSearchQuery,
        rootURL: URL
    ) -> WorkspaceSearchContext {
        let queryGeneration = advanceWorkspaceSearchQueryGeneration()
        let context = WorkspaceSearchContext(
            rootIdentity: Self.workspaceSearchRootIdentity(for: rootURL),
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
                  let request = self?.prepareWorkspaceSearchRequest(
                      query: query,
                      context: context,
                      taskToken: taskToken
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
        taskToken: UUID
    ) -> WorkspaceSearchRequest? {
        guard workspaceSearchTaskToken == taskToken,
              workspaceSearchQueriesMatch(workspaceSearchState.activeQuery, query),
              workspaceSearchContextsMatch(workspaceSearchState.activeContext, context),
              isActiveWorkspaceSearchContext(context),
              workspaceSearchState.phase == .debouncing,
              let rootURL = workspaceRootURL?.standardizedFileURL,
              let snapshot = workspaceSnapshot
        else {
            return nil
        }

        do {
            let dirtyOverlays = try workspaceSearchDirtyOverlays(rootURL: rootURL)
            workspaceSearchState.phase = .searching
            return WorkspaceSearchRequest(
                rootURL: rootURL,
                rootIdentity: context.rootIdentity,
                snapshot: snapshot,
                workspaceGeneration: context.workspaceGeneration,
                queryGeneration: context.queryGeneration,
                query: query,
                dirtyOverlays: dirtyOverlays,
                limits: workspaceSearchLimits
            )
        } catch {
            workspaceSearchState.phase = .serviceFailure(.unexpectedProducerFailure)
            return nil
        }
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
        guard let rootURL = workspaceRootURL?.standardizedFileURL,
              workspaceSearchContextsMatch(workspaceSearchState.activeContext, context),
              workspaceSearchState.queryGeneration == context.queryGeneration,
              workspaceGeneration == context.workspaceGeneration,
              ExactSourceText.matches(
                  Self.workspaceSearchRootIdentity(for: rootURL),
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

    static func workspaceSearchRootIdentity(for rootURL: URL) -> String {
        rootURL.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }
}
