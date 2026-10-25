import Foundation

/// One-based source lines for scroll sync and the line-number gutter. Only `\n` starts a
/// line, matching the preview's `data-line` numbering.
///
/// Typing applies each edit in place instead of rescanning the document: rebuilding
/// from the bridged text storage on every selection change cost ~17 ms per keystroke
/// in a 1 MiB document. A rebuild reads UTF-16 in bulk rather than per character.
/// The per-unit loops walk raw pointers because `Range` iteration is ~80x slower in
/// unoptimized builds, which the hosted typing gates run.
struct EditorScrollLineIndex: Equatable {
    /// Edits larger than this are cheaper to drop and rebuild in bulk than to scan
    /// through `String.UTF16View`.
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
        guard lineStarts.indices.contains(index) else {
            return textUTF16Count
        }

        return lineStarts[index]
    }

    /// Applies one native text replacement, `range` in pre-edit UTF-16 offsets.
    /// Returns `false`, leaving the index unchanged, when the edit cannot be applied
    /// incrementally; the caller then rebuilds from the text.
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

        // A start s > 0 follows the newline at s - 1, so the replaced newlines own
        // exactly the starts in (location, location + length].
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

    /// Index of the first line start greater than `offset`.
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
