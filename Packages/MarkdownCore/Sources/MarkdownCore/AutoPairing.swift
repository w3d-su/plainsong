import Foundation

enum AutoPairing {
    static func handleTyping(
        _ input: String,
        in text: String,
        selection: NSRange,
        fileKind: FileKind
    ) -> MarkdownEditResult? {
        guard MarkdownTextEditingSupport.utf16Length(input) == 1 else { return nil }

        if let skip = skipOverClosing(input, in: text, selection: selection, fileKind: fileKind) {
            return skip
        }

        guard let pair = pair(for: input, fileKind: fileKind) else { return nil }

        if selection.length > 0 {
            let selected = MarkdownTextEditingSupport.substring(selection, in: text)
            let replacement = pair.open + selected + pair.close
            return MarkdownTextEditingSupport.replacement(
                range: selection,
                string: replacement,
                selection: NSRange(
                    location: selection.location + MarkdownTextEditingSupport.utf16Length(pair.open),
                    length: selection.length
                )
            )
        }

        let replacement = pair.open + pair.close
        return MarkdownTextEditingSupport.replacement(
            range: selection,
            string: replacement,
            selection: NSRange(
                location: selection.location + MarkdownTextEditingSupport.utf16Length(pair.open),
                length: 0
            )
        )
    }

    private static func skipOverClosing(
        _ input: String,
        in text: String,
        selection: NSRange,
        fileKind: FileKind
    ) -> MarkdownEditResult? {
        guard selection.length == 0 else { return nil }

        let closings = closingTokens(for: input, fileKind: fileKind)
        guard let token = closings.first(where: { MarkdownTextEditingSupport.hasString(
            $0,
            at: selection.location,
            in: text
        ) }) else {
            return nil
        }

        return MarkdownTextEditingSupport.replacement(
            range: selection,
            string: "",
            selection: NSRange(location: selection.location + MarkdownTextEditingSupport.utf16Length(token), length: 0)
        )
    }

    private static func pair(for input: String, fileKind: FileKind) -> (open: String, close: String)? {
        switch input {
        case "*":
            ("**", "**")
        case "_":
            ("_", "_")
        case "`":
            ("`", "`")
        case "(":
            ("(", ")")
        case "[":
            ("[", "]")
        case "{":
            ("{", "}")
        case "\"":
            ("\"", "\"")
        case "<" where fileKind == .mdx:
            ("<", ">")
        default:
            nil
        }
    }

    private static func closingTokens(for input: String, fileKind: FileKind) -> [String] {
        switch input {
        case "*":
            ["**", "*"]
        case "_":
            ["_"]
        case "`":
            ["`"]
        case ")":
            [")"]
        case "]":
            ["]"]
        case "}":
            ["}"]
        case "\"":
            ["\""]
        case ">" where fileKind == .mdx:
            [">"]
        default:
            []
        }
    }
}
