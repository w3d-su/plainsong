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
            return commitSourceChange(plan, controller: controller, in: textView)
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
        controller: EditorFindController,
        in textView: STTextView
    ) -> EditorReplaceOutcome {
        var didInsert = false
        let opened = performPreflightedTextMutation(in: textView) {
            guard let preWrite = currentInstalledSourceSnapshot?.revision else { return }
            controller.armReplacementPublication(
                plan: plan,
                preWriteRevision: UInt64(preWrite)
            )
            textView.breakUndoCoalescing()
            editingBehaviorGuard.isApplying = true
            defer { editingBehaviorGuard.isApplying = false }
            textView.insertText(plan.replacement, replacementRange: plan.match.range)
            didInsert = true
        }

        guard opened, didInsert else {
            controller.disarmReplacementPublication()
            return .refused(.writerPreflightFailed)
        }

        // App's document publication consumes the arm when it is wired. A host
        // that does not route Find still gets exactly one replacement rescan.
        if let published = currentInstalledSourceSnapshot,
           let preWrite = controller.armedReplacementPreWriteRevision,
           UInt64(published.revision) == preWrite &+ 1
        {
            controller.consumeDocumentPublication(
                text: published.source,
                revision: UInt64(published.revision)
            )
        } else if controller.hasArmedReplacementPublication {
            controller.disarmReplacementPublication()
        }
        return .replaced(plan)
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
