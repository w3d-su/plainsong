import Foundation
import MarkdownCore

struct WorkspaceSearchPipeline {
    let request: WorkspaceSearchRequest
    let reader: any WorkspaceSearchFileReading
    let continuation: AsyncStream<WorkspaceSearchEvent>.Continuation
    let failureInjector: WorkspaceSearchPipelineFailureInjector

    func run() async throws {
        if let validationError = validationError(for: request.query) {
            try yield(.validationFailure(context, validationError))
            return
        }

        let plan = try await WorkspaceSearchCandidatePlanner.makePlan(request: request, reader: reader)
        try failureInjector.checkpoint(.afterPlanning)
        try await execute(plan: plan)
    }
}
