import Foundation

/// User-facing text metrics for the current document contents.
public struct TextStatistics: Sendable, Equatable {
    public let characterCount: Int
    public let wordCount: Int
    public let lineCount: Int

    public init(text: String) {
        self.init(text: text, isCancelled: { false })
    }

    static func countUnlessCancelled(_ text: String) -> Self? {
        guard !Task.isCancelled else { return nil }
        let counts = Self(text: text, isCancelled: { Task.isCancelled })
        return Task.isCancelled ? nil : counts
    }

    private init(text: String, isCancelled: @escaping () -> Bool) {
        var characters = 0
        var lines = 1
        for character in text {
            characters += 1
            if character.isNewline { lines += 1 }
            if characters.isMultiple(of: 4096), isCancelled() { break }
        }
        characterCount = characters
        lineCount = lines

        var words = 0
        if !isCancelled() {
            let options: String.EnumerationOptions = [.byWords, .substringNotRequired]
            text.enumerateSubstrings(in: text.startIndex ..< text.endIndex, options: options) { _, _, _, stop in
                words += 1
                if words.isMultiple(of: 256), isCancelled() { stop = true }
            }
        }
        wordCount = words
    }
}
