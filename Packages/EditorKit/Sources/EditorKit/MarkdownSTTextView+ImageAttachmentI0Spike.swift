import AppKit

extension MarkdownSTTextView {
    /// Non-user-facing I0 mechanism spike. Installs no App/public presentation case and
    /// projects only the hardcoded `![alt](fixture.png)` literal.
    @discardableResult
    func setWYSIWYGImageAttachmentI0SpikeEnabled(_ isEnabled: Bool) -> Bool {
        guard let textContentStorage = textContentManager as? NSTextContentStorage else {
            return false
        }

        if isEnabled {
            let projectionWasAlreadyInstalled = textContentStorage.delegate ===
                wysiwygZeroWidthContentStorageDelegate
            guard setWYSIWYGZeroWidthFoldingEnabled(true),
                  let delegate = wysiwygZeroWidthContentStorageDelegate
            else {
                return false
            }

            if !projectionWasAlreadyInstalled {
                isI0SpikeProjectionOwner = true
            }
            delegate.setImageAttachmentI0SpikeEnabled(true)
            setWYSIWYGImageAttachmentI0SpikeMarker(true)
            textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
            needsDisplay = true
            return true
        }

        wysiwygZeroWidthContentStorageDelegate?.setImageAttachmentI0SpikeEnabled(false)
        setWYSIWYGImageAttachmentI0SpikeMarker(false)
        if isI0SpikeProjectionOwner {
            isI0SpikeProjectionOwner = false
            return setWYSIWYGZeroWidthFoldingEnabled(false)
        }

        textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
        needsDisplay = true
        return true
    }

    func wysiwygImageAttachmentI0SpikeContains(_ offset: Int) -> Bool {
        guard let range = wysiwygImageAttachmentI0SpikeSourceRange() else {
            return false
        }
        return offset >= range.location && offset <= NSMaxRange(range)
    }

    func wysiwygImageAttachmentI0SpikeSourceRange() -> NSRange? {
        guard let textContentStorage = textContentManager as? NSTextContentStorage else {
            return nil
        }
        return wysiwygZeroWidthContentStorageDelegate?
            .imageAttachmentI0SpikeSourceRange(in: textContentStorage)
    }

    func revealWYSIWYGImageAttachmentI0SpikeIfNeeded(at caret: Int) {
        guard wysiwygImageAttachmentI0SpikeContains(caret),
              wysiwygZeroWidthContentStorageDelegate?.revealImageAttachmentI0Spike() == true
        else {
            return
        }

        setWYSIWYGImageAttachmentI0SpikeMarker(false)
        textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
        needsDisplay = true
    }

    func wysiwygImageAttachmentI0SpikeSnappedCaretOffset(
        _ offset: Int,
        preferring direction: WYSIWYGCaretSnap.Direction
    ) -> Int? {
        guard let imageSourceRange = wysiwygImageAttachmentI0SpikeSourceRange(),
              offset > imageSourceRange.location,
              offset < NSMaxRange(imageSourceRange)
        else {
            return nil
        }

        return WYSIWYGCaretSnap.snap(
            offset: offset,
            foldedDelimiterRanges: [imageSourceRange],
            preferring: direction
        )
    }

    func setWYSIWYGImageAttachmentI0SpikeMarker(_ isMarked: Bool) {
        guard let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage else {
            return
        }

        let originalSelection = selectedRange()
        let clipView = enclosingScrollView?.contentView
        let visibleOrigin = clipView?.bounds.origin
        let undoManager = undoManager
        let shouldRestoreUndoRegistration = undoManager?.isUndoRegistrationEnabled == true
        if shouldRestoreUndoRegistration {
            undoManager?.disableUndoRegistration()
        }
        defer {
            if shouldRestoreUndoRegistration {
                undoManager?.enableUndoRegistration()
            }
            if selectedRange() != originalSelection {
                textSelection = originalSelection.clamped(toLength: textStorage.length)
            }
            if let clipView, let visibleOrigin {
                clipView.scroll(to: visibleOrigin)
                enclosingScrollView?.reflectScrolledClipView(clipView)
            }
        }

        let presentation = NSMutableAttributedString(attributedString: textStorage)
        if isMarked {
            let range = (textStorage.string as NSString).range(of: WYSIWYGImageAttachmentI0Spike.source)
            if range.location != NSNotFound {
                presentation.addAttribute(
                    WYSIWYGImageAttachmentI0Spike.markerAttribute,
                    value: true,
                    range: range
                )
            }
        } else if presentation.length > 0 {
            presentation.removeAttribute(
                WYSIWYGImageAttachmentI0Spike.markerAttribute,
                range: NSRange(location: 0, length: presentation.length)
            )
        }

        textStorage.beginEditing()
        presentation.enumerateAttributes(
            in: NSRange(location: 0, length: presentation.length)
        ) { attributes, range, _ in
            textStorage.setAttributes(attributes, range: range)
        }
        textStorage.endEditing()
    }
}
