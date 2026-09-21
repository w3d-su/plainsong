import AppKit
import STTextView

@MainActor
extension MarkdownSTTextView {
    func applyWYSIWYGComposedCharacterMovement(delta: Int, extending: Bool) -> Bool {
        guard wysiwygZeroWidthContentStorageDelegate != nil,
              !hasMarkedText(),
              let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage
        else {
            return false
        }

        let text = textStorage.string as NSString
        let textLength = text.length
        let selection = selectedRange().clamped(toLength: textLength)

        if extending {
            guard let previous = currentWYSIWYGSelectionExtension() else { return false }
            let anchor = previous.anchor
            let activeEnd = previous.activeEnd
            let moved = delta < 0
                ? text.composedCharacterBoundary(before: activeEnd)
                : text.composedCharacterBoundary(after: activeEnd)
            setWYSIWYGSelection(anchor: anchor, activeEnd: moved)
        } else {
            let base = delta < 0 ? selection.location : NSMaxRange(selection)
            let movedLocation = selection.length > 0 ? base : delta < 0
                ? text.composedCharacterBoundary(before: base)
                : text.composedCharacterBoundary(after: base)
            // Edge-snapping: a collapsed caret never rests inside a folded (zero-width)
            // delimiter. Selections (the `extending` branch above) are left raw so copy
            // stays exact Markdown.
            let snappedLocation = wysiwygSnappedCaretOffset(
                movedLocation,
                preferring: delta < 0 ? .backward : .forward
            )
            textSelection = NSRange(location: snappedLocation, length: 0)
        }

        return true
    }

    func currentWYSIWYGSelectionExtension() -> (anchor: Int, activeEnd: Int)? {
        guard let selection = textLayoutManager.textSelections.last,
              let range = selection.textRanges.last
        else { return nil }
        let start = textContentManager.offset(from: textContentManager.documentRange.location, to: range.location)
        let end = textContentManager.offset(from: textContentManager.documentRange.location, to: range.endLocation)
        // Affinity describes the non-anchored edge for a nonempty native selection.
        // Read it for every command, including selections produced by word/line/paragraph
        // navigation and mouse dragging; object identity is not selection direction.
        return selection.affinity == .upstream ? (end, start) : (start, end)
    }

    func setWYSIWYGSelection(anchor: Int, activeEnd: Int) {
        guard isSelectable else { return }
        if anchor == activeEnd {
            // A caret also refreshes STTextView's typing attributes.
            textSelection = NSRange(location: anchor, length: 0)
            return
        }
        let documentStart = textContentManager.documentRange.location
        guard let start = textContentManager.location(documentStart, offsetBy: min(anchor, activeEnd)),
              let end = textContentManager.location(documentStart, offsetBy: max(anchor, activeEnd)),
              let range = NSTextRange(location: start, end: end)
        else { return }
        // Publish range and direction together: the NSRange setter would first notify
        // observers of a downstream selection even when the active edge is upstream.
        // Like native extending movement, retain typing attributes while nonempty.
        textLayoutManager.textSelections = [NSTextSelection(
            range: range, affinity: activeEnd < anchor ? .upstream : .downstream, granularity: .character
        )]
        needsLayout = true
    }
}

private extension NSString {
    func composedCharacterBoundary(before offset: Int) -> Int {
        let clampedOffset = min(max(offset, 0), length)
        guard clampedOffset > 0 else {
            return 0
        }

        return rangeOfComposedCharacterSequence(at: clampedOffset - 1).location
    }

    func composedCharacterBoundary(after offset: Int) -> Int {
        let clampedOffset = min(max(offset, 0), length)
        guard clampedOffset < length else {
            return length
        }

        return NSMaxRange(rangeOfComposedCharacterSequence(at: clampedOffset))
    }
}
