import UIKit

enum IOSViewport {
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
            return NSRange(location: 0, length: length)
        }
        return IOSTextRanges.clamped(range, length: length)
    }
}
