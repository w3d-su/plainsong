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
            case "<", ">": return false
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
        while let character = source.first {
            let index = source.startIndex
            source.removeFirst()
            if character == "\\", source.first?.isASCIIPunctuation == true {
                source.removeFirst()
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
}

private extension Character {
    var isASCIIPunctuation: Bool {
        guard let asciiValue else { return false }
        return (33 ... 47).contains(asciiValue) || (58 ... 64).contains(asciiValue)
            || (91 ... 96).contains(asciiValue) || (123 ... 126).contains(asciiValue)
    }
}
