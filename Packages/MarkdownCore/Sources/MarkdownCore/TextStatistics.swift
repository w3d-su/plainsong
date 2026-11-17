import Foundation

/// User-facing text metrics for the current document contents.
public struct TextStatistics: Sendable, Equatable {
    public let characterCount: Int
    public let wordCount: Int
    public let lineCount: Int

    public init(text: String) {
        self.init(text: text, isCancelled: { false })
    }

    /// Call from the counting task so cancellation interrupts enumeration and discards partial counts.
    public static func countUnlessCancelled(_ text: String) -> Self? {
        guard !Task.isCancelled else { return nil }
        let counts = Self(text: text, isCancelled: { Task.isCancelled })
        return Task.isCancelled ? nil : counts
    }

    private init(text: String, isCancelled: @escaping () -> Bool) {
        characterCount = text.count
        var words = 0
        let options: String.EnumerationOptions = [.byWords, .substringNotRequired]
        text.enumerateSubstrings(in: text.startIndex ..< text.endIndex, options: options) { _, _, _, stop in
            words += 1
            if words.isMultiple(of: 256), isCancelled() { stop = true }
        }
        wordCount = words
        var lines = 1
        if !isCancelled() {
            for character in text where character.isNewline {
                lines += 1
                if lines.isMultiple(of: 256), isCancelled() { break }
            }
        }
        lineCount = lines
    }
}
