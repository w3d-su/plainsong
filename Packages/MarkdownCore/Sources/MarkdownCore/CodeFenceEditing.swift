import Foundation

enum CodeFenceEditing {
    static func handleEnter(in text: String, selection: NSRange) -> MarkdownEditResult? {
        guard selection.length == 0 else { return nil }

        let line = MarkdownTextEditingSupport.line(containing: selection.location, in: text)
        let beforeCursorRange = NSRange(location: line.range.location, length: selection.location - line.range.location)
        let afterCursorRange = NSRange(location: selection.location, length: line.endLocation - selection.location)
        let beforeCursor = MarkdownTextEditingSupport.substring(beforeCursorRange, in: text)
        let afterCursor = MarkdownTextEditingSupport.substring(afterCursorRange, in: text)
        let indentLength = MarkdownTextEditingSupport.leadingWhitespaceLength(in: line.text)
        let indentRange = NSRange(location: 0, length: indentLength)
        let indent = (line.text as NSString).substring(with: indentRange)

        guard MarkdownTextEditingSupport.trimSpaces(beforeCursor) == "```",
              MarkdownTextEditingSupport.isBlank(afterCursor),
              !isClosingFence(line, in: text)
        else {
            return nil
        }

        let replacement = "\n\(indent)\n\(indent)```"
        return MarkdownTextEditingSupport.replacement(
            range: selection,
            string: replacement,
            selection: NSRange(
                location: selection.location + 1 + MarkdownTextEditingSupport.utf16Length(indent),
                length: 0
            )
        )
    }

    private static func isClosingFence(_ currentLine: MarkdownLine, in text: String) -> Bool {
        var cursor = 0
        var hasOpenFence = false

        while cursor < currentLine.range.location {
            let line = MarkdownTextEditingSupport.line(containing: cursor, in: text)
            if isBacktickFenceLine(line.text) {
                hasOpenFence.toggle()
            }

            guard line.fullEndLocation > cursor else { break }
            cursor = line.fullEndLocation
        }

        return hasOpenFence
    }

    private static func isBacktickFenceLine(_ line: String) -> Bool {
        MarkdownTextEditingSupport.trimSpaces(line).hasPrefix("```")
    }
}
