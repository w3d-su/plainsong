import CoreFoundation
import Foundation

/// Word boundaries from ICU word segmentation (UAX #29 with its CJK, Thai, Lao, Khmer and
/// Myanmar dictionaries), for the whole-word edges that touch a script written without
/// spaces between words.
///
/// Segmentation uses the root locale, so a document segments the same way whatever the
/// user's language settings: 我喜歡中文 splits as 我|喜歡|中文, 使用Swift開發 as
/// 使用|Swift|開發.
///
/// Boundaries are read from one tokenized window at a time. The window reaches
/// `windowMargin * 2` units before the queried location and `windowSpan` after it, and only
/// boundaries at least `windowMargin` units inside it (or at a document end) are trusted,
/// so a word cut by the window edge never answers a query. Whole-word candidates are
/// examined in increasing order, so a scan re-tokenizes about once per `windowSpan` units
/// and the total work stays linear in the document, even for one unbroken run of Han text.
struct TextSearchWordSegmentation {
    static let windowMargin = 64
    static let windowSpan = 1024

    let storage: NSString
    let instrumentation: TextSearchInstrumentation?
    private var tokenizer: CFStringTokenizer?
    private var trustedStart = 0
    private var trustedEnd = -1
    private var boundaries: [Int] = []

    init(storage: NSString, instrumentation: TextSearchInstrumentation?) {
        self.storage = storage
        self.instrumentation = instrumentation
    }

    /// Whether a word boundary lies at `location`. The ends of the document always count.
    mutating func isBoundary(_ location: Int) -> Bool {
        guard location > 0, location < storage.length else { return true }
        if location < trustedStart || location > trustedEnd {
            loadWindow(around: location)
        }
        return Self.sortedContains(boundaries, location)
    }

    private mutating func loadWindow(around location: Int) {
        let length = storage.length
        // Snap both ends to composed boundaries so the tokenizer never sees half a
        // surrogate pair or a mark without its base.
        var start = max(0, location - 2 * Self.windowMargin)
        if start > 0 {
            start = storage.rangeOfComposedCharacterSequence(at: start).location
        }
        var end = min(length, location + Self.windowSpan)
        if end < length {
            end = storage.rangeOfComposedCharacterSequence(at: end).location
        }
        end = max(end, location)

        let window = CFRange(location: start, length: end - start)
        let string = storage as CFString
        if let tokenizer {
            CFStringTokenizerSetString(tokenizer, string, window)
        } else {
            tokenizer = CFStringTokenizerCreate(
                kCFAllocatorDefault,
                string,
                window,
                kCFStringTokenizerUnitWordBoundary,
                nil
            )
        }
        instrumentation?.recordWordSegmentationWindow(length: window.length)

        var loaded: [Int] = [start]
        if let tokenizer {
            while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
                let token = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                if loaded.last != token.location { loaded.append(token.location) }
                loaded.append(token.location + token.length)
            }
        }
        if loaded.last != end { loaded.append(end) }
        boundaries = loaded

        trustedStart = start == 0 ? 0 : start + Self.windowMargin
        trustedEnd = end == length ? length : end - Self.windowMargin
        // A window whose margins swallowed the query still answers it.
        trustedStart = min(trustedStart, location)
        trustedEnd = max(trustedEnd, location)
    }

    private static func sortedContains(_ values: [Int], _ target: Int) -> Bool {
        var lower = 0
        var upper = values.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if values[middle] < target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower < values.count && values[lower] == target
    }
}
