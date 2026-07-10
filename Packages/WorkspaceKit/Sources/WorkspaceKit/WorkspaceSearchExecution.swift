import Foundation
import MarkdownCore

extension WorkspaceSearchPipeline {
    func execute(plan: WorkspaceSearchCandidatePlan) async throws {
        let candidateLocations = candidateLocations(in: plan)
        var state = WorkspaceSearchExecutionState()

        try await withThrowingTaskGroup(of: WorkspaceSearchReadOutcome.self) { group in
            defer { group.cancelAll() }
            try scheduleReads(candidateLocations, group: &group, state: &state)

            for planIndex in plan.items.indices {
                let shouldStop = try await processPlanItem(
                    plan.items[planIndex],
                    at: planIndex,
                    candidates: candidateLocations,
                    group: &group,
                    state: &state
                )
                try emitProgress(for: plan, state: state)
                if shouldStop {
                    group.cancelAll()
                    break
                }
            }
        }

        try Task.checkCancellation()
        try yield(.completed(context, state.summary(for: plan)))
    }

    private func processPlanItem(
        _ item: WorkspaceSearchCandidatePlanItem,
        at planIndex: Int,
        candidates: [(Int, WorkspaceSearchCandidate)],
        group: inout ThrowingTaskGroup<WorkspaceSearchReadOutcome, any Error>,
        state: inout WorkspaceSearchExecutionState
    ) async throws -> Bool {
        try Task.checkCancellation()

        switch item {
        case .ignored:
            state.completedFileCount += 1
            return false

        case let .skipped(_, skippedFile):
            try recordSkippedFile(skippedFile, state: &state)
            state.completedFileCount += 1
            return false

        case .candidate:
            let outcome = try await nextReadOutcome(
                for: planIndex,
                candidates: candidates,
                group: &group,
                state: &state
            )
            state.recordDiskRead(outcome.diskReadByteCount)
            let shouldStop = try processReadPayload(outcome.payload, state: &state)
            state.completedFileCount += 1
            return shouldStop
        }
    }

    private func nextReadOutcome(
        for planIndex: Int,
        candidates: [(Int, WorkspaceSearchCandidate)],
        group: inout ThrowingTaskGroup<WorkspaceSearchReadOutcome, any Error>,
        state: inout WorkspaceSearchExecutionState
    ) async throws -> WorkspaceSearchReadOutcome {
        while state.bufferedReads[planIndex] == nil {
            guard let outcome = try await group.next() else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            state.inFlightReads -= 1
            state.bufferedReads[outcome.planIndex] = outcome
            try scheduleReads(candidates, group: &group, state: &state)
        }

        guard let outcome = state.bufferedReads.removeValue(forKey: planIndex) else {
            throw CancellationError()
        }
        return outcome
    }

    private func scheduleReads(
        _ candidates: [(Int, WorkspaceSearchCandidate)],
        group: inout ThrowingTaskGroup<WorkspaceSearchReadOutcome, any Error>,
        state: inout WorkspaceSearchExecutionState
    ) throws {
        let concurrencyLimit = max(1, request.limits.maximumConcurrentReads)
        while state.nextCandidateLocation < candidates.count, state.inFlightReads < concurrencyLimit {
            try Task.checkCancellation()
            let (planIndex, candidate) = candidates[state.nextCandidateLocation]
            group.addTask {
                try await read(candidate: candidate, at: planIndex)
            }
            state.nextCandidateLocation += 1
            state.inFlightReads += 1
            state.maximumConcurrentReads = max(state.maximumConcurrentReads, state.inFlightReads)
        }
    }

    private func processReadPayload(
        _ payload: WorkspaceSearchReadPayload,
        state: inout WorkspaceSearchExecutionState
    ) throws -> Bool {
        switch payload {
        case let .skipped(skippedFile):
            try recordSkippedFile(skippedFile, state: &state)
            return false

        case let .content(text, sourceVersion, relativePath):
            state.searchedFileCount += 1
            return try processTextMatches(
                in: text,
                relativePath: relativePath,
                sourceVersion: sourceVersion,
                state: &state
            )
        }
    }

