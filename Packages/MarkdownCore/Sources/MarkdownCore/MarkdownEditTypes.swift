import Foundation

public struct MarkdownEditResult: Equatable, Sendable {
    public let replacementRange: NSRange
    public let replacementString: String
    public let newSelection: NSRange

    public init(replacementRange: NSRange, replacementString: String, newSelection: NSRange) {
        self.replacementRange = replacementRange
        self.replacementString = replacementString
        self.newSelection = newSelection
    }
}

public enum MarkdownFormattingCommand: Equatable, Sendable {
    case bold
    case italic
    case strikethrough
    case inlineCode
    case link
    case heading(level: Int)
    case paragraph
    case quote
    case codeFence
}

public enum MarkdownEditCommand: Equatable, Sendable {
    case insertNewline(fileKind: FileKind)
    case insertTab(backwards: Bool)
    case type(String, fileKind: FileKind)
    case toggleCheckbox
    case formatTable
    case format(MarkdownFormattingCommand)
}

public enum MarkdownEditing {
    public static func shouldHandleBehavior(hasMarkedText: Bool) -> Bool {
        !hasMarkedText
    }

    public static func apply(
        _ command: MarkdownEditCommand,
        to text: String,
        selection: NSRange
    ) -> MarkdownEditResult? {
        switch command {
        case let .insertNewline(fileKind):
            TableEditing.handleEnter(in: text, selection: selection)
                ?? CodeFenceEditing.handleEnter(in: text, selection: selection)
                ?? ListEditing.handleEnter(in: text, selection: selection, fileKind: fileKind)
        case let .insertTab(backwards):
            TableEditing.handleTab(in: text, selection: selection, backwards: backwards)
                ?? ListEditing.handleTab(in: text, selection: selection, backwards: backwards)
        case let .type(input, fileKind):
            AutoPairing.handleTyping(input, in: text, selection: selection, fileKind: fileKind)
        case .toggleCheckbox:
            CheckboxEditing.toggle(in: text, selection: selection)
        case .formatTable:
            TableEditing.format(in: text, selection: selection)
        case let .format(command):
            FormattingEditing.apply(command, to: text, selection: selection)
        }
    }
}
