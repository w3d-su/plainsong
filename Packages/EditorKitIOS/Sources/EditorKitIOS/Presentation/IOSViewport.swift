import UIKit

enum IOSViewport {
    /// UTF-16 units reported as visible before TextKit has laid out a viewport.
    static let unlaidOutFallbackLength = 8 * 1024

    @MainActor
    static func visibleUTF16Range(in textView: IOSMarkdownTextView) -> NSRange {
        let length = textView.textStorage.length
        if let override = textView.viewportOverride {
            return IOSTextRanges.clamped(override, length: length)
        }
        guard length > 0,
              let layoutManager = textView.textLayoutManager,
              let viewport = layoutManager.textViewportLayoutController.viewportRange,
              let range = IOSTextRanges.nsRange(for: viewport, content: layoutManager.textContentManager)
        else {
            // No layout yet (first open, or an empty viewport). A whole-document range
            // here made the first highlight tokenize and repaint all of a 1 MB file.
            return fallbackRange(in: textView.textStorage.mutableString, limit: unlaidOutFallbackLength)
        }
        return IOSTextRanges.clamped(range, length: length)
    }

    /// The first `limit` UTF-16 units, shortened by one when that would split a surrogate pair.
    static func fallbackRange(in source: NSString, limit: Int) -> NSRange {
        var length = min(source.length, max(limit, 0))
        if length > 0, length < source.length, UTF16.isLeadSurrogate(source.character(at: length - 1)) {
            length -= 1
        }
        return NSRange(location: 0, length: length)
    }
}
