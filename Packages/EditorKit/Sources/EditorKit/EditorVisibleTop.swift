import AppKit
import STTextView

/// The source position at the top edge of what the editor shows.
///
/// STTextView 2.4.1 widens the TextKit viewport by up to half a screen above the visible
/// area, so `viewportRange.location` is text the user cannot see. Scroll sync reported
/// that location as the top line, which kept the preview about half an editor screen
/// behind.
enum EditorVisibleTop {
    /// UTF-16 offset of the first layout fragment that reaches below the visible top.
    ///
    /// STTextView's content view keeps the text view's vertical origin and height, so
    /// layout fragment frames and the text view's visible rect share one y axis (STTextView
    /// passes the content view's visible rect to TextKit as viewport bounds unchanged).
    /// Only fragments inside the laid-out viewport are visited.
    @MainActor
    static func utf16Offset(in textView: STTextView) -> Int? {
        let layoutManager = textView.textLayoutManager
        let contentManager = textView.textContentManager
        let documentStart = contentManager.documentRange.location
        guard let viewportRange = layoutManager.textViewportLayoutController.viewportRange else {
            return nil
        }

        let visibleTop = max(0, textView.visibleRect.minY)
        var topLocation: NSTextLocation?
        layoutManager.enumerateTextLayoutFragments(from: viewportRange.location) { fragment in
            guard fragment.rangeInElement.location.compare(viewportRange.endLocation) == .orderedAscending else {
                return false
            }
            if fragment.layoutFragmentFrame.maxY > visibleTop {
                topLocation = fragment.rangeInElement.location
                return false
            }
            return true
        }

        let offset = contentManager.offset(from: documentStart, to: topLocation ?? viewportRange.location)
        return offset == NSNotFound ? nil : offset
    }
}
