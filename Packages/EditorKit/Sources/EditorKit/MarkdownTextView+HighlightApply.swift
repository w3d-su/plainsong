import AppKit
import STTextView

@MainActor
extension MarkdownTextView {
    /// Applies highlight attributes while preserving image-presentation markers so a
    /// visible-range recompute does not force a full image-marker rewrite every keystroke.
    static func applyHighlightedTextPreservingImageMarkers(
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
            let currentText = (textStorage.string as NSString).substring(with: targetRange)
            guard currentText == incoming.string else {
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

        textStorage.beginEditing()
        incoming.enumerateAttributes(
            in: NSRange(location: 0, length: incoming.length)
        ) { attributes, range, _ in
            let destinationRange = NSRange(
                location: targetRange.location + range.location,
                length: range.length
            )
            textStorage.setAttributes(attributes, range: destinationRange)
        }
        restoreImagePresentationMarkers(preservedImageMarkers, in: textStorage)
        textStorage.endEditing()
        if styledText.foldPlan != nil,
           let textRange = NSTextRange(targetRange, in: textView.textContentManager)
        {
            textView.textLayoutManager.invalidateLayout(for: textRange)
        }
        textView.needsDisplay = true
        return true
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
