import AppKit
import STTextView

extension MarkdownTextViewCoordinator {
    func scheduleMarkedTextReplacementRangeCleanup(
        for textView: MarkdownSTTextView
    ) {
        Task { @MainActor [weak textView] in
            await Task.yield()
            textView?.clearPotentialMarkedTextReplacementRangeIfUnmarked()
        }
    }

    /// A captured pre-restore representable value may arrive even after the fresh
    /// parse applied. Keep this floor until the next reconciliation, so it stays raw.
    func canApplyHighlightRevision(_ revision: Int) -> Bool {
        !hasDeferredReconciliationPresentation
            && (minimumHighlightRevisionAfterReconciliation.map { revision >= $0 } ?? true)
    }

    func applyReconciledSource(
        _ source: String,
        replacing _: String,
        in textView: STTextView
    ) {
        let selection = textView.selectedRange()
        isUpdating = true
        textView.text = source
        let clampedSelection = selection.clamped(toLength: (source as NSString).length)
        textView.textSelection = clampedSelection
        isUpdating = false
        if clampedSelection != selection {
            // Writer preflight can refuse the native edit, leaving no later selection
            // notification to update the binding used by WYSIWYG parsing.
            publishAppliedSelection(clampedSelection)
        }

        // Whole-source assignment removes every presentation attribute. Retain the
        // applied revision so an older styledText value cannot be reused, but discard
        // plans and asynchronous image work that belong to the cleared presentation.
        lastAppliedHighlightFoldPlan = nil
        appliedFindMatchHighlight = nil
        appliedFindMatchHighlightSpan = nil
        appliedFindMatchHighlightMaterialisation = nil
        if let textView = textView as? MarkdownSTTextView {
            textView.replacePresentationSnapshot = nil
            imageThumbnailPresentationController.presentationWasReset(in: textView)
        }
        requestReconciledSourcePresentation()
    }

    /// App's Reload / Keep Mine synchronizer for this exact installation.
    ///
    /// Keep Mine delivers the *unchanged* session snapshot. Whole-source assignment would
    /// erase every presentation attribute (highlighting, WYSIWYG folds, link folding, image
    /// markers, Find decoration) while the App text never changed, so no reparse would be
    /// scheduled and the editor would stay raw until the next keystroke. When the native
    /// source already equals the snapshot exactly (UTF-16, no normalization) there is
    /// nothing to install: the snapshot is only accepted, and selection, undo and every
    /// attribute stay untouched. A snapshot with different text (Reload) still assigns; the
    /// changed App text then re-derives presentation through the normal text-change path.
    /// The comparison runs only while an external-change resolution converges, never on
    /// the typing path. Marked text and a pending writer lease still defer unchanged.
    func synchronizeInstalledSource(
        _ snapshot: EditorDocumentSourceSnapshot,
        in textView: STTextView
    ) -> Bool {
        guard !hasPendingWriterLease,
              !textView.hasMarkedText()
        else {
            return false
        }

        if !nativeTextMatches(textView, snapshot.source) {
            let selectedRange = textView.selectedRange()
            isUpdating = true
            textView.text = snapshot.source
            textView.textSelection = selectedRange.clamped(
                toLength: (snapshot.source as NSString).length
            )
            isUpdating = false
        }
        installedDocument.acceptSourceSnapshot(snapshot)
        isNativeSourceSynchronized = true
        isUserEditing = false
        return true
    }

    func invalidateDeferredReconciledSourcePresentation() {
        reconciledSourcePresentationGeneration &+= 1
        hasDeferredReconciliationPresentation = false
        // Keep the numeric floor across document switches: a captured old view
        // can still carry pre-restore styling whose source matches the new document.
    }

    private func requestReconciledSourcePresentation() {
        reconciledSourcePresentationGeneration &+= 1
        hasDeferredReconciliationPresentation = false
        guard reconciledSourcePresentationInvalidationHandler != nil else {
            minimumHighlightRevisionAfterReconciliation = nil
            return
        }
        guard isInsideRepresentableUpdate else {
            minimumHighlightRevisionAfterReconciliation = reconciledSourcePresentationInvalidationHandler?()
            return
        }

        // Block every produced result until the callback can safely write SwiftUI
        // state. Selection publication was enqueued first, so parsing sees its clamp.
        hasDeferredReconciliationPresentation = true
        let generation = reconciledSourcePresentationGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, reconciledSourcePresentationGeneration == generation else { return }
            hasDeferredReconciliationPresentation = false
            minimumHighlightRevisionAfterReconciliation = reconciledSourcePresentationInvalidationHandler?()
        }
    }
}
