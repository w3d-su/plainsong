import AppKit
import MarkdownCore
import STTextView

/// Format-menu math commands: no-op detection for feedback and the redo-selection
/// fix-up that only these commands register (see
/// `apply(_:to:editingGuard:restoresSelectionOnRedo:)`).
extension EditingBehaviorsSupport {
    static func isMathCommand(_ command: MarkdownEditCommand) -> Bool {
        switch command {
        case .format(.insertInlineMath), .format(.insertDisplayMath):
            true
        default:
            false
        }
    }

    static func restoresSelectionOnRedo(_ command: MarkdownEditCommand) -> Bool {
        isMathCommand(command)
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
