import AppKit
import STTextView

/// Maps a pointer location to a raw UTF-16 caret offset in Experimental WYSIWYG, where folded
/// Markdown delimiters lay out with zero width.
///
/// Only the laid-out TextKit viewport is visited. STTextView keeps it at the visible area
/// plus a prefetch band of up to half a screen on either side, so it holds every point a
/// click can reach. The hit-test used to lay out the whole document on each click: 0.1-1.5 s
/// per click on `Fixtures/large-1mb.md`, bringing back every paragraph element that
/// `EditorTextElementCacheTrimmer` had released.
///
/// When the viewport's lines do not enclose the point (a scroll or edit with no layout pass
/// yet), TextKit lays out the text down to a band a few lines tall around the point instead,
/// and the band's lines are visited. No view layout runs: STTextView's `layout()` also runs a
/// pending post-layout action, such as a scroll to the old selection.
enum WYSIWYGPointerHitTest {
    struct Result: Equatable {
        /// The caret offset on the line nearest the point, or nil when neither the viewport's
        /// lines nor the band's enclose the point.
        let offset: Int?
        /// Whether the viewport did not enclose the point, so the band was laid out.
        let laidOutBand: Bool
        /// Layout fragments visited (diagnostics and tests).
        let visitedFragments: Int
    }

    /// Default line heights the band reaches above and below the point. Lines touch
    /// vertically, so a point inside the text has lines on both sides within one line.
    static let bandReachInLines: CGFloat = 3

    /// `point` is in text container coordinates (STTextView's content view). The nearest
    /// line by vertical distance wins, the first one on a tie, as when every line was scanned.
    @MainActor
    static func characterIndex(at point: CGPoint, in textView: STTextView) -> Result {
        let viewport = viewportScan(at: point, in: textView)
        if let offset = viewport.offset {
            return Result(offset: offset, laidOutBand: false, visitedFragments: viewport.visited)
        }
        let band = bandScan(at: point, in: textView)
        return Result(offset: band.offset, laidOutBand: true, visitedFragments: viewport.visited + band.visited)
    }

    @MainActor
    private static func viewportScan(at point: CGPoint, in textView: STTextView) -> (offset: Int?, visited: Int) {
        let documentRange = textView.textContentManager.documentRange
        guard let viewportRange = textView.textLayoutManager.textViewportLayoutController.viewportRange,
              viewportRange.location.compare(documentRange.endLocation) != .orderedDescending
        else {
            return (nil, 0)
        }
        return scan(
            from: viewportRange.location,
            before: viewportRange.endLocation,
            maxY: .infinity,
            at: point,
            in: textView
        )
    }

    /// TextKit's lookups by position scan the fragment frames above the point (~10 ms each at
    /// 60,000 lines), but lay out and create only the paragraphs of the rect they are given.
    @MainActor
    private static func bandScan(at point: CGPoint, in textView: STTextView) -> (offset: Int?, visited: Int) {
        let layoutManager = textView.textLayoutManager
        let font = textView.font
        let reach = bandReachInLines * (font.ascender - font.descender + font.leading)
            * max(textView.defaultParagraphStyle.lineHeightMultiple, 1)
        let minY = max(0, point.y - reach)
        let band = CGRect(
            x: 0,
            y: minY,
            width: textView.textContainer.size.width,
            height: max(point.y + reach - minY, 1)
        )
        // The next layout pass lays out the viewport down from its top edge, placing that edge
        // by TextKit's height estimate of the text above. Laid out from the band's own top, the
        // band's lines could sit a line or more from where that pass draws them.
        let next = textView.viewportBounds(for: layoutManager.textViewportLayoutController)
        let layoutMinY = (next.minY ... next.maxY).contains(point.y) ? min(next.minY, band.minY) : band.minY
        layoutManager.ensureLayout(for: CGRect(
            x: 0,
            y: layoutMinY,
            width: band.width,
            height: band.maxY - layoutMinY
        ))
        guard let start = layoutManager.textLayoutFragment(for: band.origin)
            ?? lastFragment(above: band, in: layoutManager)
        else {
            return (nil, 0)
        }
        return scan(from: start.rangeInElement.location, before: nil, maxY: band.maxY, at: point, in: textView)
    }

