import AppKit

extension MarkdownSTTextView {
    /// Snaps a collapsed-caret offset out of any folded delimiter interior, reading the
    /// live fold attributes so it reflects exactly what is currently hidden. Used by the
    /// non-user-facing WYSIWYG hook for keyboard arrow and pointer click rest positions.
    func wysiwygSnappedCaretOffset(_ offset: Int, preferring direction: WYSIWYGCaretSnap.Direction) -> Int {
        if let imageSnappedOffset = wysiwygImagePresentationSnappedCaretOffset(
            offset,
            preferring: direction
        ) {
            return imageSnappedOffset
        }

        guard let foldedRange = wysiwygFoldedDelimiterRange(containingInterior: offset) else {
            return offset
        }

        return WYSIWYGCaretSnap.snap(
            offset: offset,
            foldedDelimiterRanges: [foldedRange],
            preferring: direction
        )
    }

    /// The folded delimiter run that strictly contains `offset` in its interior, or `nil`
    /// when `offset` sits at a run edge, in visible content, or folding is disabled.
    func wysiwygFoldedDelimiterRange(containingInterior offset: Int) -> NSRange? {
        guard wysiwygZeroWidthContentStorageDelegate != nil,
              let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage,
              offset > 0,
              offset < textStorage.length
        else {
            return nil
        }

        // Read the complete live attribute run. Link destinations can be arbitrarily long,
        // so a bounded window could snap only partway through a hidden `](url)` span and
        // leave the caret resting inside the remainder.
        var effectiveRange = NSRange(location: 0, length: 0)
        let value = textStorage.attribute(
            WYSIWYGInlineFoldPresentation.foldedDelimiterAttribute,
            at: offset - 1,
            longestEffectiveRange: &effectiveRange,
            in: NSRange(location: 0, length: textStorage.length)
        )
        guard (value as? Bool) == true, offset < NSMaxRange(effectiveRange) else {
            return nil
        }
        return effectiveRange
    }
}
