import AppKit

@MainActor
extension MarkdownSTTextView {
    func applyWYSIWYGImagePresentationMarkers(
        _ markers: [WYSIWYGImagePresentationMarker],
        replacing previousMarkers: [WYSIWYGImagePresentationMarker],
        generation: UInt64,
        forceReapply: Bool
    ) {
        guard let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage else {
            return
        }

        let previousByRange = Dictionary(
            uniqueKeysWithValues: previousMarkers.map { (ImageRangeKey($0.sourceRange), $0) }
        )
        let nextByRange = Dictionary(
            uniqueKeysWithValues: markers.map { (ImageRangeKey($0.sourceRange), $0) }
        )
        let allKeys = Set(previousByRange.keys).union(nextByRange.keys)
        let changedKeys = allKeys.filter { key in
            guard !forceReapply,
                  let previous = previousByRange[key],
                  let next = nextByRange[key]
            else {
                return true
            }
            return previous.signature != next.signature
        }

        wysiwygZeroWidthContentStorageDelegate?.imagePresentationGeneration = generation
        guard !changedKeys.isEmpty else {
            return
        }

        let changedRanges = changedKeys.map(\.range)
        performImagePresentationMutation(in: textStorage) {
            textStorage.beginEditing()
            for range in changedRanges {
                let target = range.clamped(toLength: textStorage.length)
                guard target.length > 0 else { continue }
                textStorage.removeAttribute(WYSIWYGImagePresentationMarker.attribute, range: target)
            }
            for key in changedKeys {
                guard let marker = nextByRange[key] else { continue }
                let target = marker.sourceRange.clamped(toLength: textStorage.length)
                guard target == marker.sourceRange, target.length > 0 else { continue }
                textStorage.addAttribute(
                    WYSIWYGImagePresentationMarker.attribute,
                    value: marker,
                    range: target
                )
            }
            textStorage.endEditing()
        }
        invalidateImagePresentationParagraphs(containing: changedRanges)
    }

    func removeAllWYSIWYGImagePresentationMarkers() {
        guard let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage,
              textStorage.length > 0
        else {
            return
        }

        performImagePresentationMutation(in: textStorage) {
            textStorage.removeAttribute(
                WYSIWYGImagePresentationMarker.attribute,
                range: NSRange(location: 0, length: textStorage.length)
            )
        }
        invalidateImagePresentationParagraphs(
            containing: [NSRange(location: 0, length: textStorage.length)]
        )
    }

    func setWYSIWYGImagePresentationGeneration(
        _ generation: UInt64?,
        invalidating ranges: [NSRange]
    ) {
        guard wysiwygZeroWidthContentStorageDelegate?.imagePresentationGeneration != generation else {
            return
        }
        wysiwygZeroWidthContentStorageDelegate?.imagePresentationGeneration = generation
        invalidateImagePresentationParagraphs(containing: ranges)
    }

    func wysiwygImagePresentationSnappedCaretOffset(
        _ offset: Int,
        preferring direction: WYSIWYGCaretSnap.Direction
    ) -> Int? {
        guard let range = wysiwygImagePresentationRange(containingInterior: offset) else {
            return nil
        }
        return WYSIWYGCaretSnap.snap(
            offset: offset,
            foldedDelimiterRanges: [range],
            preferring: direction
        )
    }

    func revealWYSIWYGImagePresentationIfNeeded(at caret: Int) {
        guard let range = wysiwygImagePresentationRange(touchedBy: caret),
              let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage
        else {
            return
        }

        performImagePresentationMutation(in: textStorage) {
            textStorage.removeAttribute(WYSIWYGImagePresentationMarker.attribute, range: range)
        }
        invalidateImagePresentationParagraphs(containing: [range])
    }
}

@MainActor
private extension MarkdownSTTextView {
    func wysiwygImagePresentationRange(containingInterior offset: Int) -> NSRange? {
        guard let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage,
              offset > 0,
              offset < textStorage.length,
              let generation = wysiwygZeroWidthContentStorageDelegate?.imagePresentationGeneration
        else {
            return nil
        }

        var effectiveRange = NSRange(location: 0, length: 0)
        let marker = textStorage.attribute(
            WYSIWYGImagePresentationMarker.attribute,
            at: offset - 1,
            longestEffectiveRange: &effectiveRange,
            in: NSRange(location: 0, length: textStorage.length)
        ) as? WYSIWYGImagePresentationMarker
        guard marker?.generation == generation,
              offset < NSMaxRange(effectiveRange)
        else {
            return nil
        }
        return effectiveRange
    }

    func wysiwygImagePresentationRange(touchedBy offset: Int) -> NSRange? {
        guard let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage,
              let generation = wysiwygZeroWidthContentStorageDelegate?.imagePresentationGeneration,
              offset >= 0,
              offset <= textStorage.length
        else {
            return nil
        }

        let probeLocations = [min(offset, max(textStorage.length - 1, 0)), offset - 1]
        for probe in probeLocations where probe >= 0 && probe < textStorage.length {
            var effectiveRange = NSRange(location: 0, length: 0)
            let marker = textStorage.attribute(
                WYSIWYGImagePresentationMarker.attribute,
                at: probe,
                longestEffectiveRange: &effectiveRange,
                in: NSRange(location: 0, length: textStorage.length)
            ) as? WYSIWYGImagePresentationMarker
            if marker?.generation == generation,
               offset >= effectiveRange.location,
               offset <= NSMaxRange(effectiveRange)
            {
                return effectiveRange
            }
        }
        return nil
    }

    func performImagePresentationMutation(
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

    func invalidateImagePresentationParagraphs(containing ranges: [NSRange]) {
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

private struct ImageRangeKey: Hashable {
    let location: Int
    let length: Int

    init(_ range: NSRange) {
        location = range.location
        length = range.length
    }

    var range: NSRange {
        NSRange(location: location, length: length)
    }
}
