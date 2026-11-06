import Foundation
import Yams

extension Frontmatter {
    static func rawValueSource(for key: String, in rawYAML: String, lineEnding: String) -> String? {
        let lines = linesWithoutTerminators(rawYAML)
        guard let startIndex = lines.firstIndex(where: { topLevelKey(in: $0) == key }) else {
            return nil
        }

        let endIndex = valueSpanEndIndex(startingAt: startIndex, in: lines)
        if endIndex == startIndex + 1 {
            return rawInlineValue(in: lines[startIndex])
        }

        return lines[(startIndex + 1) ..< endIndex].joined(separator: lineEnding)
    }

    static func valueSpanEndIndex(startingAt startIndex: Int, in lines: [String]) -> Int {
        var endIndex = startIndex + 1
        while endIndex < lines.count {
            let line = lines[endIndex]
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            // Treat a blank continuation as the end of the value span so comments and
            // spacing around keys are preserved. This means a rare blank line inside a
            // YAML block scalar ends the editable span; the raw source remains intact
            // unless that specific key is edited.
            guard line.first?.isWhitespace == true, !trimmedLine.isEmpty else {
                break
            }
            endIndex += 1
        }
        return endIndex
    }

    static func rawInlineValue(in line: String) -> String? {
        guard let span = topLevelKeySpan(in: line) else { return nil }
        return unquotedScalar(span.inlineValue)
    }

    static func unquotedScalar(_ value: String) -> String {
        guard value.count >= 2 else { return value }

        if value.hasPrefix("\""), value.hasSuffix("\"") {
            let inner = value.dropFirst().dropLast()
            return inner
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }

        if value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }

        return value
    }

    static func splitTags(_ rawValue: String) -> [String] {
        rawValue
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func topLevelKey(in line: String) -> String? {
        topLevelKeySpan(in: line)?.key
    }

    /// One top-level `key: value` line of a block mapping.
    struct TopLevelKeySpan {
        /// The key as YAML loads it: `"title"` and `'title'` are both `title`.
        let key: String
        /// The key as the source spells it, quotes included.
        let keyToken: String
        /// The text after the `:` indicator, trimmed of spaces and tabs.
        let inlineValue: String

        var hasQuotedInlineValue: Bool {
            inlineValue.hasPrefix("\"") || inlineValue.hasPrefix("'")
        }
    }

    /// Reads the key of a top-level mapping line. A plain key ends at the first `:` that is
    /// followed by a space, a tab or the end of the line (`url: https://…` and `a:b: c` keep
    /// their colons); a quoted key ends at its closing quote and is unescaped by YAML itself.
    static func topLevelKeySpan(in line: String) -> TopLevelKeySpan? {
        guard let first = line.first,
              !first.isWhitespace,
              first != "#"
        else {
            return nil
        }

        let colonIndex: String.Index
        let keyToken: String
        if first == "\"" || first == "'" {
            guard let closingQuote = closingQuoteIndex(in: line, quote: first) else { return nil }
            var index = line.index(after: closingQuote)
            while index < line.endIndex, line[index] == " " || line[index] == "\t" {
                index = line.index(after: index)
            }
            guard index < line.endIndex, line[index] == ":", isMappingIndicator(at: index, in: line) else {
                return nil
            }
            colonIndex = index
            keyToken = String(line[...closingQuote])
        } else {
            guard let index = line.indices.first(where: { line[$0] == ":" && isMappingIndicator(at: $0, in: line) })
            else {
                return nil
            }
            colonIndex = index
            keyToken = String(line[..<index]).trimmingCharacters(in: .whitespaces)
        }

        let key: String
        if first == "\"" || first == "'" {
            guard let unquoted = try? Yams.load(yaml: keyToken) as? String else { return nil }
            key = unquoted
        } else {
            key = keyToken
        }
        guard !key.isEmpty else { return nil }

        let inlineValue = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
        return TopLevelKeySpan(key: key, keyToken: keyToken, inlineValue: inlineValue)
    }

    /// A `:` separates a block mapping key from its value only when whitespace or the end
    /// of the line follows it.
    private static func isMappingIndicator(at index: String.Index, in line: String) -> Bool {
        let next = line.index(after: index)
        return next == line.endIndex || line[next] == " " || line[next] == "\t"
    }

    /// The closing quote of a quoted scalar starting at the line's first character: `\`
    /// escapes in double quotes, `''` stands for one quote in single quotes.
    private static func closingQuoteIndex(in line: String, quote: Character) -> String.Index? {
        var index = line.index(after: line.startIndex)
        while index < line.endIndex {
            let character = line[index]
            if quote == "\"", character == "\\" {
                index = line.index(after: index)
                if index < line.endIndex { index = line.index(after: index) }
                continue
            }
            if character == quote {
                let next = line.index(after: index)
                if quote == "'", next < line.endIndex, line[next] == "'" {
                    index = line.index(after: next)
                    continue
                }
                return index
            }
            index = line.index(after: index)
        }
        return nil
    }

    static func linesWithoutTerminators(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        let storage = text as NSString
        var lines: [String] = []
        var lineStart = 0
        var cursor = 0

        while cursor < storage.length {
            if isNewline(storage.character(at: cursor)) {
                lines.append(storage.substring(with: NSRange(location: lineStart, length: cursor - lineStart)))
                cursor += lineEndingLength(at: cursor, in: storage) ?? 1
                lineStart = cursor
            } else {
                cursor += 1
            }
        }

        lines.append(storage.substring(from: lineStart))
        return lines
    }

    static func endOfLine(startingAt startIndex: Int, in storage: NSString) -> Int {
        var index = startIndex
        while index < storage.length, !isNewline(storage.character(at: index)) {
            index += 1
        }
        return index
    }

    static func lineEnding(at index: Int, in storage: NSString) -> String? {
        guard index < storage.length else { return nil }

        let character = storage.character(at: index)
        if character == 13 {
            if index + 1 < storage.length, storage.character(at: index + 1) == 10 {
                return "\r\n"
            }
            return "\r"
        }

        if character == 10 {
            return "\n"
        }

        return nil
    }

    static func lineEndingLength(at index: Int, in storage: NSString) -> Int? {
        guard index < storage.length else { return nil }

        let character = storage.character(at: index)
        if character == 13 {
            return index + 1 < storage.length && storage.character(at: index + 1) == 10 ? 2 : 1
        }
        if character == 10 {
            return 1
        }
        return nil
    }

    static func isNewline(_ character: unichar) -> Bool {
        character == 10 || character == 13
    }

    static func preferredLineEnding(in text: String) -> String {
        if text.contains("\r\n") {
            return "\r\n"
        }
        if text.contains("\r") {
            return "\r"
        }
        return "\n"
    }

    static func hasLineTerminatorSuffix(_ text: String) -> Bool {
        let storage = text as NSString
        guard storage.length > 0 else { return false }
        let character = storage.character(at: storage.length - 1)
        return character == 10 || character == 13
    }
}
