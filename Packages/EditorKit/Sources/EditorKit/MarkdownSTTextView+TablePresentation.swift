import AppKit

@MainActor
extension MarkdownSTTextView {
    /// Replaces every table-row marker with `markers`, which belong to `generation`.
    /// Presentation only: no undo, selection and scroll position kept.
    func applyWYSIWYGTableRowPresentationMarkers(
        _ markers: [WYSIWYGTableRowPresentationMarker],
        generation: UInt64
    ) {
        guard let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage else {
            return
        }

        let previousRows = tableRowMarkerRanges(in: textStorage)
        wysiwygZeroWidthContentStorageDelegate?.tablePresentationGeneration = generation
        performPresentationAttributeMutation(in: textStorage) {
            textStorage.beginEditing()
            for range in previousRows {
                textStorage.removeAttribute(WYSIWYGTableRowPresentationMarker.attribute, range: range)
            }
            for marker in markers {
                let target = marker.rowRange.clamped(toLength: textStorage.length)
                guard target == marker.rowRange, target.length > 0 else { continue }
                textStorage.addAttribute(WYSIWYGTableRowPresentationMarker.attribute, value: marker, range: target)
            }
            textStorage.endEditing()
        }
        invalidatePresentationParagraphs(containing: previousRows + markers.map(\.rowRange))
    }

    func removeAllWYSIWYGTableRowPresentationMarkers() {
        guard let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage else {
            return
        }
        let previousRows = tableRowMarkerRanges(in: textStorage)
        wysiwygZeroWidthContentStorageDelegate?.tablePresentationGeneration = nil
        guard !previousRows.isEmpty else { return }
        performPresentationAttributeMutation(in: textStorage) {
            for range in previousRows {
                textStorage.removeAttribute(WYSIWYGTableRowPresentationMarker.attribute, range: range)
            }
        }
        invalidatePresentationParagraphs(containing: previousRows)
    }

    /// The live marker of the presented row whose line contains `offset` (line end included).
    func wysiwygTableRowMarker(at offset: Int) -> WYSIWYGTableRowPresentationMarker? {
        guard let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage,
              let generation = wysiwygZeroWidthContentStorageDelegate?.tablePresentationGeneration,
              offset >= 0, offset <= textStorage.length
        else {
            return nil
        }
        for probe in [offset, offset - 1] where probe >= 0 && probe < textStorage.length {
            guard let marker = textStorage.attribute(
                WYSIWYGTableRowPresentationMarker.attribute,
                at: probe,
                effectiveRange: nil
            ) as? WYSIWYGTableRowPresentationMarker,
                marker.generation == generation,
                offset >= marker.rowRange.location,
                offset <= NSMaxRange(marker.rowRange)
            else {
                continue
            }
            return marker
        }
        return nil
    }

    /// A collapsed caret never rests on hidden table structure (`docs/table-wysiwyg-gates.md` §4).
    func wysiwygTablePresentationSnappedCaretOffset(
        _ offset: Int,
        preferring direction: WYSIWYGCaretSnap.Direction
    ) -> Int? {
        guard let marker = wysiwygTableRowMarker(at: offset), marker.kind != .delimiter else {
            return nil
        }
        let snapped = WYSIWYGTableRowCaretSnap.snap(
            offset: offset,
            rowRange: marker.rowRange,
            contentRanges: marker.contentRanges,
            tabOffsets: marker.tabOffsets,
            preferring: direction
        )
        return snapped == offset ? nil : snapped
    }

    private func tableRowMarkerRanges(in textStorage: NSTextStorage) -> [NSRange] {
        guard textStorage.length > 0 else { return [] }
        var ranges: [NSRange] = []
        textStorage.enumerateAttribute(
            WYSIWYGTableRowPresentationMarker.attribute,
            in: NSRange(location: 0, length: textStorage.length)
        ) { value, range, _ in
            if value != nil {
                ranges.append(range)
            }
        }
        return ranges
    }
}
