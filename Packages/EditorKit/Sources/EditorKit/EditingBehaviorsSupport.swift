import AppKit
import MarkdownCore
import STTextView

final class EditingBehaviorGuard {
    var isApplying = false
}

@MainActor
public final class EditorCommandProxy: ObservableObject {
    private weak var textView: STTextView?
    private var fileKind: FileKind = .markdown
    private var performCommand: ((MarkdownEditCommand) -> Void)?

    public init() {}

    public func perform(_ command: MarkdownEditCommand) {
        guard textView != nil else { return }
        performCommand?(command)
    }

    public func update(fileKind: FileKind) {
        self.fileKind = fileKind
    }

    func attach(
        to textView: STTextView,
        fileKind: FileKind,
        performCommand: @escaping (MarkdownEditCommand) -> Void
    ) {
        self.textView = textView
        self.fileKind = fileKind
        self.performCommand = performCommand
    }

    func detach(from textView: STTextView) {
        if self.textView === textView {
            self.textView = nil
            performCommand = nil
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
        editingGuard: EditingBehaviorGuard
    ) -> Bool {
        guard !editingGuard.isApplying else { return true }
        guard MarkdownEditing.shouldHandleBehavior(hasMarkedText: textView.hasMarkedText()) else { return true }
        guard let replacementString,
              needsMarkdownEvaluation(for: replacementString, fileKind: fileKind),
              let command = command(for: replacementString, fileKind: fileKind),
              let selection = nsRange(for: affectedRange, in: textView)
        else {
            return true
        }

        guard let edit = edit(for: command, textView: textView, selection: selection) else {
            return true
        }

        apply(edit, to: textView, editingGuard: editingGuard)
        return false
    }

    static func applyCommand(
        _ command: MarkdownEditCommand,
        to textView: STTextView,
        editingGuard: EditingBehaviorGuard
    ) {
        guard !editingGuard.isApplying else { return }
        guard MarkdownEditing.shouldHandleBehavior(hasMarkedText: textView.hasMarkedText()) else { return }
        let selection = textView.selectedRange()
        guard let edit = edit(for: command, textView: textView, selection: selection) else { return }

        apply(edit, to: textView, editingGuard: editingGuard)
    }

    static func needsMarkdownEvaluation(for replacementString: String, fileKind: FileKind) -> Bool {
        switch replacementString {
        case "\n", "\r", "\u{2028}", "\u{2029}", "\t", "\u{19}":
            true
        case "*", "_", "`", "(", "[", "{", "\"", ")", "]", "}":
            true
        case "<" where fileKind == .mdx:
            true
        case ">" where fileKind == .mdx:
            true
        default:
            false
        }
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
        editingGuard: EditingBehaviorGuard
    ) {
        if edit.replacementRange.length == 0, edit.replacementString.isEmpty {
            textView.textSelection = edit.newSelection
            return
        }

        // Keep this as direct reference-state mutation. STTextView synchronously
        // re-enters shouldChangeText during insertText, so an inout guard here traps.
        editingGuard.isApplying = true
        textView.insertText(edit.replacementString, replacementRange: edit.replacementRange)
        editingGuard.isApplying = false
        textView.textSelection = edit.newSelection
    }

    private static func nsRange(for textRange: NSTextRange, in textView: STTextView) -> NSRange? {
        let range = NSRange(textRange, in: textView.textContentManager)
        return range.location == NSNotFound ? nil : range
    }
}
