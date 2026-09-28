import AppKit
import MarkdownCore
import STTextView

/// Format-menu math commands: menu enablement and the redo-selection fix-up
/// that only these commands register (see `apply(_:to:editingGuard:restoresSelectionOnRedo:)`).
extension EditingBehaviorsSupport {
    static func restoresSelectionOnRedo(_ command: MarkdownEditCommand) -> Bool {
        switch command {
        case .format(.insertInlineMath), .format(.insertDisplayMath):
            true
        default:
            false
        }
    }

    /// Menu enablement for the math commands. Shares the execution-time guards
    /// (`isApplying`, marked text) and the MarkdownCore predicates, so a `true`
    /// flag means the command would edit rather than no-op.
    static func mathCommandAvailability(
        in textView: STTextView,
        editingGuard: EditingBehaviorGuard,
        fileKind: FileKind = .markdown
    ) -> MarkdownMathCommandAvailability {
        guard !editingGuard.isApplying,
              MarkdownEditing.shouldHandleBehavior(hasMarkedText: textView.hasMarkedText())
        else {
            return MarkdownMathCommandAvailability()
        }
        let text = MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
        return MarkdownEditing.mathCommandAvailability(
            in: text,
            selection: textView.selectedRange(),
            fileKind: fileKind
        )
    }

    /// Redo of a math insertion selects the whole inserted string. Re-register
    /// on both undo and redo so a later redo still restores `selection` after
    /// the text action, which runs first.
    static func registerMathCommandSelectionRedo(
        _ selection: NSRange,
        on textView: STTextView
    ) {
        guard let undoManager = textView.undoManager, undoManager.isUndoRegistrationEnabled else { return }
        undoManager.registerUndo(withTarget: textView) { textView in
            registerMathCommandSelectionRedo(selection, on: textView)
            guard textView.undoManager?.isRedoing == true else { return }
            textView.textSelection = selection
        }
    }

    static func currentText(of textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }
}