    /// The document's last fragment when the band lies below it, as for a click under a
    /// short document's text.
    @MainActor
    private static func lastFragment(
        above band: CGRect,
        in layoutManager: NSTextLayoutManager
    ) -> NSTextLayoutFragment? {
        var last: NSTextLayoutFragment?
        layoutManager.enumerateTextLayoutFragments(from: nil, options: [.reverse]) { fragment in
            last = fragment
            return false
        }
        guard let last, last.state == .layoutAvailable, last.layoutFragmentFrame.maxY <= band.minY else {
            return nil
        }
        return last
    }

    /// Visits laid-out fragments from `location` until no later line can be nearer the point.
    /// A fragment at `end` or below `maxY` stops the walk before it is visited, and so does a
    /// fragment without layout: enumerating without `.ensuresLayout` lays nothing out, where
    /// TextKit would have laid out the first fragment past the bound before the check ran.
    /// The offset is nil unless the visited lines enclose the point or end the document on
    /// the side the point lies.
    @MainActor
    private static func scan(
        from location: NSTextLocation,
        before end: NSTextLocation?,
        maxY: CGFloat,
        at point: CGPoint,
        in textView: STTextView
    ) -> (offset: Int?, visited: Int) {
        let contentManager = textView.textContentManager
        var scan = NearestLineScan(point: point)
        var stopped = false
        textView.textLayoutManager.enumerateTextLayoutFragments(from: location) { fragment in
            let isPastEnd = end.map { fragment.rangeInElement.location.compare($0) != .orderedAscending } ?? false
            stopped = isPastEnd || fragment.layoutFragmentFrame.minY > maxY || fragment.state != .layoutAvailable
                || !scan.visit(fragment)
            return !stopped
        }

        let startsDocument = location.compare(contentManager.documentRange.location) != .orderedDescending
        let coversAbove = startsDocument || scan.firstLineMinY.map { point.y >= $0 } == true
        let coversBelow = !stopped || point.y <= scan.lastLineMaxY
        guard let nearest = scan.nearest, coversAbove, coversBelow else {
            return (nil, scan.visited)
        }
        return (offset(of: nearest, at: point, in: contentManager), scan.visited)
    }

    private static func offset(
        of nearest: NearestLineScan.Line,
        at point: CGPoint,
        in contentManager: NSTextContentManager
    ) -> Int {
        let elementLocation = contentManager.offset(
            from: contentManager.documentRange.location,
            to: nearest.layoutFragment.rangeInElement.location
        )
        // Like `characterRange`, the index counts from the paragraph's start, not the line's:
        // adding the line's start again put clicks on a wrapped paragraph's later visual
        // lines at that line's end.
        let index = nearest.lineFragment.characterIndex(for: CGPoint(
            x: point.x - nearest.frame.minX,
            y: point.y - nearest.frame.minY
        ))
        let lineRange = nearest.lineFragment.characterRange
        return elementLocation + min(max(index, lineRange.location), NSMaxRange(lineRange))
    }
}

/// The line nearest a point among visited layout fragments, in document order.
private struct NearestLineScan {
    struct Line {
        let distance: CGFloat
        let lineFragment: NSTextLineFragment
        /// Text container coordinates.
        let frame: CGRect
        let layoutFragment: NSTextLayoutFragment
    }

    let point: CGPoint
    private(set) var nearest: Line?
    private(set) var visited = 0
    private(set) var firstLineMinY: CGFloat?
    private(set) var lastLineMaxY = -CGFloat.infinity

    init(point: CGPoint) {
        self.point = point
    }

    /// Returns false once no later line can be nearer: lines below the point only get
    /// farther from it.
    mutating func visit(_ fragment: NSTextLayoutFragment) -> Bool {
        visited += 1
        let origin = fragment.layoutFragmentFrame.origin
        for lineFragment in fragment.textLineFragments {
            let frame = lineFragment.typographicBounds.offsetBy(dx: origin.x, dy: origin.y)
            firstLineMinY = firstLineMinY ?? frame.minY
            lastLineMaxY = max(lastLineMaxY, frame.maxY)
            let distance: CGFloat = if point.y < frame.minY {
                frame.minY - point.y
            } else if point.y > frame.maxY {
                point.y - frame.maxY
            } else {
                0
            }
            if let nearest, distance >= nearest.distance {
                if frame.minY > point.y {
                    return false
                }
                continue
            }
            nearest = Line(distance: distance, lineFragment: lineFragment, frame: frame, layoutFragment: fragment)
        }
        return true
    }
}
