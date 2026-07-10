import Foundation
import MarkdownCore

extension WorkspaceSearchPipeline {
    func execute(plan: WorkspaceSearchCandidatePlan) async throws {
        let candidateLocations = candidateLocations(in: plan)
        var state = WorkspaceSearchExecutionState()

        try await withThrowingTaskGroup(of: WorkspaceSearchReadOutcome.self) { group in
            defer {
                group.cancelAll()
                state.bufferedReads.removeAll(keepingCapacity: false)
            }
            try scheduleReads(candidateLocations, group: &group, state: &state)

            for planIndex in plan.items.indices {
                let shouldStop = try await processPlanItem(
                    plan.items[planIndex],
                    at: planIndex,
                    candidates: candidateLocations,
                    group: &group,
                    state: &state
                )
                try emitProgressIfNeeded(for: plan, state: &state)
                if shouldStop {
                    group.cancelAll()
                    state.bufferedReads.removeAll(keepingCapacity: false)
                    break
                }
            }
        }

        try Task.checkCancellation()
        try emitProgressIfNeeded(for: plan, state: &state, forceFinal: true)
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
            state.receivedReadOutcomeCount += 1
            state.recordReadWindowMaximums()
            try failureInjector.checkpoint(.afterReadOutcome(state.receivedReadOutcomeCount))
            try scheduleReads(candidates, group: &group, state: &state)
        }

        guard let outcome = state.bufferedReads.removeValue(forKey: planIndex) else {
            throw CancellationError()
        }
        try scheduleReads(candidates, group: &group, state: &state)
        return outcome
    }

    private func scheduleReads(
        _ candidates: [(Int, WorkspaceSearchCandidate)],
        group: inout ThrowingTaskGroup<WorkspaceSearchReadOutcome, any Error>,
        state: inout WorkspaceSearchExecutionState
    ) throws {
        let concurrencyLimit = max(1, request.limits.maximumConcurrentReads)
        while state.nextCandidateLocation < candidates.count,
              state.outstandingReadCount < concurrencyLimit
        {
            try Task.checkCancellation()
            let (planIndex, candidate) = candidates[state.nextCandidateLocation]
            group.addTask {
                try await read(candidate: candidate, at: planIndex)
            }
            state.nextCandidateLocation += 1
            state.inFlightReads += 1
            state.maximumConcurrentReads = max(state.maximumConcurrentReads, state.inFlightReads)
            state.recordReadWindowMaximums()
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

        case let .content(text, relativePath):
            state.searchedFileCount += 1
            return try processTextMatches(
                in: text,
                relativePath: relativePath,
                state: &state
            )
        }
    }

    private func processTextMatches(
        in text: String,
        relativePath: String,
        state: inout WorkspaceSearchExecutionState
    ) throws -> Bool {
        try Task.checkCancellation()
        let contentFingerprint = WorkspaceSearchContentFingerprint(text: text)
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
                    contentFingerprint: contentFingerprint,
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
        state.skippedFileCount += 1
        guard state.skippedFiles.count < request.limits.maximumReportedSkippedFiles else {
            return
        }
        state.skippedFiles.append(skippedFile)
        try yield(.skippedFile(context, skippedFile))
    }

    private func emitProgressIfNeeded(
        for plan: WorkspaceSearchCandidatePlan,
        state: inout WorkspaceSearchExecutionState,
        forceFinal: Bool = false
    ) throws {
        let completedFileCount = state.completedFileCount
        guard state.lastProgressCompletedFileCount != completedFileCount else { return }

        let maximumProgressEvents = request.limits.maximumProgressEvents
        if forceFinal {
            guard state.progressEventCount < maximumProgressEvents else { return }
        } else {
            let candidateFileCount = plan.candidateFileCount
            guard candidateFileCount > 0 else { return }
            let stride = progressStride(
                candidateFileCount: candidateFileCount,
                maximumProgressEvents: maximumProgressEvents
            )
            guard completedFileCount == candidateFileCount
                || completedFileCount.isMultiple(of: stride)
            else {
                return
            }
        }

        try yield(.progress(
            context,
            WorkspaceSearchProgress(
                completedFileCount: completedFileCount,
                candidateFileCount: plan.candidateFileCount
            )
        ))
        state.progressEventCount += 1
        state.lastProgressCompletedFileCount = completedFileCount
    }

    private func progressStride(
        candidateFileCount: Int,
        maximumProgressEvents: Int
    ) -> Int {
        let quotient = candidateFileCount / maximumProgressEvents
        return quotient + (candidateFileCount.isMultiple(of: maximumProgressEvents) ? 0 : 1)
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
    var maximumBufferedReadCount = 0
    var maximumOutstandingReadCount = 0
    var bufferedReads: [Int: WorkspaceSearchReadOutcome] = [:]
    var receivedReadOutcomeCount = 0
    var completedFileCount = 0
    var progressEventCount = 0
    var lastProgressCompletedFileCount: Int?
    var searchedFileCount = 0
    var totalEmittedMatchCount = 0
    var diskReadCount = 0
    var diskReadByteCount = 0
    var skippedFileCount = 0
    var skippedFiles: [WorkspaceSearchSkippedFile] = []
    var truncatedFilePaths: [String] = []
    var isGloballyTruncated = false

    var outstandingReadCount: Int {
        inFlightReads + bufferedReads.count
    }

    mutating func recordReadWindowMaximums() {
        maximumBufferedReadCount = max(maximumBufferedReadCount, bufferedReads.count)
        maximumOutstandingReadCount = max(maximumOutstandingReadCount, outstandingReadCount)
    }

    mutating func recordDiskRead(_ byteCount: Int?) {
        guard let byteCount else { return }
        diskReadCount += 1
        diskReadByteCount += byteCount
    }

    func summary(for plan: WorkspaceSearchCandidatePlan) -> WorkspaceSearchSummary {
        WorkspaceSearchSummary(
            candidateFileCount: plan.candidateFileCount,
            searchedFileCount: searchedFileCount,
            skippedFileCount: skippedFileCount,
            ignoredFileCount: plan.ignoredFileCount,
            totalEmittedMatchCount: totalEmittedMatchCount,
            truncatedFilePaths: truncatedFilePaths,
            isGloballyTruncated: isGloballyTruncated,
            skippedFiles: skippedFiles,
            omittedSkippedFileCount: skippedFileCount - skippedFiles.count,
            readInstrumentation: WorkspaceSearchReadInstrumentation(
                diskReadCount: diskReadCount,
                diskReadByteCount: diskReadByteCount,
                maximumConcurrentReads: maximumConcurrentReads,
                maximumBufferedReadCount: maximumBufferedReadCount,
                maximumOutstandingReadCount: maximumOutstandingReadCount
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
    case content(text: String, relativePath: String)
    case skipped(WorkspaceSearchSkippedFile)
}
