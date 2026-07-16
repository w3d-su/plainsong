import AppKit
import MarkdownCore
import STTextView

final class EditingBehaviorGuard {
    var isApplying = false
}

enum EditingBehaviorProposal {
    case allowNativeInput
    case selectionOnly(MarkdownEditResult)
    case textMutation(MarkdownEditResult)
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
        EditorCommandResponderRegistry.attach(to: textView, performCommand: performCommand)
    }

    func detach(from textView: STTextView) {
        if self.textView === textView {
            self.textView = nil
            performCommand = nil
            EditorCommandResponderRegistry.detach(from: textView)
        }
    }

    func currentFileKind() -> FileKind {
        fileKind
    }
}

@MainActor
public enum EditorCommandDispatcher {
    public static func perform(_ command: MarkdownEditCommand) {
        NSApp.sendAction(selector(for: command), to: nil, from: nil)
    }

    // Intentional flat mapping from public edit commands to responder-chain selectors.
    // swiftlint:disable:next cyclomatic_complexity
    private static func selector(for command: MarkdownEditCommand) -> Selector {
        switch command {
        case .format(.bold):
            #selector(STTextView.plainsongFormatBold(_:))
        case .format(.italic):
            #selector(STTextView.plainsongFormatItalic(_:))
        case .format(.strikethrough):
            #selector(STTextView.plainsongFormatStrikethrough(_:))
        case .format(.inlineCode):
            #selector(STTextView.plainsongFormatInlineCode(_:))
        case .format(.link):
            #selector(STTextView.plainsongFormatLink(_:))
        case .format(.heading(level: 1)):
            #selector(STTextView.plainsongFormatHeading1(_:))
        case .format(.heading(level: 2)):
            #selector(STTextView.plainsongFormatHeading2(_:))
        case .format(.heading(level: 3)):
            #selector(STTextView.plainsongFormatHeading3(_:))
        case .format(.heading(level: 4)):
            #selector(STTextView.plainsongFormatHeading4(_:))
        case .format(.heading(level: 5)):
            #selector(STTextView.plainsongFormatHeading5(_:))
        case .format(.heading(level: 6)):
            #selector(STTextView.plainsongFormatHeading6(_:))
        case .format(.paragraph):
            #selector(STTextView.plainsongFormatParagraph(_:))
        case .format(.quote):
            #selector(STTextView.plainsongFormatQuote(_:))
        case .format(.codeFence):
            #selector(STTextView.plainsongFormatCodeFence(_:))
        case .toggleCheckbox:
            #selector(STTextView.plainsongToggleCheckbox(_:))
        case .formatTable:
            #selector(STTextView.plainsongFormatTable(_:))
        case .insertNewline, .insertTab, .type, .format(.heading):
            #selector(STTextView.plainsongNoopCommand(_:))
        }
    }
}

@MainActor
private enum EditorCommandResponderRegistry {
    private final class Route {
        let performCommand: (MarkdownEditCommand) -> Void

        init(performCommand: @escaping (MarkdownEditCommand) -> Void) {
            self.performCommand = performCommand
        }
    }

    private static var routes: [ObjectIdentifier: Route] = [:]

    static func attach(
        to textView: STTextView,
        performCommand: @escaping (MarkdownEditCommand) -> Void
    ) {
        routes[ObjectIdentifier(textView)] = Route(performCommand: performCommand)
    }

    static func detach(from textView: STTextView) {
        routes[ObjectIdentifier(textView)] = nil
    }

    static func perform(_ command: MarkdownEditCommand, in textView: STTextView) {
        routes[ObjectIdentifier(textView)]?.performCommand(command)
    }
}

@MainActor
extension STTextView {
    @objc func plainsongFormatBold(_ sender: Any?) {
        plainsongPerform(.format(.bold), sender: sender)
    }

    @objc func plainsongFormatItalic(_ sender: Any?) {
        plainsongPerform(.format(.italic), sender: sender)
    }

    @objc func plainsongFormatStrikethrough(_ sender: Any?) {
        plainsongPerform(.format(.strikethrough), sender: sender)
    }

    @objc func plainsongFormatInlineCode(_ sender: Any?) {
        plainsongPerform(.format(.inlineCode), sender: sender)
    }

    @objc func plainsongFormatLink(_ sender: Any?) {
        plainsongPerform(.format(.link), sender: sender)
    }

    @objc func plainsongFormatHeading1(_ sender: Any?) {
        plainsongPerform(.format(.heading(level: 1)), sender: sender)
    }

    @objc func plainsongFormatHeading2(_ sender: Any?) {
        plainsongPerform(.format(.heading(level: 2)), sender: sender)
    }

    @objc func plainsongFormatHeading3(_ sender: Any?) {
        plainsongPerform(.format(.heading(level: 3)), sender: sender)
    }

