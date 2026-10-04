import AppKit
import STTextView

@MainActor
extension MarkdownTextViewCoordinator {
    /// Attribute-only suspension once for the whole batch. The raw TextKit source
    /// stays authoritative; no projected U+FFFC/U+200B text enters the replacement.
    /// Its one publication requests the normal post-write presentation reparse.
    func suspendBatchReplacePresentation(in textView: STTextView) {
        guard let view = textView as? MarkdownSTTextView,
              view.wysiwygZeroWidthContentStorageDelegate != nil,
              let storage = MarkdownTextView.textStorage(of: view)
        else { return }
        let manager = view.undoManager
        let restoresRegistration = manager?.isUndoRegistrationEnabled == true
        if restoresRegistration {
            manager?.disableUndoRegistration()
        }
        storage.beginEditing()
        let range = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(WYSIWYGInlineFoldPresentation.foldedDelimiterAttribute, range: range)
        storage.removeAttribute(WYSIWYGImagePresentationMarker.attribute, range: range)
        storage.endEditing()
        if restoresRegistration {
            manager?.enableUndoRegistration()
        }
        view.replacePresentationSnapshot = nil
        if let textRange = NSTextRange(range, in: view.textContentManager) {
            view.textLayoutManager.invalidateLayout(for: textRange)
        }
        view.needsDisplay = true
    }
}
