import Foundation
import MarkdownCore

extension WorkspaceSearchPipeline {
    var context: WorkspaceSearchContext {
        WorkspaceSearchContext(
            rootIdentity: request.rootIdentity,
            workspaceGeneration: request.workspaceGeneration,
            queryGeneration: request.queryGeneration
        )
    }

    func validationError(for query: TextSearchQuery) -> WorkspaceSearchValidationError? {
        if query.pattern.isEmpty { return .emptyQuery }
        if query.pattern.contains(where: \.isNewline) { return .newlineInQuery }
        if query.pattern.utf16.count > TextSearchEngine.maximumPatternUTF16Length {
            return .overlongQuery(maximumUTF16Length: TextSearchEngine.maximumPatternUTF16Length)
        }
        return nil
    }

    func matcherLimit(for maximumMatchesPerFile: Int) -> Int {
        let limit = max(0, maximumMatchesPerFile)
        guard limit < Int.max else { return Int.max }
        return max(1, limit + 1)
    }

    func inclusiveLimit(for limit: Int) -> Int {
        guard limit < Int.max else { return limit }
        return limit + 1
    }

    var globalMatchLimit: Int {
        max(0, request.limits.maximumMatchesPerQuery)
    }

    func isMissingFileError(_ error: Error) -> Bool {
        (error as NSError).code == NSFileNoSuchFileError
    }

    func yield(_ event: WorkspaceSearchEvent) throws {
        try Task.checkCancellation()
        if case .terminated = continuation.yield(event) {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }
}
