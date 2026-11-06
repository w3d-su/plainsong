import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
protocol WorkspaceSearchStreamProviding {
    func events(for request: WorkspaceSearchRequest) -> AsyncStream<WorkspaceSearchEvent>
}

extension WorkspaceSearchService: WorkspaceSearchStreamProviding {}

struct WorkspaceSearchState: Equatable {
    enum Phase: Equatable {
        case idle
        case debouncing
        case searching
        case completed
        case validationFailure(WorkspaceSearchValidationError)
        case serviceFailure(WorkspaceSearchServiceFailure)
    }

    var activeQuery: TextSearchQuery?
    var queryGeneration: UInt64
    var activeContext: WorkspaceSearchContext?
    var phase: Phase
    var fileResults: [WorkspaceSearchFileResult]
    var skippedFiles: [WorkspaceSearchSkippedFile]
    var progress: WorkspaceSearchProgress?
    var summary: WorkspaceSearchSummary?

    init(
        activeQuery: TextSearchQuery? = nil,
        queryGeneration: UInt64 = 0,
        activeContext: WorkspaceSearchContext? = nil,
        phase: Phase = .idle,
        fileResults: [WorkspaceSearchFileResult] = [],
        skippedFiles: [WorkspaceSearchSkippedFile] = [],
        progress: WorkspaceSearchProgress? = nil,
        summary: WorkspaceSearchSummary? = nil
    ) {
        self.activeQuery = activeQuery
        self.queryGeneration = queryGeneration
        self.activeContext = activeContext
        self.phase = phase
        self.fileResults = fileResults
        self.skippedFiles = skippedFiles
        self.progress = progress
        self.summary = summary
    }

    var isTruncated: Bool {
        summary?.isTruncated == true || fileResults.contains(where: \.isTruncated)
    }

    var isGloballyTruncated: Bool {
        summary?.isGloballyTruncated == true
    }

    var truncatedFilePaths: [String] {
        summary?.truncatedFilePaths ?? fileResults.filter(\.isTruncated).map(\.relativePath)
    }
}

private struct WorkspaceSearchDirtyOverlayInput {
    let fileURL: URL
    let fileKind: FileKind
    let text: String
}

