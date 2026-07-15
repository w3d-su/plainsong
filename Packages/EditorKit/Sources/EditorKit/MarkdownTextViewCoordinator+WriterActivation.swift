import AppKit
import STTextView

@MainActor
extension MarkdownTextViewCoordinator {
    @discardableResult
    func performPreflightedTextMutation(
        in textView: STTextView,
        _ mutation: () -> Void
    ) -> Bool {
        guard !isUpdating,
              preflightTextMutation(in: textView)
        else {
            return false
        }

        withWriterAuthorizedTextMutation(in: textView, mutation)
        return true
    }

    func applyPreflightedEditingBehavior(
        _ proposal: EditingBehaviorProposal,
        to textView: STTextView
    ) -> Bool {
        guard case .textMutation = proposal else {
            return EditingBehaviorsSupport.apply(
                proposal,
                to: textView,
                editingGuard: editingBehaviorGuard
            )
        }

        return withWriterAuthorizedTextMutation(in: textView) {
            EditingBehaviorsSupport.apply(
                proposal,
                to: textView,
                editingGuard: editingBehaviorGuard
            )
        }
    }

    func preflightTextMutation(
        in textView: STTextView,
        allowsPendingStalePublication: Bool = false
    ) -> Bool {
        // A marked source already passed the activation fence when composition began.
        // Its commit must publish from that retained base so App can perform the
        // existing non-overlapping three-way reconciliation.
        if allowsPendingStalePublication,
           isSourceSynchronizationPending,
           !installedDocument.isSourceRevisionCurrent()
        {
            return true
        }

        return requestWriterActivation(in: textView)
    }

    private func withWriterAuthorizedTextMutation<Result>(
        in textView: STTextView,
        _ mutation: () -> Result
    ) -> Result {
        let isOutermostMutation = writerAuthorizedTextMutationDepth == 0
        if isOutermostMutation {
            writerAuthorizedTextView = textView
        }
        writerAuthorizedTextMutationDepth += 1
        defer {
            writerAuthorizedTextMutationDepth -= 1
            if isOutermostMutation {
                writerAuthorizedTextView = nil
            }
        }
        return mutation()
    }

    private func requestWriterActivation(
        in textView: STTextView,
        retryingAfterSynchronization: Bool = false
    ) -> Bool {
        guard let result = installedDocument.requestWriterActivation(
            installationID: documentBindingInstallationID
        ) else {
            return true
        }

        switch result {
        case let .activated(snapshot):
            acceptWriterActivation(snapshot)
            return true
        case let .synchronize(snapshot):
            return synchronizeWriterActivation(
                snapshot,
                in: textView,
                retryingAfterSynchronization: retryingAfterSynchronization
            )
        case let .rejected(snapshot):
            rejectWriterActivation(snapshot, in: textView)
            return false
        case .released, .releaseRejected:
            assertionFailure("Writer activation returned a release result")
            return false
        }
    }

    private func acceptWriterActivation(_ snapshot: EditorDocumentSourceSnapshot) {
        // Matching App-owned revisions plus exact installation authorization are
        // constant-time proof for the ordinary native mutation path. The coordinator's
        // buffer was installed from that retained revision, so do not scan it here.
        installedDocument.synchronizeSourceSnapshot(snapshot)
        isNativeSourceSynchronized = true
    }

    private func synchronizeWriterActivation(
        _ snapshot: EditorDocumentSourceSnapshot,
        in textView: STTextView,
        retryingAfterSynchronization: Bool
    ) -> Bool {
        let isExactViewBase = nativeTextMatches(textView, snapshot.source)
        if !isExactViewBase {
            applyReconciledSource(snapshot.source, replacing: "", in: textView)
        }
        installedDocument.synchronizeSourceSnapshot(snapshot)
        isNativeSourceSynchronized = true
        settleSourceSynchronizationPending()
        scheduleDeferredDocumentTransitionRetry()

        // A URL or file-kind rekey can advance the session revision without changing
        // its exact source. Reacquire before the native mutation; content-stale views
        // still reject this event.
        guard isExactViewBase, !retryingAfterSynchronization else {
            return false
        }
        return requestWriterActivation(
            in: textView,
            retryingAfterSynchronization: true
        )
    }

    private func rejectWriterActivation(
        _ snapshot: EditorDocumentSourceSnapshot,
        in textView: STTextView
    ) {
        if !nativeTextMatches(textView, snapshot.source) {
            applyReconciledSource(snapshot.source, replacing: "", in: textView)
        }
        installedDocument.synchronizeSourceSnapshot(snapshot)
        isNativeSourceSynchronized = true
        settleSourceSynchronizationPending()
        scheduleDeferredDocumentTransitionRetry()
    }

    func beginSourceSynchronizationPending() {
        guard !isSourceSynchronizationPending else { return }
        isSourceSynchronizationPending = true
        installedDocument.reportPendingSource(
            EditorDocumentPendingSourceEvent.began,
            installationID: documentBindingInstallationID
        )
    }

    func settleSourceSynchronizationPending() {
        guard isSourceSynchronizationPending else { return }
        installedDocument.reportPendingSource(
            EditorDocumentPendingSourceEvent.synchronized,
            installationID: documentBindingInstallationID
        )
        isSourceSynchronizationPending = false
        scheduleDeferredDocumentTransitionRetry()
    }
}
