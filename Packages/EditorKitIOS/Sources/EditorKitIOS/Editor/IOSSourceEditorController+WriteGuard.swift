import MarkdownCore
import UIKit

extension IOSSourceEditorController {
    /// The source as a native UTF-8 string, for anything that leaves the editor
    /// (agent.md §12). The bridged storage string is the fallback only for text a native
    /// string cannot hold exactly (an unpaired surrogate).
    func nativeSourceText() -> String {
        ExactSourceText.nativeCopy(of: textView.textStorage.mutableString) ?? plainText()
    }

    /// True while the text view must not take keyboard or composition input: no document,
    /// or one that is not writable (a conflict fence, a revoked grant, a transition).
    /// The editor's own writes do not come through `insertText` or `setMarkedText`.
    var refusesNativeInput: Bool {
        guard isHostAlive, !isMutating, !isReconciling else { return false }
        return installation?.canWrite != true
    }

    /// Last line of the write fence. Native paths that never ask the editor first (shake
    /// or three-finger undo, a hardware Command-Z, drag and drop, dictation) have already
    /// changed the buffer when `textViewDidChange` runs. The session is not writable, so
    /// the buffer goes back to the session text instead of the session taking the edit.
    func restoreSessionTextAfterRefusedNativeEdit(_ session: DocumentSession) {
        guard !ExactSourceFragment.matches(plainText(), session.text) else { return }
        isReconciling = true
        defer { isReconciling = false }
        if textView.markedTextRange != nil {
            textView.unmarkText()
        }
        let selected = textView.selectedRange
        _ = IOSNativeTextMutation.replaceBufferWithoutUndo(session.text, in: textView)
        // The history now describes a buffer that was put back underneath it. A native undo
        // or redo calls this from inside its own replay, so the clear waits for it to end.
        if let manager = textView.undoManager, manager.isUndoing || manager.isRedoing {
            textView.discardHistoryAfterReplay()
        } else {
            textView.undoManager?.removeAllActions()
        }
        isAdjustingSelection = true
        textView.selectedRange = IOSTextRanges.clamped(selected, length: textView.textStorage.length)
        isAdjustingSelection = false
        selectionGeneration &+= 1
        lastSelection = textView.selectedRange
        raisePresentationFloor()
        clearInheritedPresentation()
        rebuildLineIndex()
    }

    /// Ends a composition whose next keystroke was refused. Dropping that input alone would
    /// leave the view marked with an input method that has moved on: highlighting, gutter
    /// chrome and statistics stay deferred, and edits are refused with `.markedText` after
    /// access returns. The session already holds the composing text, so it stays. A
    /// composition nobody types into is left alone: a reload that is deferred behind it
    /// applies when it ends.
    func endCompositionAfterRefusedInput() {
        guard textView.markedTextRange != nil, let session = installation?.session else { return }
        isReconciling = true
        textView.unmarkText()
        isReconciling = false
        restoreSessionTextAfterRefusedNativeEdit(session)
    }

    /// Replaces the buffer for another document. A whole-buffer replacement inherits the
    /// attributes of the previous first character; a heading there would style the new
    /// document until each part scrolls into a highlighted viewport.
    func replaceBufferClearingPresentation(_ text: String) {
        _ = IOSNativeTextMutation.replaceBufferWithoutUndo(text, in: textView)
        clearInheritedPresentation()
    }

    func clearInheritedPresentation() {
        IOSHighlightPresenter.clearOwnedAttributes(
            in: NSRange(location: 0, length: textView.textStorage.length),
            of: textView,
            theme: theme
        )
    }

    /// A gutter width change moves the text container inset, which relays out the text
    /// and ends a composition (Zhuyin). `noteMarkedText` applies it when marking ends.
    func defersLineNumberChromeForComposition() -> Bool {
        needsLineNumberChrome = textView.markedTextRange != nil
        return needsLineNumberChrome
    }
}
