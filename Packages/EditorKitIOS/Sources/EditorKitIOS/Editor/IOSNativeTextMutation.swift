import MarkdownCore
import UIKit

/// Exact source mutations integrated with the editor's native undo stack.
enum IOSNativeTextMutation {
    @MainActor
    static func replace(_ edit: MarkdownEditResult, in textView: IOSMarkdownTextView, actionName: String) -> Bool {
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
