import AppKit
import MarkdownCore
import STTextView

@MainActor
public final class EditorCommandProxy: ObservableObject {
    private weak var textView: STTextView?
    private var fileKind: FileKind = .markdown

    public init() {}

    public func perform(_ command: MarkdownEditCommand) {
        guard let textView else { return }
        EditingBehaviorsSupport.applyCommand(command, to: textView)
    }

    public func update(fileKind: FileKind) {
        self.fileKind = fileKind
    }

    func attach(to textView: STTextView, fileKind: FileKind) {
        self.textView = textView
        self.fileKind = fileKind
    }

    func detach(from textView: STTextView) {
        if self.textView === textView {
            self.textView = nil
        }
    }

    func currentFileKind() -> FileKind {
        fileKind
    }
}

@MainActor
enum EditingBehaviorsSupport {
    static func handleProposedChange(
        in textView: STTextView,
        affectedRange: NSTextRange,
        replacementString: String?,
        fileKind: FileKind,
        isApplyingEdit: inout Bool
    ) -> Bool {
        guard !isApplyingEdit else { return true }
        guard MarkdownEditing.shouldHandleBehavior(hasMarkedText: textView.hasMarkedText()) else { return true }
        guard let replacementString,
              let command = command(for: replacementString, fileKind: fileKind),
              let selection = nsRange(for: affectedRange, in: textView)
        else {
            return true
        }

        guard let edit = edit(for: command, textView: textView, selection: selection) else {
            return true
        }

        apply(edit, to: textView, isApplyingEdit: &isApplyingEdit)
        return false
    }

    static func applyCommand(_ command: MarkdownEditCommand, to textView: STTextView) {
        guard MarkdownEditing.shouldHandleBehavior(hasMarkedText: textView.hasMarkedText()) else { return }
        let selection = textView.selectedRange()
        guard let edit = edit(for: command, textView: textView, selection: selection) else { return }

        var isApplyingEdit = false
        apply(edit, to: textView, isApplyingEdit: &isApplyingEdit)
    }

    private static func command(for replacementString: String, fileKind: FileKind) -> MarkdownEditCommand? {
        switch replacementString {
        case "\n", "\r", "\u{2028}", "\u{2029}":
            .insertNewline(fileKind: fileKind)
        case "\t":
            .insertTab(backwards: false)
        case "\u{19}":
            .insertTab(backwards: true)
        default:
            .type(replacementString, fileKind: fileKind)
        }
    }

    private static func edit(
        for command: MarkdownEditCommand,
        textView: STTextView,
        selection: NSRange
    ) -> MarkdownEditResult? {
        let text = MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
        return MarkdownEditing.apply(command, to: text, selection: selection)
    }

    private static func apply(
        _ edit: MarkdownEditResult,
        to textView: STTextView,
        isApplyingEdit: inout Bool
    ) {
        if edit.replacementRange.length == 0, edit.replacementString.isEmpty {
            textView.textSelection = edit.newSelection
            return
        }

        isApplyingEdit = true
        textView.insertText(edit.replacementString, replacementRange: edit.replacementRange)
        isApplyingEdit = false
        textView.textSelection = edit.newSelection
    }

    private static func nsRange(for textRange: NSTextRange, in textView: STTextView) -> NSRange? {
        let range = NSRange(textRange, in: textView.textContentManager)
        return range.location == NSNotFound ? nil : range
    }
}
