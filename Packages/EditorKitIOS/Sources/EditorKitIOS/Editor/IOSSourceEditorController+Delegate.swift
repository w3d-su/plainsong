import UIKit

public extension IOSSourceEditorController {
    func textViewDidChange(_ textView: UITextView) {
        guard textView === self.textView, !isReconciling, !isMutating else { return }
        noteMarkedTextTransition()
        if textView.markedTextRange != nil {
            rebuildLineIndex()
        } else if let pending = pendingLineEdit {
            pendingLineEdit = nil
            noteLineReplacement(range: pending.range, replacement: pending.replacement)
        } else {
            rebuildLineIndex()
        }
        publishCurrentText()
        scheduleHighlight()
        emitSnapshot()
        noteViewportLine()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard textView === self.textView else { return }
        noteMarkedTextTransition()
        let range = textView.selectedRange
        if isMutating || isReconciling || isAdjustingSelection {
            lastSelection = range
            return
        }
        self.textView.setNeedsLineNumberDisplay()
        guard range != lastSelection else { return }
        lastSelection = range
        selectionGeneration &+= 1
        emitSnapshot()
    }

    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        guard textView === self.textView else { return false }
        if isMutating || isReconciling {
            return true
        }
        let allow = !consumeReplacement(text, range: range)
        if allow {
            pendingLineEdit = (range: range, replacement: text)
        }
        return allow
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === textView, textView.viewportOverride == nil, !isReconciling else { return }
        textView.setNeedsLineNumberDisplay()
        noteViewportLine()
        let viewport = IOSViewport.visibleUTF16Range(in: textView)
        guard viewport != lastSelectionViewport else { return }
        lastSelectionViewport = viewport
        scheduleHighlight()
    }

    internal func noteMarkedTextTransition() {
        noteMarkedText(textView.markedTextRange != nil)
    }

    internal func noteMarkedText(_ marked: Bool) {
        let ended = hadMarkedText && !marked
        hadMarkedText = marked
        guard ended else { return }
        if needsBaseStyle {
            applyBaseTextStyle()
            raisePresentationFloor()
        }
        scheduleHighlight()
    }
}
