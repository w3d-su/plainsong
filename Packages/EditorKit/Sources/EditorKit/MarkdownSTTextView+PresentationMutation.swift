import AppKit

/// Presentation-only attribute edits shared by image thumbnails and table rows: they never
/// register undo and keep the selection and scroll position where they were.
@MainActor
extension MarkdownSTTextView {
    func performPresentationAttributeMutation(
        in textStorage: NSTextStorage,
        _ mutation: () -> Void
    ) {
        let originalSelection = selectedRange()
        let clipView = enclosingScrollView?.contentView
        let visibleOrigin = clipView?.bounds.origin
        let manager = undoManager
        let restoresUndoRegistration = manager?.isUndoRegistrationEnabled == true
        if restoresUndoRegistration {
            manager?.disableUndoRegistration()
        }
        mutation()
        if restoresUndoRegistration {
            manager?.enableUndoRegistration()
        }
        if selectedRange() != originalSelection {
            textSelection = originalSelection.clamped(toLength: textStorage.length)
        }
        if let clipView, let visibleOrigin {
            clipView.scroll(to: visibleOrigin)
            enclosingScrollView?.reflectScrolledClipView(clipView)
        }
    }

    func invalidatePresentationParagraphs(containing ranges: [NSRange]) {
        guard !ranges.isEmpty,
              let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage
        else {
            return
        }

        let storage = textStorage.string as NSString
        let paragraphRanges = ranges
            .map { storage.paragraphRange(for: $0.clamped(toLength: storage.length)) }
            .reduce(into: [NSRange]()) { accumulated, range in
                guard !accumulated.contains(range) else { return }
                accumulated.append(range)
            }
        for paragraphRange in paragraphRanges {
            guard let textRange = NSTextRange(paragraphRange, in: textContentManager) else {
                continue
            }
            textLayoutManager.invalidateLayout(for: textRange)
        }
        needsDisplay = true
    }
}
