import CoreGraphics

extension ExportPDFPagePlanner {
    /// Emits the page starting at `top`, bounded by the mandatory break `limit`:
    /// resolves its width by fixed-point (the page's own bottom can pull in a wider
    /// extent, which changes its budgets), then ends it at the last safe break in
    /// budget — or extends it across a span-free slice or to an unbreakable
    /// interval's end, failing typed only when the interval itself is what
    /// overflows the hard budget.
    static func pageFromTop(
        top: CGFloat,
        limit: CGFloat,
        baseline: CGFloat,
        aspect: CGFloat?,
        intervals: [Span],
        extents: [WidthExtent],
        contentWidth: CGFloat,
        epsilon: CGFloat
    ) throws(ExportPDFCaptureError) -> Page {
        var width = baseline
        while true {
            // A page wider than `maximumSide` captures `widePageSlack` of overscan
            // past the measured right edge so glyphs painted beyond it are not
            // clipped; the soft and hard budgets and the scale all see that
            // wider capture rect.
            let captureWidth = Self.captureWidth(for: width, contentWidth: contentWidth)
            let target = top + softBudget(captureWidth, aspect: aspect)
            var bottom: CGFloat
            var extended: Span?
            if target >= limit - epsilon {
                // The run boundary (or the document end) is a safe break the page
                // may never cross; `limit > top + ε` keeps the page non-empty.
                bottom = limit
            } else if let interval = intervalStrictlyContaining(
                target, in: intervals, epsilon: epsilon
            ) {
                if interval.minY > top + epsilon,
                   anyIntervalStrictlyIntersecting(
                       minY: top, maxY: interval.minY,
                       in: intervals, epsilon: epsilon
                   )
                {
                    // The slice before this interval still holds content, so its
                    // edge is the last safe break inside the budget.
                    bottom = interval.minY
                } else {
                    // The interval already reaches the page top, or the slice
                    // before it is span-free whitespace — emitting it would be a
                    // blank page, so the page grows into the interval's end
                    // (never past the mandatory break) as a soft extension.
                    // The grown page must still fit the hard budget; when a
                    // degenerate leading gap would push it past, the whitespace
                    // page is the lesser evil — an over-budget capture cannot be
                    // emitted (the interval itself stays splittable, so refusing
                    // would be a false oversize).
                    let grown = min(interval.maxY, limit)
                    if interval.minY <= top + epsilon
                        || grown - top <= hardBudget(captureWidth) + epsilon
                    {
                        bottom = grown
                        extended = interval
                    } else {
                        bottom = interval.minY
                    }
                }
            } else {
                bottom = target
            }
            // A slice that holds no span up to the mandatory break would start
            // the next page inside whitespace — emit it and it would be blank —
            // so this page swallows it instead, bounded by the hard budget.
            if bottom < limit - epsilon,
               limit - top <= hardBudget(captureWidth) + epsilon,
               !anyIntervalStrictlyIntersecting(
                   minY: bottom, maxY: limit,
                   in: intervals, epsilon: epsilon
               )
            {
                bottom = limit
            }
            let measured = pageWidth(
                top: top, bottom: bottom, baseline: baseline,
                contentWidth: contentWidth, extents: extents, epsilon: epsilon
            )
            if measured > width {
                width = measured
                continue
            }
            if let extended, bottom - top > hardBudget(captureWidth) + epsilon {
                if extended.height > maximumSide + epsilon {
                    throw .oversizeAtomicBox(heightPoints: extended.height)
                }
                throw .oversizeCaptureArea(
                    widthPoints: width,
                    heightPoints: extended.height
                )
            }
            return Page(
                rect: CGRect(x: 0, y: top, width: captureWidth, height: bottom - top),
                scale: pageScale(width: captureWidth)
            )
        }
    }

    /// The capture width for a page whose content needs `width`: the same width,
    /// plus `widePageSlack` of overscan only once the page is wider than
    /// `maximumSide` — painted overflow past the measured right edge was only
    /// ever observed far past that point (≈0 at ~101k pt, `docs/perf-log.md`),
    /// and adding slack to a page that fits would shrink its print scale for no
    /// reason (the E1 owner decision forbids it). The result is capped at
    /// `contentWidth + widePageSlack`. Applied after run classification, so it
    /// can never promote a page into a run.
    static func captureWidth(for width: CGFloat, contentWidth: CGFloat) -> CGFloat {
        guard width > maximumSide else { return width }
        return min(width + widePageSlack, contentWidth + widePageSlack)
    }

    /// Whether any merged interval strictly intersects `(minY, maxY)` — more than
    /// `epsilon` on both sides. Intervals are sorted by `minY` and disjoint, so
    /// their `maxY`s are sorted too: the first interval still open at `minY` is
    /// the only candidate that can start before `maxY` — O(log n) per query.
    static func anyIntervalStrictlyIntersecting(
        minY: CGFloat,
        maxY: CGFloat,
        in intervals: [Span],
        epsilon: CGFloat
    ) -> Bool {
        var low = 0
        var high = intervals.count
        while low < high {
            let mid = (low + high) / 2
            if intervals[mid].maxY > minY + epsilon {
                high = mid
            } else {
                low = mid + 1
            }
        }
        guard low < intervals.count else { return false }
        return intervals[low].minY < maxY - epsilon
    }
}
