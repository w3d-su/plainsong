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
    func scheduleCompletionWorkspaceRefresh(
        debounceNanoseconds: UInt64 = 0,
        workspaceGeneration expectedWorkspaceGeneration: UInt64? = nil
    ) {
        completionWorkspaceTask?.cancel()

        let rootURL = workspaceRootURL
        let snapshot = workspaceSnapshot
        let workspaceGeneration = expectedWorkspaceGeneration ?? workspaceGeneration
        let fileURL = currentDocument.fileURL
        let text = currentDocument.text

        completionWorkspaceTask = Task { @MainActor [weak self] in
            if debounceNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: debounceNanoseconds)
                } catch {
                    return
                }
            }

            let workspace = await Task.detached(priority: .utility) {
                if let rootURL, let fileURL, let snapshot {
                    do {
                        return try CompletionWorkspaceProvider().workspace(
                            rootURL: rootURL,
                            currentFileURL: fileURL,
                            currentText: text,
                            snapshot: snapshot
                        )
                    } catch {
                        return CompletionWorkspace(
                            currentFilePath: fileURL.lastPathComponent,
                            currentFileHeadingAnchors: []
                        )
                    }
                } else {
                    do {
                        return try CompletionWorkspaceProvider().workspace(
                            rootURL: nil,
                            currentFileURL: fileURL,
                            currentText: text,
                            tree: nil
                        )
                    } catch {
                        return CompletionWorkspace(
                            currentFilePath: fileURL?.lastPathComponent,
                            currentFileHeadingAnchors: []
                        )
                    }
                }
            }.value

            guard let self,
                  !Task.isCancelled,
                  self.workspaceGeneration == workspaceGeneration
            else {
                return
            }
            completionWorkspace = workspace
        }
    }

    func workspaceSearchDirtyOverlays(
        rootAuthority: WorkspaceFileSystemRootAuthority
    ) async throws -> WorkspaceSearchOverlayCollection {
        let cachedSessions = sessionCache
            .sorted { first, second in
                Self.workspaceSearchPathLessThan(
                    first.key.absoluteString,
                    second.key.absoluteString
                )
            }
            .map(\.value)
        let candidateSessions = [currentDocument] + cachedSessions
        var seenSessions: Set<ObjectIdentifier> = []
        var inputs: [WorkspaceSearchDirtyOverlayInput] = []

        for session in candidateSessions where session.isDirty {
            let sessionIdentity = ObjectIdentifier(session)
            guard seenSessions.insert(sessionIdentity).inserted,
                  let fileURL = session.fileURL?.standardizedFileURL,
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

    func applyWorkspaceSearchFileResult(_ result: WorkspaceSearchFileResult) {
        if let existingIndex = workspaceSearchState.fileResults.firstIndex(where: {
            ExactSourceText.matches($0.relativePath, result.relativePath)
        }) {
            workspaceSearchState.fileResults[existingIndex] = result
        } else {
            workspaceSearchState.fileResults.append(result)
        }
        workspaceSearchState.fileResults.sort {
            Self.workspaceSearchPathLessThan($0.relativePath, $1.relativePath)
        }
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
