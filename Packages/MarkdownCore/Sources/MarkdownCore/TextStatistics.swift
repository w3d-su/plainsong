import Foundation

/// User-facing text metrics for the current document contents.
public struct TextStatistics: Sendable, Equatable {
    public let characterCount: Int
    public let wordCount: Int
    public let lineCount: Int

    public init(text: String) {
        characterCount = text.count
        wordCount = Self.countWords(in: text)
        lineCount = Self.countLines(in: text)
    }

    private static func countWords(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex ..< text.endIndex, options: [.byWords]) { substring, _, _, _ in
            if substring != nil {
                count += 1
            }
        }
        return count
    }

    private static func countLines(in text: String) -> Int {
        var count = 1
        for character in text where character.isNewline {
            count += 1
        }
        return count
    }
}
