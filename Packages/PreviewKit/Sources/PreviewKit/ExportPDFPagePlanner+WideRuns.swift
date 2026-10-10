import CoreGraphics
import Foundation

extension ExportPDFPagePlanner {
    /// The sorted mandatory break positions the page loop must respect: the tops and
    /// bottoms of the wide runs — the union of the vertical spans of extents crossing
    /// `wideThreshold`, merged on overlap or touch, snapped outward to
    /// merged-unsplittable-interval edges so every boundary is a safe break, then grown
    /// across the neighbouring whitespace gaps and merged again (see the `plan` doc
    /// comment).
    ///
    /// The gap absorption keeps a mandatory break from ever landing inside span-free
    /// whitespace: each snapped run's top climbs to the bottom of the last interval
    /// ending at or before it (or the document start) and its bottom descends to the
    /// top of the first interval starting at or after it (or the document end). A run
    /// near the document start therefore covers the leading margin instead of leaving
    /// it to a blank first page, and two runs separated by a gap both claim it and
    /// merge. Two runs separated only by a shared safe break — touching intervals with
    /// no gap between them — stay separate so each run's pages take their own width;
    /// the shared edge collapses to one boundary position so no hairline page can form.
    /// This assumes whitespace gaps between consecutive spans stay below a page's soft
    /// budget; prose whitespace taller than a page is out of scope (such a gap has no
    /// safe break for a page inside the run to end on).
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
            // Absorb the span-free gap on each side: the edges land on the nearest
            // interval edge (or the document edge), so they stay safe breaks and no
            // page is forced to hold only whitespace.
            minY = intervals.last { $0.maxY <= minY }?.maxY ?? 0
            maxY = intervals.first { $0.minY >= maxY }?.minY ?? contentHeight
            minY = max(0, minY)
            maxY = min(contentHeight, maxY)
            guard maxY > minY else { continue }
            if let last = snapped.last, minY < last.maxY - epsilon {
                // The absorbed runs genuinely overlap: the gap between them was claimed
                // from both sides, so they merge into one run.
                snapped[snapped.count - 1] = Span(minY: last.minY, maxY: max(last.maxY, maxY))
            } else if let last = snapped.last, minY <= last.maxY + epsilon {
                // Only a shared safe break (or a sub-ε crack) separates the runs: keep
                // them separate so each run's pages keep their own width, and pin the
                // shared edge to a single position so no hairline page can be emitted
                // between the two boundaries. A run entirely covered by the previous
                // one contributes no new boundary.
                if maxY > last.maxY {
                    snapped.append(Span(minY: last.maxY, maxY: maxY))
                }
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
    /// would push the capture raster past `captureAreaBudget` — a measured WebKit
    /// limit near 2³⁰ px per capture, independent of aspect ratio and DPR, halved
    /// here for safety — so a very wide page trades height for width.
    static func hardBudget(_ width: CGFloat) -> CGFloat {
        min(maximumSide, captureAreaBudget / max(width, 1))
    }

    /// `hardBudget`, tightened to `width × aspect` for Print so a page fits its paper.
    static func softBudget(_ width: CGFloat, aspect: CGFloat?) -> CGFloat {
        guard let aspect else { return hardBudget(width) }
        return min(hardBudget(width), width * aspect)
    }
}
