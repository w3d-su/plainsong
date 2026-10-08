import UIKit

public extension IOSSourceEditorController {
    func textViewDidChange(_ textView: UITextView) {
        guard textView === self.textView, !isReconciling, !isMutating else { return }
        noteMarkedTextTransition()
        publishCurrentText()
        scheduleHighlight()
        emitSnapshot()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard textView === self.textView else { return }
        noteMarkedTextTransition()
        let range = textView.selectedRange
        if isMutating || isReconciling || isAdjustingSelection {
            lastSelection = range
            return
        }
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
        return !consumeReplacement(text, range: range)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === textView, textView.viewportOverride == nil, !isReconciling else { return }
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
        scheduleHighlight()
    }
}