    private func processTextMatches(
        in text: String,
        relativePath: String,
        sourceVersion: String,
        state: inout WorkspaceSearchExecutionState
    ) throws -> Bool {
        try Task.checkCancellation()
        let discoveredMatches = TextSearchEngine.matches(
            in: text,
            query: request.query,
            limit: matcherLimit(for: request.limits.maximumMatchesPerFile)
        )
        try Task.checkCancellation()

        let perFileLimit = max(0, request.limits.maximumMatchesPerFile)
        let fileMatches = Array(discoveredMatches.prefix(perFileLimit))
        let isPerFileTruncated = discoveredMatches.count > fileMatches.count
        let remainingCapacity = max(0, globalMatchLimit - state.totalEmittedMatchCount)
        let emittedMatches = Array(fileMatches.prefix(remainingCapacity))
        let globalOverflow = state.totalEmittedMatchCount + emittedMatches.count == globalMatchLimit
            && discoveredMatches.count > emittedMatches.count

        if isPerFileTruncated {
            state.truncatedFilePaths.append(relativePath)
        }
        if !emittedMatches.isEmpty {
            try yield(.fileResult(
                context,
                WorkspaceSearchFileResult(
                    relativePath: relativePath,
                    sourceVersion: sourceVersion,
                    matches: emittedMatches,
                    isTruncated: isPerFileTruncated || globalOverflow
                )
            ))
            state.totalEmittedMatchCount += emittedMatches.count
        }
        state.isGloballyTruncated = globalOverflow
        return globalOverflow
    }

    private func recordSkippedFile(
        _ skippedFile: WorkspaceSearchSkippedFile,
        state: inout WorkspaceSearchExecutionState
    ) throws {
        state.skippedFiles.append(skippedFile)
        try yield(.skippedFile(context, skippedFile))
    }

    private func emitProgress(
        for plan: WorkspaceSearchCandidatePlan,
        state: WorkspaceSearchExecutionState
    ) throws {
        try yield(.progress(
            context,
            WorkspaceSearchProgress(
                completedFileCount: state.completedFileCount,
                candidateFileCount: plan.candidateFileCount
            )
        ))
    }

    private func candidateLocations(in plan: WorkspaceSearchCandidatePlan) -> [(Int, WorkspaceSearchCandidate)] {
        plan.items.enumerated().compactMap { index, item in
            guard case let .candidate(_, candidate) = item else { return nil }
            return (index, candidate)
        }
    }
}

private struct WorkspaceSearchExecutionState {
    var nextCandidateLocation = 0
    var inFlightReads = 0
    var maximumConcurrentReads = 0
    var bufferedReads: [Int: WorkspaceSearchReadOutcome] = [:]
    var completedFileCount = 0
    var searchedFileCount = 0
    var totalEmittedMatchCount = 0
    var diskReadCount = 0
    var diskReadByteCount = 0
    var skippedFiles: [WorkspaceSearchSkippedFile] = []
    var truncatedFilePaths: [String] = []
    var isGloballyTruncated = false

    mutating func recordDiskRead(_ byteCount: Int?) {
        guard let byteCount else { return }
        diskReadCount += 1
        diskReadByteCount += byteCount
    }

    func summary(for plan: WorkspaceSearchCandidatePlan) -> WorkspaceSearchSummary {
        WorkspaceSearchSummary(
            candidateFileCount: plan.candidateFileCount,
            searchedFileCount: searchedFileCount,
            skippedFileCount: skippedFiles.count,
            ignoredFileCount: plan.ignoredFileCount,
            totalEmittedMatchCount: totalEmittedMatchCount,
            truncatedFilePaths: truncatedFilePaths,
            isGloballyTruncated: isGloballyTruncated,
            skippedFiles: skippedFiles,
            readInstrumentation: WorkspaceSearchReadInstrumentation(
                diskReadCount: diskReadCount,
                diskReadByteCount: diskReadByteCount,
                maximumConcurrentReads: maximumConcurrentReads
            )
        )
    }
}

struct WorkspaceSearchReadOutcome {
    let planIndex: Int
    let payload: WorkspaceSearchReadPayload
    let diskReadByteCount: Int?
}

enum WorkspaceSearchReadPayload {
    case content(text: String, sourceVersion: String, relativePath: String)
    case skipped(WorkspaceSearchSkippedFile)
}
