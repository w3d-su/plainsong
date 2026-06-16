import Foundation

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
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let rawValueStart = line.index(after: colonIndex)
        return unquotedScalar(String(line[rawValueStart...]).trimmingCharacters(in: .whitespaces))
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
        guard !line.isEmpty,
              line.first?.isWhitespace == false,
              !line.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
              let colonIndex = line.firstIndex(of: ":")
        else {
            return nil
        }

        let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return key
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
