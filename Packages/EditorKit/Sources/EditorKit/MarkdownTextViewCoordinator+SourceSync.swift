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

    /// Do not apply a captured styled value after a presentation reset.
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
        textView.textSelection = selection.clamped(toLength: (source as NSString).length)
        isUpdating = false
    }
}
