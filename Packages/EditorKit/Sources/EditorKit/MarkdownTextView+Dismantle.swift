import AppKit

extension MarkdownTextView {
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? MarkdownSTTextView else { return }
        coordinator.detachFocusHandler(from: textView)
        coordinator.detachPasteAndDragHandlers(from: textView)
        coordinator.detachCommandProxy(from: textView)
        coordinator.detachScrollProxy()
        coordinator.detachVisibleRangeReporter()
        coordinator.cancelCompletionRequest()
        coordinator.cancelPendingNavigationTasks()
        coordinator.invalidateDeferredSelectionPublication()
        coordinator.detachDeferredDocumentTransitionInstallationHandler()
        coordinator.revokeInstalledDocumentBinding()
        coordinator.detachImageThumbnailPresentation(from: textView)
        textView.textDelegate = nil
    }
}
