import Foundation
import MarkdownCore

enum IOSEditorBehavior {
    static func needsEvaluation(_ replacement: String, fileKind: FileKind) -> Bool {
        switch replacement {
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

    static func command(for replacement: String, fileKind: FileKind) -> MarkdownEditCommand? {
        switch replacement {
        case "\n", "\r", "\u{2028}", "\u{2029}":
            .insertNewline(fileKind: fileKind)
        case "\t":
            .insertTab(backwards: false)
        case "\u{19}":
            .insertTab(backwards: true)
        default:
            .type(replacement, fileKind: fileKind)
        }
    }

    static func undoActionName(for command: MarkdownEditCommand) -> String {
        switch command {
        case .insertNewline:
            "New Line"
        case let .insertTab(backwards):
            backwards ? "Outdent" : "Indent"
        case .type:
            "Typing"
        case .toggleCheckbox:
            "Checkbox"
        case .formatTable:
            "Format Table"
        case .format:
            "Format"
        }
    }
}
