import Foundation

/// Case-matching policy for literal text search (Phase 3 workspace search, MarkdownCore core).
public enum TextSearchCaseSensitivity: String, Sendable, Equatable, CaseIterable {
    /// Case-sensitive when the pattern contains a cased uppercase character; otherwise insensitive.
    case smart
    /// Exact case match (Foundation still applies canonical equivalence, e.g. NFD ↔ NFC).
    case sensitive
    /// Case-insensitive match (Foundation Unicode case folding via `NSString`, e.g. `ß` ↔ `SS`).
    case insensitive
}

/// A pure, file-agnostic literal search query.
public struct TextSearchQuery: Sendable, Equatable {
    public let pattern: String
    public let caseSensitivity: TextSearchCaseSensitivity
    public let wholeWord: Bool

    public init(
        pattern: String,
        caseSensitivity: TextSearchCaseSensitivity = .smart,
        wholeWord: Bool = false
    ) {
        self.pattern = pattern
        self.caseSensitivity = caseSensitivity
        self.wholeWord = wholeWord
    }
}

/// One non-overlapping literal match inside a source string.
///
/// All ranges are UTF-16 `NSRange` values suitable for STTextView / TextKit selection.
public struct TextSearchMatch: Sendable, Equatable {
    /// Match range in the full source string (UTF-16 units).
    public let range: NSRange
    /// One-based line number of the match start (LF / CRLF aware).
    public let line: Int
    /// Bounded snippet around the match (may include leading/trailing `…`).
    ///
    /// Source grapheme boundaries are preserved on each side unless the match occupies only
    /// part of a grapheme and reaching that side's boundary exceeds the per-side context cap.
    /// That side then uses the exact match boundary as a bounded fallback.
    public let preview: String
    /// Highlight range of the match inside `preview` (UTF-16 units).
    public let previewMatchRange: NSRange

    public init(range: NSRange, line: Int, preview: String, previewMatchRange: NSRange) {
        self.range = range
        self.line = line
        self.preview = preview
        self.previewMatchRange = previewMatchRange
    }
}

/// Synchronous, pure literal text matcher for MarkdownCore.
///
/// Scans left to right in near-linear time over the source. Does not implement regex and
/// never launches an external process.
public enum TextSearchEngine {
    /// Maximum UTF-16 length accepted for one literal query.
    ///
    /// Workspace search is interactive; bounding the synchronous pattern keeps Unicode
    /// fallback comparisons and cancellation latency predictable.
    public static let maximumPatternUTF16Length = 256

    /// Extended grapheme clusters kept on each side of a match when they fit the UTF-16 cap.
    public static let defaultPreviewContextGraphemes = 40

    /// Maximum contextual UTF-16 units copied on either side of the exact match.
    ///
    /// Grapheme boundaries are preferred. If a match occupies only part of a source grapheme
    /// and reaching a boundary exceeds this per-side cap, that side falls back to the exact
    /// match boundary so output remains bounded.
    public static let maximumPreviewContextUTF16PerSide = 1024

    /// Ellipsis inserted when a preview is clipped on either side.
    public static let previewEllipsis = "…"

    /// Returns non-overlapping literal matches for `query` inside `text`, up to `limit`.
    ///
    /// - Empty, newline-containing, over-limit patterns and non-positive limits yield `[]`.
    /// - Matches are ordered left to right by UTF-16 location.
    /// - Line numbers are one-based and count LF and CRLF as a single line break.
    /// - Rejected whole-word hits advance to the next composed boundary whose predecessor
    ///   is not a word character; impossible starts inside one word are not enumerated.
    /// - Match length is whatever Foundation returns after case folding / canonical
    ///   equivalence; it is **not** assumed to equal the query’s UTF-16 length.
    /// - Preview context is bounded independently of match length. A match is never clipped.
    public static func matches(
        in text: String,
        query: TextSearchQuery,
        limit: Int,
        previewContextGraphemes: Int = defaultPreviewContextGraphemes
    ) -> [TextSearchMatch] {
        guard isValidRequest(text: text, query: query, limit: limit) else { return [] }
        var scanner = TextSearchScanner(
            text: text,
            query: query,
            limit: limit,
            previewContextGraphemes: previewContextGraphemes,
            instrumentation: nil
        )
        return scanner.matches()
    }

    static func matches(
        in text: String,
        query: TextSearchQuery,
        limit: Int,
        previewContextGraphemes: Int = defaultPreviewContextGraphemes,
        instrumentation: TextSearchInstrumentation
    ) -> [TextSearchMatch] {
        guard isValidRequest(text: text, query: query, limit: limit) else { return [] }
        var scanner = TextSearchScanner(
            text: text,
            query: query,
            limit: limit,
            previewContextGraphemes: previewContextGraphemes,
            instrumentation: instrumentation
        )
        return scanner.matches()
    }

    private static func isValidRequest(text: String, query: TextSearchQuery, limit: Int) -> Bool {
        limit > 0
            && !text.isEmpty
            && !query.pattern.isEmpty
            && query.pattern.utf16.count <= maximumPatternUTF16Length
            && !query.pattern.contains(where: \.isNewline)
    }
}
