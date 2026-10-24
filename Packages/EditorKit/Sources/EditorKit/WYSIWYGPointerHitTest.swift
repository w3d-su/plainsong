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
enum WYSIWYGPointerHitTest {
    struct Result: Equatable {
        /// The caret offset on the line nearest the point, or nil when no line is laid out.
        let offset: Int?
        /// Whether the visited lines enclose the point vertically or end the document on the
        /// side the point lies; otherwise the viewport is stale.
        let coversPoint: Bool
        /// Layout fragments visited (diagnostics and tests).
        let visitedFragments: Int
    }

    /// `point` is in text container coordinates (STTextView's content view). The nearest
    /// line by vertical distance wins, the first one on a tie, as when every line was scanned.
    @MainActor
    static func characterIndex(at point: CGPoint, in textView: STTextView) -> Result {
        let contentManager = textView.textContentManager
        let documentRange = contentManager.documentRange
        guard let viewportRange = textView.textLayoutManager.textViewportLayoutController.viewportRange,
              viewportRange.location.compare(documentRange.endLocation) != .orderedDescending
        else {
            return Result(offset: nil, coversPoint: false, visitedFragments: 0)
        }

        var scan = NearestLineScan(point: point)
        textView.textLayoutManager.enumerateTextLayoutFragments(
            from: viewportRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            // Past the viewport TextKit would create the elements the cache trimmer released.
            if scan.visited > 0,
               fragment.rangeInElement.location.compare(viewportRange.endLocation) != .orderedAscending
            {
                scan.stoppedAtViewportEnd = true
                return false
            }
            return scan.visit(fragment)
        }

        let startsDocument = viewportRange.location.compare(documentRange.location) != .orderedDescending
        let coversAbove = startsDocument || scan.firstLineMinY.map { point.y >= $0 } == true
        let coversBelow = !scan.stoppedAtViewportEnd || point.y <= scan.lastLineMaxY
        return Result(
            offset: scan.nearest.map { offset(of: $0, at: point, in: contentManager) },
            coversPoint: coversAbove && coversBelow,
            visitedFragments: scan.visited
        )
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
    var stoppedAtViewportEnd = false

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
