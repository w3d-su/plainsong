import AppKit
import MarkdownCore
import STTextView

/// Product Candidate B1: one prepared minimal raw enclosing slice, one writer
/// activation, one native insertion. This synchronous commit never checks task
/// cancellation after admission and cannot expose an intermediate batch source.
@MainActor
extension MarkdownTextViewCoordinator {
    func performBatchReplace(
        _ request: EditorReplaceRequest,
        prepared: EditorReplacePreparedBatch,
        authorization: EditorReplaceAuthorization,
        controller: EditorFindController,
        recheck: @MainActor () -> EditorReplaceBatchRefusal?,
        in textView: STTextView
    ) -> EditorReplaceBatchOutcome {
        guard !textView.hasMarkedText() else { return .refused(.markedText) }
        let source: String
        switch validatedBatchReplace(request, prepared: prepared, controller: controller, in: textView) {
        case let .failure(refusal): return .refused(refusal)
        case let .success(value): source = value
        }
        // The App tuple, editor composition, and authorization are the last checks;
        // writer preflight and the native insert follow without a suspension.
        if let refusal = recheck() {
            return .refused(refusal)
        }
        guard !textView.hasMarkedText() else { return .refused(.markedText) }
        guard authorization.allowsCommit() else { return .refused(.unauthorized) }
        // Authorization may synchronously run an App callback; it cannot hide a
        // fence or composition that appeared in that callback.
        if let refusal = recheck() {
            return .refused(refusal)
        }
        guard !textView.hasMarkedText() else { return .refused(.markedText) }
        guard prepared.plan.changedCount > 0 else { return .noChanges(prepared.plan) }
        guard let enclosing = prepared.plan.enclosingRange,
              let slice = prepared.replacementSlice
        else { return .refused(.invalidPlan(.noCurrentMatch)) }
        let preWriteCaret = textView.selectedRange().location
        var preWriteRevision: Int?
        let opened = performPreflightedTextMutation(in: textView) {
            guard let revision = currentInstalledSourceSnapshot?.revision else { return }
            preWriteRevision = revision
            controller.armReplacementPublication()
            suspendBatchReplacePresentation(in: textView)
            insertAuthorizedBatch(
                slice,
                enclosing: enclosing,
                postSelection: prepared.postSelection,
                preWriteSource: source,
                preWriteRevision: revision,
                in: textView
            )
        }
        guard opened, let preWriteRevision else {
            controller.abandonReplacementPublication()
            return .refused(.writerPreflightFailed)
        }
        guard let observed = currentInstalledSourceSnapshot else {
            controller.abandonReplacementPublication()
            return .unverifiedWrite
        }
        if observed.revision > preWriteRevision,
           ExactSourceText.matches(observed.source, prepared.expectedSource)
        {
            let admitted = controller.admitBatchReplacementPublication(
                plan: prepared.plan,
                text: observed.source,
                revision: UInt64(observed.revision),
                preWriteCurrentMatch: request.session.currentMatch,
                preWriteCaretUTF16: preWriteCaret,
                mappedAnchorUTF16: prepared.postSelection.location
            )
            return admitted ? .replaced(prepared.plan) : .unverifiedWrite
        }
        controller.abandonReplacementPublication()
        if observed.revision == preWriteRevision,
           ExactSourceText.matches(observed.source, source)
        {
            return .refused(.writeNotApplied)
        }
        controller.documentTextDidChange(
            text: observed.source,
            revision: UInt64(max(0, observed.revision))
        )
        return .unverifiedWrite
    }

    private func validatedBatchReplace(
        _ request: EditorReplaceRequest,
        prepared: EditorReplacePreparedBatch,
        controller: EditorFindController,
        in textView: STTextView
    ) -> Result<String, EditorReplaceBatchRefusal> {
        guard request.documentIdentity == controller.documentBinding.identity,
              request.documentIdentity == currentDocumentIdentity
        else { return .failure(.staleIdentity) }
        guard let snapshot = currentInstalledSourceSnapshot,
              request.sourceRevision == controller.documentBinding.revision,
              request.sourceRevision == UInt64(snapshot.revision)
        else { return .failure(.staleRevision) }
        guard request.queryGeneration == controller.queryGeneration else {
            return .failure(.staleQueryGeneration)
        }
        guard controller.session == request.session else { return .failure(.staleSession) }
        guard !request.session.isTruncated else { return .failure(.invalidPlan(.truncatedSession)) }
        guard prepared.plan.query == request.session.query,
              ExactSourceText.matches(prepared.plan.replacement, request.replacement),
              prepared.plan.allRanges == request.session.matches.map(\.range),
              prepared.plan.totalCount == request.session.total
        else { return .failure(.staleSession) }
        let source = MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
        guard ExactSourceText.matches(source, snapshot.source),
              ExactSourceText.matches(source, controller.documentBinding.text),
              ExactSourceText.matches(source, prepared.sourceSnapshot)
        else { return .failure(.staleRevision) }
        return .success(source)
    }

    private func insertAuthorizedBatch(
        _ slice: String,
        enclosing: NSRange,
        postSelection: NSRange,
        preWriteSource: String,
        preWriteRevision: Int,
        in textView: STTextView
    ) {
        textView.breakUndoCoalescing()
        let manager = textView.undoManager
        var openedUndoGroup = false
        var observedAppliedChange = false
        let priorSelection = textView.selectedRange()
        editingBehaviorGuard.isApplying = true
        let rejectedUndo = EditorReplaceRejectedWriteUndo(
            textView: textView,
            coordinator: self,
            preWriteSource: preWriteSource,
            preWriteRevision: preWriteRevision,
            onAppliedChange: {
                // An empty outer group itself swallows Undo on a rejected write.
                // Open only after publication is accepted, before native undo
                // registration (STTextView registers after its notification).
                guard !openedUndoGroup else { return }
                observedAppliedChange = true
                manager?.beginUndoGrouping()
                openedUndoGroup = manager != nil
            }
        )
        rejectedUndo.guarding {
            textView.insertText(slice, replacementRange: enclosing)
        }
        editingBehaviorGuard.isApplying = false
        if !observedAppliedChange || rejectedUndo.didSuppressUndoRegistration {
            textView.textSelection = priorSelection
        } else {
            textView.textSelection = postSelection
            // Selection restoration is registered only after the native edit is
            // accepted. A rejected publication opens no outer undo group.
            EditorReplaceBatchSelectionUndo(textView: textView).register(
                priorSelection: priorSelection,
                postSelection: postSelection
            )
        }
        if openedUndoGroup {
            manager?.endUndoGrouping()
        }
        textView.breakUndoCoalescing()
    }
}
