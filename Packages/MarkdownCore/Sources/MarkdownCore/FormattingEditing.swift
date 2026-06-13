import Foundation

enum FormattingEditing {
    static func apply(
        _ command: MarkdownFormattingCommand,
        to text: String,
        selection: NSRange
    ) -> MarkdownEditResult? {
        switch command {
        case .bold:
            toggleDelimiter("**", in: text, selection: selection)
        case .italic:
            toggleDelimiter("*", in: text, selection: selection)
        case .strikethrough:
            toggleDelimiter("~~", in: text, selection: selection)
        case .inlineCode:
            toggleDelimiter("`", in: text, selection: selection)
        case .link:
            toggleLink(in: text, selection: selection)
        case let .heading(level):
            toggleHeading(level: level, in: text, selection: selection)
        case .paragraph:
            stripHeading(in: text, selection: selection)
        case .quote:
            toggleQuote(in: text, selection: selection)
        case .codeFence:
            toggleCodeFence(in: text, selection: selection)
        }
    }

    private static func toggleDelimiter(
        _ delimiter: String,
        in text: String,
        selection: NSRange
    ) -> MarkdownEditResult? {
        let delimiterLength = MarkdownTextEditingSupport.utf16Length(delimiter)

        if selection.length == 0 {
            let replacement = delimiter + delimiter
            return MarkdownTextEditingSupport.replacement(
                range: selection,
                string: replacement,
                selection: NSRange(location: selection.location + delimiterLength, length: 0)
            )
        }

        if selection.length >= delimiterLength * 2 {
            let selected = MarkdownTextEditingSupport.substring(selection, in: text)
            if selected.hasPrefix(delimiter), selected.hasSuffix(delimiter) {
                let innerLength = selection.length - delimiterLength * 2
                let innerRange = NSRange(location: selection.location + delimiterLength, length: innerLength)
                let inner = MarkdownTextEditingSupport.substring(innerRange, in: text)
                return MarkdownTextEditingSupport.replacement(
                    range: selection,
                    string: inner,
                    selection: NSRange(location: selection.location, length: innerLength)
                )
            }
        }

        let beforeLocation = selection.location - delimiterLength
        let afterLocation = selection.location + selection.length
        let hasOuterDelimiters = beforeLocation >= 0 &&
            MarkdownTextEditingSupport.hasString(delimiter, at: beforeLocation, in: text) &&
            MarkdownTextEditingSupport.hasString(delimiter, at: afterLocation, in: text)
        if hasOuterDelimiters {
            let selected = MarkdownTextEditingSupport.substring(selection, in: text)
            return MarkdownTextEditingSupport.replacement(
                range: NSRange(location: beforeLocation, length: selection.length + delimiterLength * 2),
                string: selected,
                selection: NSRange(location: beforeLocation, length: selection.length)
            )
        }

        let selected = MarkdownTextEditingSupport.substring(selection, in: text)
        let replacement = delimiter + selected + delimiter
        return MarkdownTextEditingSupport.replacement(
            range: selection,
            string: replacement,
            selection: NSRange(location: selection.location + delimiterLength, length: selection.length)
        )
    }

    private static func toggleLink(in text: String, selection: NSRange) -> MarkdownEditResult? {
        guard selection.length > 0 else {
            return MarkdownTextEditingSupport.replacement(
                range: selection,
                string: "[]()",
                selection: NSRange(location: selection.location + 1, length: 0)
            )
        }

        let selected = MarkdownTextEditingSupport.substring(selection, in: text)
        if selected.hasPrefix("["), selected.hasSuffix(")"), let closeBracket = selected.range(of: "](") {
            let label = String(selected[selected.index(after: selected.startIndex) ..< closeBracket.lowerBound])
            return MarkdownTextEditingSupport.replacement(
                range: selection,
                string: label,
                selection: NSRange(location: selection.location, length: MarkdownTextEditingSupport.utf16Length(label))
            )
        }

        let replacement = "[\(selected)]()"
        return MarkdownTextEditingSupport.replacement(
            range: selection,
            string: replacement,
            selection: NSRange(
                location: selection.location + MarkdownTextEditingSupport.utf16Length("[\(selected)]("),
                length: 0
            )
        )
    }

    private static func toggleHeading(level: Int, in text: String, selection: NSRange) -> MarkdownEditResult? {
        guard (1 ... 6).contains(level) else { return nil }
        let line = MarkdownTextEditingSupport.line(containing: selection.location, in: text)
        let existing = headingPrefix(in: line.text)
        let desiredPrefix = String(repeating: "#", count: level) + " "
        let replacementPrefix = existing?.level == level ? "" : desiredPrefix
        let replaceRange = NSRange(
            location: line.range
                .location +
                (existing?.range.location ?? MarkdownTextEditingSupport.leadingWhitespaceLength(in: line.text)),
            length: existing?.range.length ?? 0
        )
        let delta = MarkdownTextEditingSupport.utf16Length(replacementPrefix) - replaceRange.length
        return MarkdownTextEditingSupport.replacement(
            range: replaceRange,
            string: replacementPrefix,
            selection: shifted(selection, by: delta, afterOrAt: replaceRange.location)
        )
    }