@MainActor
extension AppState {
    /// Refreshes completion metadata. Paths and sibling frontmatter keys are read once per
    /// installed capture and current file; a typing pause recomputes only heading anchors and
    /// MDX component names, and republishes only when the result literally changed.
    func scheduleCompletionWorkspaceRefresh(
        debounceNanoseconds: UInt64 = 0,
        workspaceGeneration expectedWorkspaceGeneration: UInt64? = nil
    ) {
        completionWorkspaceTask?.cancel()

        let snapshot = workspaceSnapshot
        let rootAuthority = workspaceSearchRootAuthority
        let captureGeneration = workspaceInstalledCaptureGeneration
        let workspaceGeneration = expectedWorkspaceGeneration ?? workspaceGeneration
        let fileURL = shownSession.fileURL
        let text = shownSession.text
        let currentFileLocation = completionCurrentFileLocation(rootAuthority: rootAuthority)
        let baseLookup = completionWorkspaceBaseLookup(
            captureGeneration: captureGeneration,
            currentFileLocation: currentFileLocation
        )

        completionWorkspaceTask = Task { @MainActor [weak self] in
            if debounceNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: debounceNanoseconds)
                } catch {
                    return
                }
            }

            let (workspace, computedBase) = await Task.detached(priority: .utility) {
                CompletionWorkspaceRefresh.workspace(
                    currentFileLocation: currentFileLocation,
                    snapshot: snapshot,
                    fileURL: fileURL,
                    text: text,
                    baseLookup: baseLookup
                )
            }.value

            guard let self,
                  !Task.isCancelled,
                  self.workspaceGeneration == workspaceGeneration,
                  rootAuthority == nil || (
                      workspaceInstalledCaptureGeneration == workspaceGeneration
                          && workspaceSearchRootAuthority == rootAuthority
                  )
            else {
                return
            }
            if case let .computed(base) = computedBase,
               let captureGeneration,
               let currentFileLocation,
               workspaceInstalledCaptureGeneration == captureGeneration
            {
                completionWorkspaceBaseCache = CompletionWorkspaceBaseCache(
                    captureGeneration: captureGeneration,
                    currentFileLocation: currentFileLocation,
                    base: base
                )
            }
            // An unchanged value must not publish: every AppState observer re-renders.
            guard !completionWorkspace.isLiterallyIdentical(to: workspace) else { return }
            completionWorkspace = workspace
        }
    }

    private func completionCurrentFileLocation(
        rootAuthority: WorkspaceFileSystemRootAuthority?
    ) -> WorkspaceFileSystemLocation? {
        if let retainedLocation = retainedAnchoredSessionLocation(for: shownSession) {
            guard retainedLocation.rootAuthority == rootAuthority else { return nil }
            return retainedLocation
        }
        guard let rootAuthority, let fileURL = shownSession.fileURL,
              let relativePath = try? rootAuthority.relativePath(forFileURL: fileURL)
        else {
            return nil
        }
        return try? rootAuthority.location(relativePath: relativePath)
    }

    private func completionWorkspaceBaseLookup(
        captureGeneration: UInt64?,
        currentFileLocation: WorkspaceFileSystemLocation?
    ) -> CompletionWorkspaceBaseLookup {
        guard let cache = completionWorkspaceBaseCache,
              let captureGeneration,
              let currentFileLocation,
              cache.captureGeneration == captureGeneration,
              cache.currentFileLocation == currentFileLocation
        else {
            return .uncached
        }
        return .cached(cache.base)
    }

    func workspaceSearchDirtyOverlays(
        rootAuthority: WorkspaceFileSystemRootAuthority
    ) async throws -> WorkspaceSearchOverlayCollection {
        let cachedSessions = registry.warmSessionEntries
            .sorted { first, second in
                Self.workspaceSearchPathLessThan(
                    first.url.absoluteString,
                    second.url.absoluteString
                )
            }
            .map(\.session)
        let candidateSessions = registry.sessions(from: [.windowDocuments]) + cachedSessions
        var seenSessions: Set<ObjectIdentifier> = []
        var inputs: [WorkspaceSearchDirtyOverlayInput] = []

        for session in candidateSessions where session.isDirty {
            let sessionIdentity = ObjectIdentifier(session)
            let anchoredBinding = anchoredSessionFileBinding(for: session)
            let unanchoredWorkspaceLocation: WorkspaceFileSystemLocation? =
                if case let .proven(proof)? =
                unanchoredManagedSessionOwnershipProofs[sessionIdentity] {
                    proof.installedWorkspaceLocation
                } else {
                    nil
                }
            let retainedLocation = anchoredBinding?.location ?? unanchoredWorkspaceLocation
            guard seenSessions.insert(sessionIdentity).inserted,
                  retainedLocation?.rootAuthority == rootAuthority,
                  let fileURL = retainedLocation?.fileURL,
                  !detachedSessionURLs.contains(fileURL),
                  let inferredKind = FileKind(url: fileURL),
                  inferredKind == session.fileKind
            else {
                continue
            }

            inputs.append(WorkspaceSearchDirtyOverlayInput(
                fileURL: fileURL,
                fileKind: session.fileKind,
                text: session.text
            ))
        }

        return try await withThrowingTaskGroup(
            of: WorkspaceSearchOverlayCollection.self
        ) { group in
            group.addTask(priority: .utility) {
                var seenRelativePaths: [String] = []
                var overlays: [WorkspaceSearchOverlay] = []

                for input in inputs {
                    try Task.checkCancellation()
                    guard let location = try? rootAuthority.canonicalizedLocation(
                        forFileURL: input.fileURL
                    ),
                        FileKind(url: location.fileURL) == input.fileKind,
                        !seenRelativePaths.contains(where: {
                            ExactSourceText.matches($0, location.relativePath)
                        })
                    else {
                        continue
                    }

                    seenRelativePaths.append(location.relativePath)
                    try overlays.append(WorkspaceSearchOverlay(
                        relativePath: location.relativePath,
                        text: input.text
                    ))
                }

                return try WorkspaceSearchOverlayCollection(overlays)
            }
            defer { group.cancelAll() }
            guard let overlays = try await group.next() else {
                throw CancellationError()
            }
            return overlays
        }
    }

    func applyWorkspaceSearchEvent(
        _ event: WorkspaceSearchEvent,
        expectedContext: WorkspaceSearchContext,
        taskToken: UUID
    ) {
        guard workspaceSearchTaskToken == taskToken,
              workspaceSearchContextsMatch(event.context, expectedContext),
              isActiveWorkspaceSearchContext(event.context),
              workspaceSearchState.phase == .searching
        else {
            return
        }

        switch event {
        case let .fileResult(_, result):
            applyWorkspaceSearchFileResult(result)
        case let .skippedFile(_, skippedFile):
            applyWorkspaceSearchSkippedFile(skippedFile)
        case let .progress(_, progress):
            workspaceSearchState.progress = progress
        case let .completed(_, summary):
            workspaceSearchState.summary = summary
            workspaceSearchState.skippedFiles = summary.skippedFiles.sorted {
                Self.workspaceSearchPathLessThan($0.relativePath, $1.relativePath)
            }
            workspaceSearchState.phase = .completed
        case let .failed(_, failure):
            workspaceSearchState.phase = .serviceFailure(failure)
        case let .validationFailure(_, validationError):
            workspaceSearchState.phase = .validationFailure(validationError)
        }
    }

    /// `fileResults` stays sorted by path, so a result is placed by binary search instead of
    /// a linear lookup plus a full re-sort per event (quadratic over a large result set).
    func applyWorkspaceSearchFileResult(_ result: WorkspaceSearchFileResult) {
        let results = workspaceSearchState.fileResults
        var lower = 0
        var upper = results.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if Self.workspaceSearchPathLessThan(results[middle].relativePath, result.relativePath) {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        var index = lower
        while index < results.count,
              !Self.workspaceSearchPathLessThan(result.relativePath, results[index].relativePath)
        {
            if ExactSourceText.matches(results[index].relativePath, result.relativePath) {
                workspaceSearchState.fileResults[index] = result
                return
            }
            index += 1
        }
        workspaceSearchState.fileResults.insert(result, at: lower)
    }

    func applyWorkspaceSearchSkippedFile(_ skippedFile: WorkspaceSearchSkippedFile) {
        if let existingIndex = workspaceSearchState.skippedFiles.firstIndex(where: {
            ExactSourceText.matches($0.relativePath, skippedFile.relativePath)
        }) {
            workspaceSearchState.skippedFiles[existingIndex] = skippedFile
        } else {
            workspaceSearchState.skippedFiles.append(skippedFile)
        }
        workspaceSearchState.skippedFiles.sort {
            Self.workspaceSearchPathLessThan($0.relativePath, $1.relativePath)
        }
    }

    static func workspaceSearchPathLessThan(_ first: String, _ second: String) -> Bool {
        first.utf8.lexicographicallyPrecedes(second.utf8)
    }
}

private extension WorkspaceSearchEvent {
    var context: WorkspaceSearchContext {
        switch self {
        case let .fileResult(context, _),
             let .skippedFile(context, _),
             let .progress(context, _),
             let .completed(context, _),
             let .failed(context, _),
             let .validationFailure(context, _):
            context
        }
    }
}
