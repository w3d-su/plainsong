import AppKit
import MarkdownCore
import STTextView

@MainActor
extension MarkdownTextView {
    /// Applies highlight attributes while preserving presentation markers that this pass must
    /// not own: image projections (so a visible-range recompute does not force a full
    /// image-marker rewrite every keystroke) and find-match decoration (docs/editor-find-gates.md
    /// F8 — `setAttributes` below replaces the whole attribute dictionary, so anything not
    /// collected and restored here is silently wiped on the next recompute).
    static func applyHighlightedTextPreservingPresentationMarkers(
        _ styledText: HighlightedText,
        to textView: STTextView
    ) -> Bool {
        guard
            !textView.hasMarkedText(),
            let textStorage = textStorage(of: textView)
        else {
            return false
        }

        let incoming = NSMutableAttributedString(attributedString: NSAttributedString(styledText.text))
        if let foldPlan = styledText.foldPlan {
            WYSIWYGInlineFoldPresentation.applyFoldedDelimiterAttributes(
                plan: foldPlan,
                visibleRange: styledText.range,
                to: incoming
            )
        }
        let targetRange = styledText.range.clamped(toLength: textStorage.length)
        guard targetRange.length == incoming.length else {
            return false
        }

        if incoming.length > 0 {
            // Exact code units: `==` on these bridged strings would normalize both, slowly,
            // and accept canonically equivalent text that is not the highlighted source.
            let currentText = (textStorage.string as NSString).substring(with: targetRange)
            guard ExactSourceText.matches(currentText, incoming.string) else {
                return false
            }
        }

        let selectedRange = textView.selectedRange()
        let clipView = textView.enclosingScrollView?.contentView
        let visibleOrigin = clipView?.bounds.origin
        let undoManager = textView.undoManager
        let shouldRestoreUndoRegistration = undoManager?.isUndoRegistrationEnabled == true
        if shouldRestoreUndoRegistration {
            undoManager?.disableUndoRegistration()
        }
        defer {
            if shouldRestoreUndoRegistration {
                undoManager?.enableUndoRegistration()
            }
            if textView.selectedRange() != selectedRange {
                textView.textSelection = selectedRange.clamped(toLength: textStorage.length)
            }
            if let clipView, let visibleOrigin {
                clipView.scroll(to: visibleOrigin)
                textView.enclosingScrollView?.reflectScrolledClipView(clipView)
            }
        }

        let preservedImageMarkers = collectImagePresentationMarkers(
            in: textStorage,
            range: targetRange
        )
        let preservedFindHighlights = EditorFindMatchHighlight.collect(
            in: textStorage,
            range: targetRange
        )

        textStorage.beginEditing()
        incoming.enumerateAttributes(
            in: NSRange(location: 0, length: incoming.length)
        ) { attributes, range, _ in
            let destinationRange = NSRange(
                location: targetRange.location + range.location,
                length: range.length
            )
            // Re-setting equal attributes still marks the run edited, and TextKit then
            // re-typesets every visible paragraph on each keystroke. Typing usually changes
            // the runs of one paragraph; the stored result is identical either way.
            guard !hasExactAttributes(attributes, in: destinationRange, of: textStorage) else {
                return
            }
            textStorage.setAttributes(attributes, range: destinationRange)
        }
        restoreImagePresentationMarkers(preservedImageMarkers, in: textStorage)
        EditorFindMatchHighlight.restore(preservedFindHighlights, in: textStorage)
        textStorage.endEditing()
        if let view = textView as? MarkdownSTTextView, styledText.foldPlan != nil {
            view.replacePresentationSnapshot = EditorReplacePresentationSnapshot(
                styledText: styledText,
                coordinator: view.textDelegate as? MarkdownTextViewCoordinator
            )
        } else if let view = textView as? MarkdownSTTextView {
            view.replacePresentationSnapshot = nil
        }
        if styledText.foldPlan != nil,
           let textRange = NSTextRange(targetRange, in: textView.textContentManager)
        {
            textView.textLayoutManager.invalidateLayout(for: textRange)
        }
        textView.needsDisplay = true
        return true
    }

    private static func hasExactAttributes(
        _ attributes: [NSAttributedString.Key: Any],
        in range: NSRange,
        of textStorage: NSTextStorage
    ) -> Bool {
        var effectiveRange = NSRange(location: NSNotFound, length: 0)
        let existing = textStorage.attributes(
            at: range.location,
            longestEffectiveRange: &effectiveRange,
            in: range
        )
        return effectiveRange == range && (existing as NSDictionary).isEqual(to: attributes)
    }

    private static func collectImagePresentationMarkers(
        in textStorage: NSTextStorage,
        range: NSRange
    ) -> [(range: NSRange, marker: WYSIWYGImagePresentationMarker)] {
        var preserved: [(range: NSRange, marker: WYSIWYGImagePresentationMarker)] = []
        guard range.length > 0 else {
            return preserved
        }
        textStorage.enumerateAttribute(
            WYSIWYGImagePresentationMarker.attribute,
            in: range
        ) { value, attributeRange, _ in
            guard let marker = value as? WYSIWYGImagePresentationMarker else {
                return
            }
            preserved.append((attributeRange, marker))
        }
        return preserved
    }

    private static func restoreImagePresentationMarkers(
        _ markers: [(range: NSRange, marker: WYSIWYGImagePresentationMarker)],
        in textStorage: NSTextStorage
    ) {
        for preserved in markers {
            let clamped = preserved.range.clamped(toLength: textStorage.length)
            guard clamped.length > 0 else { continue }
            textStorage.addAttribute(
                WYSIWYGImagePresentationMarker.attribute,
                value: preserved.marker,
                range: clamped
            )
        }
    }
}
