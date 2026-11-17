import Foundation

/// Recognizes an entire inline link before the Link command removes its destination.
enum MarkdownLinkSelection {
    static func label(in selection: String) -> String? {
        guard selection.first == "[", selection.last == ")" else { return nil }
        // Inline links cannot contain a paragraph break.
        let lines = selection.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard !lines.contains(where: { $0.allSatisfy(\.isWhitespace) }) else { return nil }
        var source = selection[...]
        guard source.popFirst() == "[",
              let label = balancedContents(in: &source, opening: "[", closing: "]"),
              source.popFirst() == "("
        else { return nil }

        source = source.drop(while: { $0.isWhitespace })
        guard consumeDestination(in: &source) else { return nil }
        if source.first?.isWhitespace == true {
            source = source.drop(while: { $0.isWhitespace })
            guard consumeOptionalTitle(in: &source) else { return nil }
        }
        guard source == ")" else { return nil }
        return String(label)
    }

    private static func consumeDestination(in source: inout Substring) -> Bool {
        if source.first == "<" {
            source.removeFirst()
            guard let destination = balancedContents(in: &source, opening: "<", closing: ">", allowsNesting: false)
            else { return false }
            return !destination.contains(where: \.isNewline)
        }
        var depth = 0
        while let character = source.first, !character.isWhitespace {
            if character == ")", depth == 0 { break }
            source.removeFirst()
            switch character {
            case "\\":
                if source.first?.isASCIIPunctuation == true { source.removeFirst() }
            case "(": depth += 1
            case ")": depth -= 1
            default: break
            }
        }
        return depth == 0
    }

    private static func consumeOptionalTitle(in source: inout Substring) -> Bool {
        guard let quote = source.first, ["\"", "'", "("].contains(quote) else { return true }
        source.removeFirst()
        let close: Character = quote == "(" ? ")" : quote
        guard balancedContents(in: &source, opening: quote, closing: close, allowsNesting: false) != nil
        else { return false }
        source = source.drop(while: { $0.isWhitespace })
        return true
    }

    private static func balancedContents(
        in source: inout Substring, opening: Character, closing: Character, allowsNesting: Bool = true
    ) -> Substring? {
        let original = source
        var depth = 1
        var backticks: [Int: [Range<String.Index>]]?
        while let character = source.first {
            let index = source.startIndex
            source.removeFirst()
            if character == "\\", source.first?.isASCIIPunctuation == true {
                source.removeFirst()
            } else if opening == "[", character == "`" {
                if backticks == nil { backticks = backtickRuns(in: original) }
                source = source.drop(while: { $0 == "`" })
                let length = original.distance(from: index, to: source.startIndex)
                while let next = backticks?[length]?.popLast() {
                    if next.lowerBound >= source.startIndex {
                        source = original[next.upperBound...]
                        break
                    }
                }
            } else if character == closing {
                depth -= 1
                if depth == 0 { return original[..<index] }
            } else if character == opening {
                guard allowsNesting else { return nil }
                depth += 1
            }
        }
        return nil
    }

    /// Store equal-length delimiters in reverse order so an unmatched opener stays
    /// literal and repeated searches never rescan the rest of a large selection.
    private static func backtickRuns(in text: Substring) -> [Int: [Range<String.Index>]] {
        var runs: [Int: [Range<String.Index>]] = [:]
        var end = text.endIndex
        while end > text.startIndex {
            var start = text.index(before: end)
            if text[start] == "`" {
                while start > text.startIndex, text[text.index(before: start)] == "`" {
                    start = text.index(before: start)
                }
                runs[text.distance(from: start, to: end), default: []].append(start ..< end)
            }
            end = start
        }
        return runs
    }
}

private extension Character {
    var isASCIIPunctuation: Bool {
        guard let asciiValue else { return false }
        return (33 ... 47).contains(asciiValue) || (58 ... 64).contains(asciiValue)
            || (91 ... 96).contains(asciiValue) || (123 ... 126).contains(asciiValue)
    }
}
