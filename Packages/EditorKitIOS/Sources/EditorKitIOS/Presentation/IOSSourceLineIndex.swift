import Foundation

/// One-based source lines for the gutter and preview scroll sync. Only `\n`
/// starts a line, matching the preview's `data-line` numbering and the macOS index.
///
/// Typing updates the index in place. A full scan is the fallback when an edit is
/// too large to walk, or when the stored length no longer matches the text view.
struct IOSSourceLineIndex: Equatable {
    static let incrementalReplacementLimit = 65536

    private(set) var lineStarts: [Int]
    private(set) var textUTF16Count: Int

    init(text: String) {
        self.init(utf16: text as NSString)
    }

    init(utf16 text: NSString) {
        let length = text.length
        let chunkLength = 16384
        var starts = [0]
        var buffer = [unichar](repeating: 0, count: min(chunkLength, max(length, 1)))
        buffer.withUnsafeMutableBufferPointer { buffer in
            var location = 0
            while location < length {
                let count = min(buffer.count, length - location)
                let start = buffer.baseAddress!
                text.getCharacters(start, range: NSRange(location: location, length: count))
                var unit = start
                let end = start + count
                while unit < end {
                    if unit.pointee == 10 {
                        starts.append(location + (unit - start) + 1)
                    }
                    unit += 1
                }
                location += count
            }
        }
        lineStarts = starts
        textUTF16Count = length
    }

    /// Source lines, counting the empty line after a final newline.
    var lineCount: Int {
        lineStarts.count
    }

    func oneBasedLine(containingUTF16Offset offset: Int) -> Int {
        let clampedOffset = min(max(offset, 0), textUTF16Count)
        return max(1, firstLineStart(after: clampedOffset))
    }

    func utf16Offset(forOneBasedLine line: Int) -> Int {
        guard line > 1 else { return 0 }
        let index = line - 1
        guard lineStarts.indices.contains(index) else { return textUTF16Count }
        return lineStarts[index]
    }

    /// Applies one replacement, `range` in pre-edit UTF-16 offsets.
    /// Returns false without changing the index when the edit is not incremental.
    mutating func replaceCharacters(in range: NSRange, with replacement: String) -> Bool {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0,
              range.location <= textUTF16Count - range.length,
              replacement.utf8.count <= Self.incrementalReplacementLimit
        else {
            return false
        }

        var insertedStarts: [Int] = []
        var replacementLength = 0
        for unit in replacement.utf16 {
            replacementLength += 1
            if unit == 10 {
                insertedStarts.append(range.location + replacementLength)
            }
        }

        let firstReplaced = firstLineStart(after: range.location)
        let firstKept = firstLineStart(after: NSMaxRange(range))
        lineStarts.replaceSubrange(firstReplaced ..< firstKept, with: insertedStarts)

        let delta = replacementLength - range.length
        if delta != 0 {
            let firstShifted = firstReplaced + insertedStarts.count
            lineStarts.withUnsafeMutableBufferPointer { starts in
                guard let base = starts.baseAddress else { return }
                var start = base + firstShifted
                let end = base + starts.count
                while start < end {
                    start.pointee += delta
                    start += 1
                }
            }
        }
        textUTF16Count += delta
        return true
    }

    private func firstLineStart(after offset: Int) -> Int {
        var lowerBound = 0
        var upperBound = lineStarts.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if lineStarts[midpoint] <= offset {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }
}

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
