import Foundation

enum CheckboxEditing {
    static func toggle(in text: String, selection: NSRange) -> MarkdownEditResult? {
        let lines = MarkdownTextEditingSupport.lines(overlapping: selection, in: text)
        guard let firstLine = lines.first, let lastLine = lines.last else { return nil }

        let replacementRange = NSRange(
            location: firstLine.range.location,
            length: lastLine.range.location + lastLine.range.length - firstLine.range.location
        )
        let original = MarkdownTextEditingSupport.substring(replacementRange, in: text)
        let transformedLines = original
            .components(separatedBy: "\n")
            .map(toggleLine)
        let replacement = transformedLines.joined(separator: "\n")

        guard replacement != original else { return nil }

        if selection.length == 0 {
            let deltaBeforeCursor = MarkdownTextEditingSupport.utf16Length(replacement) -
                MarkdownTextEditingSupport.utf16Length(original)
            return MarkdownTextEditingSupport.replacement(
                range: replacementRange,
                string: replacement,
                selection: NSRange(
                    location: max(replacementRange.location, selection.location + deltaBeforeCursor),
                    length: 0
                )
            )
        }

        return MarkdownTextEditingSupport.replacement(
            range: replacementRange,
            string: replacement,
            selection: NSRange(
                location: replacementRange.location,
                length: MarkdownTextEditingSupport.utf16Length(replacement)
            )
        )
    }

    private static func toggleLine(_ line: String) -> String {
        guard let item = MarkdownListItem(line) else {
            if MarkdownTextEditingSupport.isBlank(line) {
                return "- [ ] "
            }
            return "- [ ] \(line)"
        }

        if item.hasCheckbox {
            let storage = line as NSString
            let prefix = storage.substring(with: NSRange(location: 0, length: item.prefixLength))
            let toggledPrefix: String = if item.checkboxState == " " {
                prefix.replacingOccurrences(of: "[ ]", with: "[x]", options: [], range: nil)
            } else {
                prefix
                    .replacingOccurrences(of: "[x]", with: "[ ]", options: [], range: nil)
                    .replacingOccurrences(of: "[X]", with: "[ ]", options: [], range: nil)
            }
            return toggledPrefix + storage.substring(from: item.prefixLength)
        }

        let storage = line as NSString
        let prefix = storage.substring(with: NSRange(location: 0, length: item.prefixLength))
        return "\(prefix)[ ] \(storage.substring(from: item.prefixLength))"
    }
}
