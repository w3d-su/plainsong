import CoreGraphics
import Foundation

extension ExportPDFPagePlanner {
    /// The sorted mandatory break positions the page loop must respect: the tops and
    /// bottoms of the wide runs — the union of the vertical spans of extents crossing
    /// `wideThreshold`, merged on overlap or touch, snapped outward to
    /// merged-unsplittable-interval edges so every boundary is a safe break, clamped
    /// to the document, and merged again (see the `plan` doc comment).
    static func mandatoryBreaks(
        extents: [WidthExtent],
        intervals: [Span],
        wideThreshold: CGFloat,
        contentHeight: CGFloat,
        epsilon: CGFloat
    ) -> [CGFloat] {
        var runs: [Span] = []
        for extent in extents where extent.maxX > wideThreshold {
            if let last = runs.last, extent.minY <= last.maxY + epsilon {
                runs[runs.count - 1] = Span(
                    minY: last.minY,
                    maxY: max(last.maxY, extent.maxY)
                )
            } else {
                runs.append(Span(minY: extent.minY, maxY: extent.maxY))
            }
        }
        var snapped: [Span] = []
        snapped.reserveCapacity(runs.count)
        for run in runs {
            var minY = run.minY
            var maxY = run.maxY
            if let interval = intervalStrictlyContaining(minY, in: intervals, epsilon: epsilon) {
                minY = interval.minY
            }
            if let interval = intervalStrictlyContaining(maxY, in: intervals, epsilon: epsilon) {
                maxY = interval.maxY
            }
            minY = max(0, minY)
            maxY = min(contentHeight, maxY)
            guard maxY > minY else { continue }
            if let last = snapped.last, minY <= last.maxY + epsilon {
                snapped[snapped.count - 1] = Span(minY: last.minY, maxY: max(last.maxY, maxY))
            } else {
                snapped.append(Span(minY: minY, maxY: maxY))
            }
        }
        var breaks: [CGFloat] = []
        breaks.reserveCapacity(snapped.count * 2)
        for run in snapped {
            breaks.append(run.minY)
            breaks.append(run.maxY)
        }
        return breaks.sorted()
    }

    /// The smallest mandatory break strictly past `top + ε`, or `contentHeight` when
    /// no boundary remains — the position the current page may never cross.
    static func pageLimit(
        after top: CGFloat,
        breaks: [CGFloat],
        contentHeight: CGFloat,
        epsilon: CGFloat
    ) -> CGFloat {
        var low = 0
        var high = breaks.count
        while low < high {
            let mid = (low + high) / 2
            if breaks[mid] <= top + epsilon {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low < breaks.count ? breaks[low] : contentHeight
    }

    /// The hard page-height cap: a flat 14,400 CSS pt until the page's own width
    /// would push the capture raster past `captureAreaBudget` — WebContent dies
    /// painting a bitmap near 2³⁰ px — so a very wide page trades height for width.
    static func hardBudget(_ width: CGFloat) -> CGFloat {
        min(maximumSide, captureAreaBudget / max(width, 1))
    }

    /// `hardBudget`, tightened to `width × aspect` for Print so a page fits its paper.
    static func softBudget(_ width: CGFloat, aspect: CGFloat?) -> CGFloat {
        guard let aspect else { return hardBudget(width) }
        return min(hardBudget(width), width * aspect)
    }
}
