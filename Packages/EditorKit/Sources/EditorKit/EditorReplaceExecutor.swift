import AppKit
import MarkdownCore
import STTextView

/// Source-only single Replace. App passes a plain request and reads a plain
/// outcome; the concrete editor stays inside EditorKit.
@MainActor
extension MarkdownTextViewCoordinator {
    func performSingleReplace(
        _ request: EditorReplaceRequest,
        authorization: EditorReplaceAuthorization,
        controller: EditorFindController,
        in textView: STTextView
    ) -> EditorReplaceOutcome {
        if textView.hasMarkedText() {
            return .refused(.markedText)
        }
        let eligible: EligibleReplace
        switch validatedReplace(request, controller: controller, in: textView) {
        case let .failure(refusal):
            return .refused(refusal)
        case let .success(value):
            eligible = value
        }
        guard authorization.allowsCommit() else {
            return .refused(.unauthorized)
        }
        if isWYSIWYGPresentationInstalled(textView) {
            return .refused(.wysiwygPresentationInstalled)
        }
        let selectionIsMatch = isPreparedDocumentInstalled
            && textView.selectedRange() == eligible.match.range
        guard selectionIsMatch else {
            controller.activateCurrentMatch()
            applyControllerNavigation(controller, in: textView)
            return .navigatedToCurrentMatch(eligible.match.range)
        }
        return commitValidatedReplace(eligible, request: request, controller: controller, in: textView)
    }

    private func commitValidatedReplace(
        _ eligible: EligibleReplace,
        request: EditorReplaceRequest,
        controller: EditorFindController,
        in textView: STTextView
    ) -> EditorReplaceOutcome {
        switch EditorReplacePlanner.planOneMatch(
            session: request.session,
            source: eligible.source,
            replacement: request.replacement
        ) {
        case let .failure(refusal):
            return .refused(.invalidPlan(refusal))
        case let .success(plan) where plan.isLiteralIdentical:
            let continuation = EditorReplaceContinuationPlanning.afterLiteralIdentical(
                plan: plan,
                session: request.session
            )
            controller.installUnchangedContinuation(continuation)
            applyControllerNavigation(controller, in: textView)
            return .advancedIdentical(continuation)
        case let .success(plan):
            return commitSourceChange(
                plan,
                preWriteSource: eligible.source,
                controller: controller,
                in: textView
            )
        }
    }

    private func validatedReplace(
        _ request: EditorReplaceRequest,
        controller: EditorFindController,
        in textView: STTextView
    ) -> Result<EligibleReplace, EditorReplaceRefusal> {
        guard request.documentIdentity == controller.documentBinding.identity,
              request.documentIdentity == currentDocumentIdentity
        else {
            return .failure(.staleIdentity)
        }
        guard let snapshot = currentInstalledSourceSnapshot,
              request.sourceRevision == controller.documentBinding.revision,
              request.sourceRevision == UInt64(snapshot.revision)
        else {
            return .failure(.staleRevision)
        }
        guard request.queryGeneration == controller.queryGeneration else {
            return .failure(.staleQueryGeneration)
        }
        guard controller.session == request.session else {
            return .failure(.staleSession)
        }
        guard let match = request.session.currentMatch else {
            return .failure(.noCurrentMatch)
        }
        let source = MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
        guard ExactSourceText.matches(source, snapshot.source),
              ExactSourceText.matches(source, controller.documentBinding.text)
        else {
            return .failure(.staleRevision)
        }
        return .success(EligibleReplace(match: match, source: source))
    }

    private func commitSourceChange(
        _ plan: EditorReplaceOneMatchPlan,
        preWriteSource: String,
        controller: EditorFindController,
        in textView: STTextView
    ) -> EditorReplaceOutcome {
        guard let planned = EditorReplaceSourceConstruction.replacedSource(
            preWriteSource,
            ranges: [plan.match.range],
            replacement: plan.replacement
        ) else {
            return .refused(.invalidPlan(.noCurrentMatch))
        }
        var preWriteRevision: Int?
        let opened = performPreflightedTextMutation(in: textView) {
            guard let revision = currentInstalledSourceSnapshot?.revision else { return }
            preWriteRevision = revision
            controller.armReplacementPublication()
            insertAuthorizedReplacement(
                plan,
                preWriteSource: preWriteSource,
                preWriteRevision: revision,
                in: textView
            )
        }
        // Find observers run only after the writer-authorized closure has returned.
        guard opened, let preWriteRevision else {
            controller.abandonReplacementPublication()
            return .refused(.writerPreflightFailed)
        }
        // The insert ran, but its outcome can no longer be observed.
        guard let observed = currentInstalledSourceSnapshot else {
            controller.abandonReplacementPublication()
            return .unverifiedWrite
        }

        // The outcome is what the authoritative post-write snapshot shows, not the fact
        // that `insertText` was called: native insertion can be refused and a publication
        // can be rejected (restored) or reconciled.
        if observed.revision > preWriteRevision,
           ExactSourceText.matches(observed.source, planned)
        {
            // A rebind or document close during the write already superseded Find.
            let admitted = controller.admitReplacementPublication(
                plan: plan,
                text: observed.source,
                revision: UInt64(observed.revision)
            )
            return admitted ? .replaced(plan) : .unverifiedWrite
        }
        controller.abandonReplacementPublication()
        if observed.revision == preWriteRevision,
           ExactSourceText.matches(observed.source, preWriteSource)
        {
            return .refused(.writeNotApplied)
        }
        // A host that does not route publications to Find still recomputes the change.
        controller.documentTextDidChange(
            text: observed.source,
            revision: UInt64(max(0, observed.revision))
        )
        return .unverifiedWrite
    }

    /// The one native edit, inside the writer-authorized closure.
    private func insertAuthorizedReplacement(
        _ plan: EditorReplaceOneMatchPlan,
        preWriteSource: String,
        preWriteRevision: Int,
        in textView: STTextView
    ) {
        textView.breakUndoCoalescing()
        editingBehaviorGuard.isApplying = true
        defer { editingBehaviorGuard.isApplying = false }
        // A write whose publication is rejected leaves no undo step (Decision Log).
        EditorReplaceRejectedWriteUndo(
            textView: textView,
            coordinator: self,
            preWriteSource: preWriteSource,
            preWriteRevision: preWriteRevision
        ).guarding {
            textView.insertText(plan.replacement, replacementRange: plan.match.range)
        }
        // Close any group the insert joined, even if a caller dispatches Replace while
        // STTextView is processing a key event, so later typing is its own undo step.
        textView.breakUndoCoalescing()
    }

    private func applyControllerNavigation(
        _ controller: EditorFindController,
        in textView: STTextView
    ) {
        observeNavigationCommand(controller.pendingNavigationCommand)
        _ = applyPendingNavigationIfPossible(in: textView)
    }

    private struct EligibleReplace {
        let match: TextSearchMatch
        let source: String
    }

    private func isWYSIWYGPresentationInstalled(_ textView: STTextView) -> Bool {
        guard let textView = textView as? MarkdownSTTextView else { return false }
        return textView.wysiwygZeroWidthContentStorageDelegate != nil
    }
}
