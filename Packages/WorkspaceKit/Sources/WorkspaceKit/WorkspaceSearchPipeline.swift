import Foundation
import MarkdownCore

struct WorkspaceSearchPipeline {
    let request: WorkspaceSearchRequest
    let reader: any WorkspaceSearchFileReading
    let continuation: AsyncStream<WorkspaceSearchEvent>.Continuation

    func run() async throws {
        if let validationError = validationError(for: request.query) {
            try yield(.validationFailure(context, validationError))
            return
        }

        let plan = try await WorkspaceSearchCandidatePlanner.makePlan(request: request, reader: reader)
        try await execute(plan: plan)
    }
}
