import MarkdownCore

typealias IOSSourceLineIndex = SourceLineIndex

enum IOSLineNumberDigits {
    static let minimum = 3

    static func required(forLineCount lineCount: Int) -> Int {
        max(minimum, String(max(lineCount, 1)).count)
    }

    /// Grows immediately, and shrinks only after the count falls well below the
    /// next narrower width, so typing around 999/1000 does not reflow every key.
    static func next(forLineCount lineCount: Int, current: Int?) -> Int {
        let required = required(forLineCount: lineCount)
        guard let current, required < current else { return required }
        return lineCount < shrinkThreshold(below: current) ? required : current
    }

    static func shrinkThreshold(below digits: Int) -> Int {
        var limit = 1
        for _ in 0 ..< max(digits - 1, 0) {
            limit *= 10
        }
        return limit * 9 / 10
    }
}
