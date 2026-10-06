import Darwin
import EditorKit
import Foundation
import MarkdownCore

enum EditorReplaceBatchCommandResult: Equatable {
    case ineligible(EditorReplaceIneligibility)
    case refused(EditorReplaceAuthorizationRefusal)
    case notDelivered(EditorReplaceDeliveryRefusal)
    case invalidPlan(EditorReplacePlanRefusal)
    case cancelled
    case superseded
    case markedText
    case delivered(EditorReplaceBatchOutcome)
}

private struct EditorReplaceBatchCapture {
    let plan: EditorReplacePlan
    let invocation: EditorReplaceInvocation
    let actionID: UInt64
    let replacementGeneration: UInt64
    let navigationGeneration: UInt64
}

@MainActor
extension AppState {
    /// PR H's replacement field uses this even when a value returns A -> B -> A.
    func setEditorReplaceReplacement(_ value: String) {
        if editorFindHost.replaceBatch.setReplacement(value) {
            advanceEditorReplaceAuthorityGeneration()
        }
    }

    func cancelEditorReplaceAll() {
        editorFindHost.replaceBatch.cancel()
        advanceEditorReplaceAuthorityGeneration()
    }

    /// Two phases: a bounded worker prepares B1, then one synchronous turn commits it.
    /// Missing/recomputing sessions never retain an intent for a future Find result.
    func performEditorReplaceAll(
        replacement: String,
        invocation: EditorReplaceInvocation = .menu
    ) async -> EditorReplaceBatchCommandResult {
        setEditorReplaceReplacement(replacement)
        let plan: EditorReplacePlan
        switch makeEditorReplacePlan(replacement: replacement) {
        case let .failure(.ineligible(reason)): return .ineligible(reason)
        case let .failure(.noKeyWindowEditor(reason)): return .notDelivered(reason)
        case let .success(value): plan = value
        }
        if editorReplaceHasMarkedText(for: plan) {
            return .markedText
        }
        if case let .refused(reason) = editorReplaceAuthorizationDecision(for: plan.stamp, session: plan.session) {
            return .refused(reason)
        }
        // Cheap refusals happen before a task or progress starts.
        if plan.request.session.isTruncated {
            return .invalidPlan(.truncatedSession)
        }
        if plan.request.session.total == 0 {
            return .invalidPlan(.emptySession)
        }
        guard plan.request.sourceRevision == editorFindHost.controller.documentBinding.revision,
              plan.request.sourceRevision == UInt64(max(0, currentDocument.version)),
              plan.request.documentIdentity == activeEditorDocumentIdentity
        else {
            refreshEditorFindCounterFromAppSource()
            return .superseded
        }

        let state = editorFindHost.replaceBatch
        let previousTask = state.preparationTask
        let token = state.begin(total: plan.request.session.total)
        let capture = EditorReplaceBatchCapture(
            plan: plan, invocation: invocation, actionID: state.actionID,
            replacementGeneration: state.replacementGeneration,
            navigationGeneration: editorNavigationGeneration
        )
        let observation = EditorReplaceCommandDispatcher.observeBatchSelectionChanges { [weak self] in
            self?.advanceEditorReplaceAuthorityGeneration()
            token.cancel()
        }
        defer { observation?.stop() }
        let request = plan.request
        let source = editorFindHost.controller.documentBinding.text
        let selection = plan.editorStamp.selection
        let hook = state.onChunkForTesting
        let began = ContinuousClock.now
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            // Serial drain: a newer explicit action cancels the old one, then waits for
            // its bounded checkpoint before allocating another source/slice.
            if let previousTask {
                _ = await previousTask.value
            }
            let ranOffMain = pthread_main_np() == 0
            let result = EditorReplaceBatchPreparation.prepare(
                session: request.session, source: source,
                replacement: request.replacement, selection: selection,
                isCancelled: { token.isCancelled },
                onChunk: { chunk in hook?(chunk) },
                progress: { progress in
                    Task { @MainActor [weak self] in
                        guard let self, isCurrentEditorReplaceBatch(capture), state.isPreparing,
                              progress.completedMatchCount > (state.progress.last?.completedMatchCount ?? 0)
                        else { return }
                        state.progress.append(progress)
                        state.onProgressForTesting?(progress)
                    }
                }
            )
            await MainActor.run {
                if state.actionID == capture.actionID {
                    state.lastPreparationRanOffMain = ranOffMain
                }
            }
            return result
        }
        state.preparationTask = worker
        state.preparationActionID = capture.actionID
        let prepared = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            token.cancel()
        }
        if state.preparationActionID == capture.actionID {
            state.preparationMilliseconds = elapsedMilliseconds(since: began)
        }
        if case .success = prepared, !token.isCancelled, isCurrentEditorReplaceBatch(capture) {
            await presentEditorReplaceApplying(state)
        }
        // The selection observer covers the frame above; the final recheck takes over from here.
        observation?.stop()
        let result = finishEditorReplaceBatchPreparation(prepared, capture: capture, token: token)
        state.isApplying = false
        state.finish(action: capture.actionID, result: result)
        return result
    }

    /// Shows `Applying…` (Cancel withdrawn) and yields one frame so it can render. This is
    /// before the final recheck, where the no-suspension rule starts: anything that changes
    /// during the frame — an edit, selection, fence, close, or composition — still fails it.
    private func presentEditorReplaceApplying(_ state: EditorReplaceBatchRuntime) async {
        state.beginApplying()
        objectWillChange.send()
        try? await Task.sleep(nanoseconds: Self.editorReplaceApplyingFrameNanoseconds)
    }

    /// One display frame at 60 Hz.
    static let editorReplaceApplyingFrameNanoseconds: UInt64 = 16_000_000

    private func finishEditorReplaceBatchPreparation(
        _ prepared: Result<EditorReplacePreparedBatch, EditorReplaceBatchPreparationFailure>,
        capture: EditorReplaceBatchCapture,
        token: EditorReplaceBatchCancellation
    ) -> EditorReplaceBatchCommandResult {
        let state = editorFindHost.replaceBatch
        let result: EditorReplaceBatchCommandResult
        if token.wasExplicitlyCancelled {
            result = .cancelled
        } else if Task.isCancelled {
            // Caller cancellation supersedes via the same App generation after drain.
            if state.actionID == capture.actionID {
                cancelEditorReplaceAll()
            }
            result = .cancelled
        } else if !isCurrentEditorReplaceBatch(capture) {
            result = .superseded
        } else {
            switch prepared {
            case .failure(.cancelled): result = .cancelled
            case let .failure(.invalidPlan(reason)): result = .invalidPlan(reason)
            case let .success(batch): result = commitEditorReplaceBatch(batch, capture: capture)
            }
        }
        return result
    }

    private func isCurrentEditorReplaceBatch(_ capture: EditorReplaceBatchCapture) -> Bool {
        let state = editorFindHost.replaceBatch
        let controller = editorFindHost.controller
        return state.actionID == capture.actionID
            && state.replacementGeneration == capture.replacementGeneration
            && editorNavigationGeneration == capture.navigationGeneration
            && capture.plan.stamp == currentEditorReplaceAuthorityStamp(for: currentDocument)
            && controller.queryGeneration == capture.plan.request.queryGeneration
            && controller.documentBinding.identity == capture.plan.request.documentIdentity
            && controller.documentBinding.revision == capture.plan.request.sourceRevision
            && controller.session == capture.plan.request.session
            && EditorReplaceCommandDispatcher.captureKeyWindowEditorStamp() == .success(capture.plan.editorStamp)
    }

    /// No await from this recheck through authorization, writer preflight and native insert.
    private func commitEditorReplaceBatch(
        _ batch: EditorReplacePreparedBatch,
        capture: EditorReplaceBatchCapture
    ) -> EditorReplaceBatchCommandResult {
        let state = editorFindHost.replaceBatch
        // From here to the native insert there is no suspension.
        state.willCommitForTesting?()
        guard isCurrentEditorReplaceBatch(capture) else { return .superseded }
        let record = EditorReplaceAuthorizationRecord()
        editorFindHost.replaceAuthority.lastAuthorizationRecord = record
        let plan = capture.plan
        let decision = editorReplaceAuthorizationDecision(for: plan.stamp, session: plan.session)
        record.note(.validation, decision)
        guard case .allowed = decision, let session = plan.session else {
            return .refused(record.refusal ?? .notCurrentSession)
        }
        let command = EditorReplaceBatchCommand(
            request: plan.request, prepared: batch,
            authorization: makeEditorReplaceCommitAuthorization(stamp: plan.stamp, session: session, record: record),
            controller: editorFindHost.controller, editorStamp: plan.editorStamp,
            installations: liveEditorDocumentBindingInstallations(for: session),
            recheck: { [weak self] in
                guard let self, isCurrentEditorReplaceBatch(capture) else { return .superseded }
                if editorFindHost.replaceMarkedTextOwners.hasMarkedText(in: plan.editorStamp.window) {
                    return .markedText
                }
                return nil
            }
        )
        // Preparation cancellation is no longer consulted once native committing begins.
        state.isPreparing = false
        let began = ContinuousClock.now
        var delivery = EditorReplaceCommandDispatcher.sendBatch(command)
        if delivery == EditorReplaceBatchDelivery.notDelivered(.noEditorOnResponderChain),
           capture.invocation == .barControl || isEditorFindCommandContextActive()
        {
            delivery = EditorReplaceCommandDispatcher.sendBatchToKeyWindowEditor(command)
        }
        state.commitMilliseconds = elapsedMilliseconds(since: began)
        switch delivery {
        case .notDelivered(.staleEditorStamp): return .superseded
        case let .notDelivered(reason): return .notDelivered(reason)
        case .delivered(.refused(.unauthorized)): return .refused(record.refusal ?? .authoritySuperseded)
        case .delivered(.refused(.markedText)): return .markedText
        case .delivered(.refused(.superseded)): return .superseded
        case let .delivered(.refused(.invalidPlan(reason))): return .invalidPlan(reason)
        case .delivered(.refused(.staleIdentity)), .delivered(.refused(.staleRevision)),
             .delivered(.refused(.staleQueryGeneration)), .delivered(.refused(.staleSession)):
            refreshEditorFindCounterFromAppSource()
            return .superseded
        case let .delivered(outcome):
            switch outcome {
            case .refused(.writerPreflightFailed), .refused(.writeNotApplied), .unverifiedWrite:
                refreshEditorFindCounterFromAppSource()
            default: break
            }
            return .delivered(outcome)
        }
    }

    private func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }
}
