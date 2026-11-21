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
        if range.location > 0 {
            text = "\n" + source[stringRange]
            base = range.location - 1
        } else {
            text = String(source[stringRange])
            base = range.location
        }
    }
}