    @objc func plainsongFormatHeading4(_ sender: Any?) {
        plainsongPerform(.format(.heading(level: 4)), sender: sender)
    }

    @objc func plainsongFormatHeading5(_ sender: Any?) {
        plainsongPerform(.format(.heading(level: 5)), sender: sender)
    }

    @objc func plainsongFormatHeading6(_ sender: Any?) {
        plainsongPerform(.format(.heading(level: 6)), sender: sender)
    }

    @objc func plainsongFormatParagraph(_ sender: Any?) {
        plainsongPerform(.format(.paragraph), sender: sender)
    }

    @objc func plainsongFormatQuote(_ sender: Any?) {
        plainsongPerform(.format(.quote), sender: sender)
    }

    @objc func plainsongFormatCodeFence(_ sender: Any?) {
        plainsongPerform(.format(.codeFence), sender: sender)
    }

    @objc func plainsongToggleCheckbox(_ sender: Any?) {
        plainsongPerform(.toggleCheckbox, sender: sender)
    }

    @objc func plainsongFormatTable(_ sender: Any?) {
        plainsongPerform(.formatTable, sender: sender)
    }

    @objc func plainsongNoopCommand(_: Any?) {}

    private func plainsongPerform(_ command: MarkdownEditCommand, sender _: Any?) {
        EditorCommandResponderRegistry.perform(command, in: self)
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
        let proposal = proposedChange(
            in: textView,
            affectedRange: affectedRange,
            replacementString: replacementString,
            fileKind: fileKind,
            editingGuard: editingGuard
        )
        return apply(proposal, to: textView, editingGuard: editingGuard)
    }

    static func proposedChange(
        in textView: STTextView,
        affectedRange: NSTextRange,
        replacementString: String?,
        fileKind: FileKind,
        editingGuard: EditingBehaviorGuard
    ) -> EditingBehaviorProposal {
        guard !editingGuard.isApplying else { return .allowNativeInput }
        guard MarkdownEditing.shouldHandleBehavior(hasMarkedText: textView.hasMarkedText()) else {
            return .allowNativeInput
        }
        guard let replacementString,
              needsMarkdownEvaluation(for: replacementString, fileKind: fileKind),
              let command = command(for: replacementString, fileKind: fileKind),
              let selection = nsRange(for: affectedRange, in: textView)
        else {
            return .allowNativeInput
        }

        guard let edit = edit(for: command, textView: textView, selection: selection) else {
            return .allowNativeInput
        }

        return proposal(for: edit)
    }

    static func apply(
        _ proposal: EditingBehaviorProposal,
        to textView: STTextView,
        editingGuard: EditingBehaviorGuard
    ) -> Bool {
        switch proposal {
        case .allowNativeInput:
            return true
        case let .selectionOnly(edit):
            textView.textSelection = edit.newSelection
            return false
        case let .textMutation(edit):
            apply(edit, to: textView, editingGuard: editingGuard)
            return false
        }
    }

    static func applyCommand(
        _ command: MarkdownEditCommand,
        to textView: STTextView,
        editingGuard: EditingBehaviorGuard
    ) {
        guard let proposal = proposedCommand(
            command,
            in: textView,
            editingGuard: editingGuard
        ) else {
            return
        }

        _ = apply(proposal, to: textView, editingGuard: editingGuard)
    }

    static func proposedCommand(
        _ command: MarkdownEditCommand,
        in textView: STTextView,
        editingGuard: EditingBehaviorGuard
    ) -> EditingBehaviorProposal? {
        guard !editingGuard.isApplying else { return nil }
        guard MarkdownEditing.shouldHandleBehavior(hasMarkedText: textView.hasMarkedText()) else { return nil }
        let selection = textView.selectedRange()
        guard let edit = edit(for: command, textView: textView, selection: selection) else { return nil }

        return proposal(for: edit)
    }

    static func applyReplacement(
        _ replacementString: String,
        replacementRange: NSRange,
        newSelection: NSRange,
        to textView: STTextView,
        editingGuard: EditingBehaviorGuard
    ) {
        let edit = MarkdownEditResult(
            replacementRange: replacementRange,
            replacementString: replacementString,
            newSelection: newSelection
        )
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

    private static func proposal(for edit: MarkdownEditResult) -> EditingBehaviorProposal {
        if edit.replacementRange.length == 0, edit.replacementString.isEmpty {
            return .selectionOnly(edit)
        }
        return .textMutation(edit)
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
        defer { editingGuard.isApplying = false }
        textView.insertText(edit.replacementString, replacementRange: edit.replacementRange)
        textView.textSelection = edit.newSelection
    }

    private static func nsRange(for textRange: NSTextRange, in textView: STTextView) -> NSRange? {
        let range = NSRange(textRange, in: textView.textContentManager)
        return range.location == NSNotFound ? nil : range
    }
}
