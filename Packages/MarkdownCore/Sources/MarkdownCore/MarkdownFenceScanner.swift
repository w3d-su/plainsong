import Foundation

/// The opening line of a fenced code block that is still open.
public struct MarkdownFence: Equatable, Sendable {
    public enum Marker: Equatable, Sendable {
        case backtick
        case tilde
    }

    public let marker: Marker
    /// Number of marker characters on the opening line; at least three.
    public let length: Int
    /// UTF-16 offset of the first character of the opening fence line.
    public let openingLineStart: Int

    public init(marker: Marker, length: Int, openingLineStart: Int) {
        self.marker = marker
        self.length = length
        self.openingLineStart = openingLineStart
    }
}

/// The one definition of fenced-code state shared by highlighting, Enter handling and
/// completion, so the three can no longer disagree about where a code block ends.
///
/// Rules (CommonMark 0.31 §4.5, line based):
/// - Lines end at `\n`, `\r` or `\r\n`, matching `MarkdownTextEditingSupport`.
/// - A fence line is indentation, then a run of at least three `` ` `` or `~`.
///   `.commonMark` indentation allows up to three spaces and no tab; `.anyWhitespace`
///   allows any spaces and tabs so fences nested in list items still count.
/// - A backtick opening fence whose info string contains a backtick is not a fence.
/// - Only a run of the opening character, at least as long as the opening run and
///   followed by nothing but spaces and tabs, closes the block. A tilde line never
///   closes a backtick block, nor the reverse, and a line with an info string never
///   closes one.
/// - A leading `---` or `+++` frontmatter block closed by the same marker (each line
///   trimmed of spaces and tabs) is skipped, matching the highlighter's frontmatter
///   context.
///
/// Scans walk the string's contiguous UTF-8 storage with `memchr` and touch only the
/// first characters of each line; offsets in and out are UTF-16, converted through the
/// standard library's index breadcrumbs. Bridged strings, such as `NSTextStorage`
/// contents, are read as UTF-16 in place when Foundation exposes the buffer, otherwise
/// copied once.
public enum MarkdownFenceScanner {
    public enum Indentation: Sendable {
        /// Up to three spaces before the marker run, as CommonMark requires.
        case commonMark
        /// Any run of spaces and tabs, so fences inside list items count.
        case anyWhitespace
    }

    /// The fence left open by the lines that start before UTF-16 `location`, or `nil`
    /// when those lines end outside fenced code. The line containing `location` counts
    /// when it starts before it.
    public static func openFence(
        in source: String,
        before location: Int,
        indentation: Indentation = .commonMark
    ) -> MarkdownFence? {
        guard location > 0, !source.isEmpty else {
            return nil
        }

        return withScanUnits(of: source) { units in
            openFence(in: units, before: location, indentation: indentation)
        }
    }

    /// The UTF-16 range of the leading `---`/`+++` frontmatter block through its closing
    /// line's terminator, or `nil` when the first line opens no closed block.
    public static func frontmatterRange(in source: String) -> NSRange? {
        guard !source.isEmpty else {
            return nil
        }

        return withScanUnits(of: source) { units in
            frontmatterRange(in: units)
        }
    }

    /// Grows a line-aligned UTF-16 `range` so it neither starts nor ends inside the
    /// leading frontmatter block or a fenced code block, in one pass over the lines up to
    /// the closing fence.
    ///
    /// A range that intersects the frontmatter starts at 0 and covers the whole block.
    /// A range starting inside fenced code starts at that block's opening line; a range
    /// ending inside fenced code ends after the closing fence line's terminator, or at the
    /// end of the source when the block never closes.
    public static func contextRange(
        in source: String,
        expanding range: NSRange,
        indentation: Indentation = .commonMark
    ) -> NSRange {
        guard !source.isEmpty, range.location != NSNotFound else {
            return range
        }

        return withScanUnits(of: source) { units in
            contextRange(in: units, expanding: range, indentation: indentation)
        }
    }
}

extension MarkdownFenceScanner {
    static func openFence(
        in units: MarkdownFenceScanUnits,
        before location: Int,
        indentation: Indentation
    ) -> MarkdownFence? {
        var scan = MarkdownFenceLineScan(units: units, indentation: indentation)
        let limit = units.unitLimit(beforeUTF16Offset: location)
        while scan.position < limit, scan.position < units.count {
            scan.consumeLine()
        }
        return scan.openFence.map { units.publicFence($0) }
    }

    static func frontmatterRange(in units: MarkdownFenceScanUnits) -> NSRange? {
        let scan = MarkdownFenceLineScan(units: units, indentation: .commonMark)
        guard scan.frontmatterEnd > 0 else {
            return nil
        }
        return NSRange(location: 0, length: units.utf16Offset(ofUnit: scan.frontmatterEnd))
    }

    static func contextRange(
        in units: MarkdownFenceScanUnits,
        expanding range: NSRange,
        indentation: Indentation
    ) -> NSRange {
        var scan = MarkdownFenceLineScan(units: units, indentation: indentation)
        var start = range.location
        var end = NSMaxRange(range)

        if scan.frontmatterEnd > 0 {
            let frontmatterLength = units.utf16Offset(ofUnit: scan.frontmatterEnd)
            if range.length > 0, start < frontmatterLength {
                start = 0
                end = max(end, frontmatterLength)
            }
        }

        let startLimit = units.unitLimit(beforeUTF16Offset: start)
        while scan.position < startLimit, scan.position < units.count {
            scan.consumeLine()
        }
        if let openFence = scan.openFence {
            start = units.utf16Offset(ofUnit: openFence.lineStart)
        }

        let endLimit = units.unitLimit(beforeUTF16Offset: end)
        while scan.position < endLimit, scan.position < units.count {
            scan.consumeLine()
        }

        if scan.openFence != nil {
            while scan.position < units.count {
                if scan.consumeLine() {
                    break
                }
            }
            end = max(end, units.utf16Offset(ofUnit: scan.position))
        }

        return NSRange(location: start, length: max(0, end - start))
    }

    static func withScanUnits<Result>(
        of source: String,
        _ body: (MarkdownFenceScanUnits) -> Result
    ) -> Result {
        if let result = source.utf8.withContiguousStorageIfAvailable({ bytes in
            body(MarkdownFenceScanUnits(utf8: bytes, source: source))
        }) {
            return result
        }

        let string = source as NSString as CFString
        let length = CFStringGetLength(string)
        if let characters = CFStringGetCharactersPtr(string) {
            return body(MarkdownFenceScanUnits(utf16: characters, count: length))
        }

        var buffer = [UInt16](repeating: 0, count: length)
        return buffer.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            CFStringGetCharacters(string, CFRange(location: 0, length: length), base)
            return body(MarkdownFenceScanUnits(utf16: UnsafePointer(base), count: length))
        }
    }
}
