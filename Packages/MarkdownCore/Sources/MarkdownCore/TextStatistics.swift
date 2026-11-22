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
        let source = nativeSource(text)
        let counts = Self(text: source, isCancelled: { Task.isCancelled })
        return Task.isCancelled ? nil : counts
    }

    /// The iOS editor publishes its text storage string, which Swift reads on the bridged
    /// (foreign) path. Counting a native copy of 1 MiB of Traditional Chinese took 102 ms
    /// instead of 155 ms (docs/perf/2026-11-18-ios-edit-statistics.md). An unpaired
    /// surrogate has no exact native copy, so that text is counted as it is.
    static func nativeSource(_ text: String) -> String {
        if text.utf8.withContiguousStorageIfAvailable({ _ in true }) == true {
            return text
        }
        return ExactSourceText.nativeCopy(of: text as NSString) ?? text
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
