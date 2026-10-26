import AppKit

/// The editor's scroll view: tiles the line-number gutter left of the clip view.
///
/// The clip view gives up the gutter's width, so STTextView sizes and wraps its text to
/// the visible width as if there were no gutter, and scrolling never moves the gutter
/// sideways.
@MainActor
final class EditorScrollView: NSScrollView {
    var lineNumberGutter: EditorLineNumberGutterView? {
        didSet {
            guard oldValue !== lineNumberGutter else { return }
            oldValue?.removeFromSuperview()
            if let lineNumberGutter {
                addSubview(lineNumberGutter)
            }
            tile()
        }
    }

    override func tile() {
        guard let gutter = lineNumberGutter else {
            super.tile()
            return
        }

        // `super.tile()` gives the clip view the full width, which this then narrows.
        // STTextView autoresizes with the clip view, and each width it passes through
        // re-lays out its text container, so it only follows the net change.
        let clipView = contentView
        let previousClipSize = clipView.frame.size
        let autoresizesSubviews = clipView.autoresizesSubviews
        clipView.autoresizesSubviews = false
        super.tile()

        var clipFrame = clipView.frame
        let width = min(gutter.thickness, clipFrame.width)
        gutter.frame = NSRect(x: clipFrame.minX, y: clipFrame.minY, width: width, height: clipFrame.height)
        clipFrame.origin.x += width
        clipFrame.size.width -= width
        clipView.frame = clipFrame
        clipView.autoresizesSubviews = autoresizesSubviews
        if autoresizesSubviews, clipView.frame.size != previousClipSize {
            clipView.resizeSubviews(withOldSize: previousClipSize)
        }
    }
}
