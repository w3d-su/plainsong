import Foundation

@MainActor
extension MarkdownTextViewCoordinator {
    func updateImageThumbnailPresentationConfiguration(
        _ configuration: EditorImageThumbnailConfiguration?,
        documentIdentity: EditorDocumentIdentity?,
        isPresentationEnabled: Bool,
        in textView: MarkdownSTTextView
    ) {
        imageThumbnailPresentationController.updateConfiguration(
            configuration,
            documentIdentity: documentIdentity,
            isPresentationEnabled: isPresentationEnabled,
            in: textView
        )
        imageThumbnailPresentationController.documentTextDidChange(in: textView)
    }

    func applyImageThumbnailPresentation(
        foldPlan: WYSIWYGFoldPlan?,
        in textView: MarkdownSTTextView,
        forceReapply: Bool
    ) {
        guard let source = MarkdownTextView.textStorage(of: textView)?.string else {
            return
        }
        imageThumbnailPresentationController.apply(
            foldPlan: foldPlan,
            source: source,
            selection: textView.selectedRange(),
            forceReapply: forceReapply,
            in: textView
        )
    }

    func detachImageThumbnailPresentation(from textView: MarkdownSTTextView) {
        imageThumbnailPresentationController.detach(from: textView)
    }
}
