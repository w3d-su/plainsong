import MarkdownCore
import UIKit

/// One native UITextInput replacement. Callers keep the undo group around this write
/// so a format or Replace is a single Undo entry, not a full `text`/`attributedText` reset.
enum IOSNativeTextMutation {
    @MainActor
    static func replace(_ edit: MarkdownEditResult, in textView: UITextView, actionName: String) -> Bool {
        guard let uiRange = IOSTextRanges.textRange(for: edit.replacementRange, in: textView) else {
            return false
        }
        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        textView.replace(uiRange, withText: edit.replacementString)
        if let selection = IOSTextRanges.textRange(for: edit.newSelection, in: textView) {
            textView.selectedTextRange = selection
        }
        // `replace` names the group "Replace"; set the caller label after that registration.
        undoManager?.setActionName(actionName)
        undoManager?.endUndoGrouping()
        return true
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
