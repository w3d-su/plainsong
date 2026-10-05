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
        minimumHighlightRevisionAfterReconciliation.map { revision >= $0 } ?? true
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

    func invalidateDeferredReconciledSourcePresentation() {
        reconciledSourcePresentationGeneration &+= 1
        minimumHighlightRevisionAfterReconciliation = nil
    }

    private func requestReconciledSourcePresentation() {
        reconciledSourcePresentationGeneration &+= 1
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
        minimumHighlightRevisionAfterReconciliation = Int.max
        let generation = reconciledSourcePresentationGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, reconciledSourcePresentationGeneration == generation else { return }
            minimumHighlightRevisionAfterReconciliation = reconciledSourcePresentationInvalidationHandler?()
        }
    }
}
