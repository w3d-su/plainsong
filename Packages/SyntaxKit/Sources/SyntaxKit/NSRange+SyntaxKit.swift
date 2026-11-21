import Foundation

extension NSRange {
    func clamped(toLength length: Int) -> NSRange {
        guard location != NSNotFound else { return NSRange(location: 0, length: 0) }
        let clampedLocation = min(max(location, 0), length)
        // An unvalidated caller range can have `location + length` past `Int.max`.
        let (sum, overflow) = location.addingReportingOverflow(self.length)
        let end = overflow ? (self.length > 0 ? Int.max : Int.min) : sum
        let clampedEnd = min(max(end, clampedLocation), length)
        return NSRange(location: clampedLocation, length: clampedEnd - clampedLocation)
    }
}

/// The slice of a document that one visible-range parse reads.
struct MarkdownParseFragment {
    let text: String
    /// Added to a fragment offset to get the document offset.
    let base: Int

    /// A slice that starts after the first character cannot hold frontmatter, but
    /// tree-sitter-markdown reads a leading `---` or `+++` line as its opening fence.
    /// A blank line in front keeps that line a thematic break.
    init?(source: String, range: NSRange) {
        guard let stringRange = Range(range, in: source) else {
            return nil
        }
        let slice = source[stringRange]
        // A bound inside a surrogate pair is rounded to the whole character, which would
        // shift every offset. Decoding the exact units keeps one unit per split half.
        let body = slice.utf16.count == range.length
            ? String(slice)
            : String(decoding: source.utf16[stringRange], as: UTF16.self)
        if range.location > 0 {
            text = "\n" + body
            base = range.location - 1
        } else {
            text = body
            base = range.location
        }
    }
}

extension NSString {
    /// The line containing `index`, with its terminator. Only LF, CR and CRLF end a
    /// Markdown line; `lineRange(for:)` also splits at U+2028, U+2029 and U+0085, which
    /// CommonMark keeps inside the line.
    func markdownLineRange(containing index: Int) -> NSRange {
        guard length > 0 else {
            return NSRange(location: 0, length: 0)
        }
        var start = min(max(index, 0), length)
        // The line feed of a CRLF pair belongs to the line its carriage return ends.
        if start > 0, start < length, character(at: start) == 10, character(at: start - 1) == 13 {
            start -= 1
        }
        while start > 0 {
            let previous = character(at: start - 1)
            if previous == 10 || previous == 13 {
                break
            }
            start -= 1
        }
        var end = start
        while end < length {
            let unit = character(at: end)
            end += 1
            if unit == 10 {
                break
            }
            if unit == 13 {
                if end < length, character(at: end) == 10 {
                    end += 1
                }
                break
            }
        }
        return NSRange(location: start, length: end - start)
    }
}
