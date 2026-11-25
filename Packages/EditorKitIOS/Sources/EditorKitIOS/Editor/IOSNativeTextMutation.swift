import MarkdownCore
import UIKit

/// Exact source mutations integrated with the editor's native undo stack.
enum IOSNativeTextMutation {
    @MainActor
    static func replaceAsInput(_ edit: MarkdownEditResult, in textView: UITextView, actionName: String) -> Bool {
        guard let range = IOSTextRanges.textRange(for: edit.replacementRange, in: textView) else { return false }
        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        textView.replace(range, withText: edit.replacementString)
        if let selection = IOSTextRanges.textRange(for: edit.newSelection, in: textView) {
            textView.selectedTextRange = selection
        }
        undoManager?.setActionName(actionName)
        undoManager?.endUndoGrouping()
        return true
    }

    @MainActor
    static func replaceExactly(_ edit: MarkdownEditResult, in textView: IOSMarkdownTextView,
                               actionName: String) -> Bool
    {
        guard let original = IOSTextRanges.substring(textView.textStorage.string, range: edit.replacementRange) else {
            return false
        }
        let inverse = MarkdownEditResult(
            replacementRange: NSRange(
                location: edit.replacementRange.location,
                length: IOSTextRanges.utf16Length(of: edit.replacementString)
            ),
            replacementString: original,
            newSelection: textView.selectedRange
        )
        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        apply(edit, inverse: inverse, in: textView, actionName: actionName)
        undoManager?.endUndoGrouping()
        return true
    }

    @MainActor
    private static func apply(
        _ edit: MarkdownEditResult, inverse: MarkdownEditResult, in textView: IOSMarkdownTextView, actionName: String
    ) {
        guard IOSTextRanges.contains(edit.replacementRange, length: textView.textStorage.length) else { return }
        let undoManager = textView.undoManager
        undoManager?.registerUndo(withTarget: textView) { view in
            MainActor.assumeIsolated {
                guard view.editor?.canUseHistory() == true else {
                    view.discardHistoryAfterReplay()
                    return
                }
                apply(inverse, inverse: edit, in: view, actionName: actionName)
            }
        }
        undoManager?.setActionName(actionName)

        // UITextInput.replace can smarten punctuation outside the edit when the keyboard is offscreen.
        textView.suppressesUndoRegistration = true
        textView.textStorage.replaceCharacters(in: edit.replacementRange, with: edit.replacementString)
        textView.suppressesUndoRegistration = false
        textView.selectedRange = edit.newSelection
        textView.delegate?.textViewDidChange?(textView)
    }

    /// Reconciliation install. Writes the text storage directly so this is not a user command
    /// and the input system cannot rewrite characters such as `---`.
    @MainActor
    static func replaceBufferWithoutUndo(_ text: String, in textView: UITextView) -> Bool {
        let markdownView = textView as? IOSMarkdownTextView
        markdownView?.suppressesUndoRegistration = true
        let storage = textView.textStorage
        let range = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: text)
        storage.endEditing()
        markdownView?.suppressesUndoRegistration = false
        return true
    }
}

extension IOSMarkdownTextView {
    /// Clears the history once the undo or redo in progress has closed its group. Clearing
    /// it from inside the replay would remove the group UIKit is still about to end.
    func discardHistoryAfterReplay() {
        guard let manager = undoManager else { return }
        let name: Notification.Name = manager.isUndoing ? .NSUndoManagerDidUndoChange : .NSUndoManagerDidRedoChange
        let center = NotificationCenter.default
        center.removeObserver(self, name: name, object: manager)
        center.addObserver(self, selector: #selector(discardStaleHistory), name: name, object: manager)
    }

    @objc private func discardStaleHistory(_ notification: Notification) {
        guard let manager = notification.object as? UndoManager else { return }
        NotificationCenter.default.removeObserver(self, name: notification.name, object: manager)
        // The refused entry was already consumed. Older ranges no longer describe the buffer.
        manager.removeAllActions()
    }
}