    private static func stripHeading(in text: String, selection: NSRange) -> MarkdownEditResult? {
        let line = MarkdownTextEditingSupport.line(containing: selection.location, in: text)
        guard let existing = headingPrefix(in: line.text) else { return nil }

        let range = NSRange(location: line.range.location + existing.range.location, length: existing.range.length)
        return MarkdownTextEditingSupport.replacement(
            range: range,
            string: "",
            selection: shifted(selection, by: -range.length, afterOrAt: range.location)
        )
    }

    private static func toggleQuote(in text: String, selection: NSRange) -> MarkdownEditResult? {
        let lines = MarkdownTextEditingSupport.lines(overlapping: selection, in: text)
        guard let firstLine = lines.first, let lastLine = lines.last else { return nil }

        let allQuoted = lines
            .allSatisfy { quotePrefixRange(in: $0.text) != nil || MarkdownTextEditingSupport.isBlank($0.text) }
        var transformed = ""
        for (index, line) in lines.enumerated() {
            if index > 0 {
                transformed += "\n"
            }
            if allQuoted {
                if let quoteRange = quotePrefixRange(in: line.text) {
                    let storage = line.text as NSString
                    transformed += storage.substring(to: quoteRange.location)
                    transformed += storage.substring(from: quoteRange.location + quoteRange.length)
                } else {
                    transformed += line.text
                }
            } else if MarkdownTextEditingSupport.isBlank(line.text) {
                transformed += line.text
            } else {
                transformed += "> \(line.text)"
            }
        }

        let replacementRange = NSRange(
            location: firstLine.range.location,
            length: lastLine.endLocation - firstLine.range.location
        )
        let original = MarkdownTextEditingSupport.substring(replacementRange, in: text)
        guard original != transformed else { return nil }

        let delta = MarkdownTextEditingSupport.utf16Length(transformed) - replacementRange.length
        let newSelection = selection.length == 0
            ? shifted(selection, by: delta, afterOrAt: replacementRange.location)
            : NSRange(location: replacementRange.location, length: MarkdownTextEditingSupport.utf16Length(transformed))
        return MarkdownTextEditingSupport.replacement(
            range: replacementRange,
            string: transformed,
            selection: newSelection
        )
    }

    private static func toggleCodeFence(in text: String, selection: NSRange) -> MarkdownEditResult? {
        if selection.length > 0 {
            let selected = MarkdownTextEditingSupport.substring(selection, in: text)
            if selection.length >= 8, selected.hasPrefix("```\n"), selected.hasSuffix("\n```") {
                let innerRange = NSRange(location: selection.location + 4, length: selection.length - 8)
                let inner = MarkdownTextEditingSupport.substring(innerRange, in: text)
                return MarkdownTextEditingSupport.replacement(
                    range: selection,
                    string: inner,
                    selection: NSRange(
                        location: selection.location,
                        length: MarkdownTextEditingSupport.utf16Length(inner)
                    )
                )
            }

            let replacement = "```\n\(selected)\n```"
            return MarkdownTextEditingSupport.replacement(
                range: selection,
                string: replacement,
                selection: NSRange(location: selection.location + 4, length: selection.length)
            )
        }

        let replacement = "```\n\n```"
        return MarkdownTextEditingSupport.replacement(
            range: selection,
            string: replacement,
            selection: NSRange(location: selection.location + 4, length: 0)
        )
    }

    private static func headingPrefix(in line: String) -> (level: Int, range: NSRange)? {
        let storage = line as NSString
        var index = 0
        var leadingSpaces = 0
        while index < storage.length, storage.character(at: index) == 32, leadingSpaces < 3 {
            index += 1
            leadingSpaces += 1
        }

        let hashStart = index
        while index < storage.length, storage.character(at: index) == 35 {
            index += 1
        }
        let level = index - hashStart
        guard (1 ... 6).contains(level),
              index < storage.length,
              storage.character(at: index) == 32
        else {
            return nil
        }

        return (level, NSRange(location: hashStart, length: level + 1))
    }

    private static func quotePrefixRange(in line: String) -> NSRange? {
        let storage = line as NSString
        var index = 0
        while index < storage.length, storage.character(at: index) == 32 || storage.character(at: index) == 9 {
            index += 1
        }
        guard index < storage.length, storage.character(at: index) == 62 else { return nil }
        let hasFollowingSpace = index + 1 < storage.length && storage.character(at: index + 1) == 32
        let length = hasFollowingSpace ? 2 : 1
        return NSRange(location: index, length: length)
    }

    private static func shifted(_ selection: NSRange, by delta: Int, afterOrAt location: Int) -> NSRange {
        guard selection.location >= location else { return selection }
        return NSRange(location: max(0, selection.location + delta), length: selection.length)
    }
}
