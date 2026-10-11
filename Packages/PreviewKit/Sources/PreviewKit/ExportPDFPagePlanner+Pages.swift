import CoreGraphics

extension ExportPDFPagePlanner {
    struct PageContext {
        let top: CGFloat
        let limit: CGFloat
        let baseline: CGFloat
        let aspect: CGFloat?
        let intervals: [Span]
        let extents: [WidthExtent]
        let contentWidth: CGFloat
        let epsilon: CGFloat
    }

    private struct PageBounds {
        let top: CGFloat
        let bottom: CGFloat
    }

    /// Settles width before assigning whitespace, then recalculates the final capture
    /// width and scale after any split or back-off.
    static func pageFromTop(_ context: PageContext) throws(ExportPDFCaptureError) -> Page {
        var width = context.baseline
        while true {
            let captureWidth = Self.captureWidth(for: width, contentWidth: context.contentWidth)
            var bounds = try initialBounds(context, captureWidth: captureWidth)
            bounds = applyGapOwnership(
                bounds, context: context, capture: captureWidth
            )
            let measured = pageWidth(
                top: bounds.top, bottom: bounds.bottom, baseline: context.baseline,
                contentWidth: context.contentWidth, extents: context.extents,
                epsilon: context.epsilon
            )
            if measured > width {
                width = measured
                continue
            }
            let finalWidth = pageWidth(
                top: bounds.top, bottom: bounds.bottom, baseline: context.baseline,
                contentWidth: context.contentWidth, extents: context.extents,
                epsilon: context.epsilon
            )
            let finalCaptureWidth = Self.captureWidth(
                for: finalWidth, contentWidth: context.contentWidth
            )
            return Page(
                rect: CGRect(
                    x: 0, y: bounds.top, width: finalCaptureWidth,
                    height: bounds.bottom - bounds.top
                ),
                scale: pageScale(width: finalCaptureWidth)
            )
        }
    }

    private static func initialBounds(
        _ context: PageContext,
        captureWidth: CGFloat
    ) throws(ExportPDFCaptureError) -> PageBounds {
        let target = context.top + softBudget(captureWidth, aspect: context.aspect)
        guard target < context.limit - context.epsilon else {
            return PageBounds(top: context.top, bottom: context.limit)
        }
        if let interval = intervalStrictlyContaining(
            target, in: context.intervals, epsilon: context.epsilon
        ) {
            let hasEarlierContent = anyIntervalStrictlyIntersecting(
                minY: context.top, maxY: interval.minY,
                in: context.intervals, epsilon: context.epsilon
            )
            if interval.minY > context.top + context.epsilon, hasEarlierContent {
                return PageBounds(top: context.top, bottom: interval.minY)
            }
            return try extensionBounds(
                interval, from: context.top, limit: context.limit,
                context: context
            )
        }
        let bounds = PageBounds(top: context.top, bottom: target)
        guard !hasSpan(bounds, context: context) else { return bounds }
        return try growSpanFreeSlice(bounds, context: context)
    }

    private static func growSpanFreeSlice(
        _ bounds: PageBounds,
        context: PageContext
    ) throws(ExportPDFCaptureError) -> PageBounds {
        guard let interval = context.intervals.first(where: {
            $0.maxY > bounds.bottom + context.epsilon && $0.minY < context.limit - context.epsilon
        }) else {
            return bounds
        }
        return try extensionBounds(
            interval, from: bounds.top, limit: context.limit,
            context: context
        )
    }

    private static func extensionBounds(
        _ interval: Span,
        from top: CGFloat,
        limit: CGFloat,
        context: PageContext
    ) throws(ExportPDFCaptureError) -> PageBounds {
        let boxWidth = pageWidth(
            top: interval.minY, bottom: interval.maxY, baseline: context.baseline,
            contentWidth: context.contentWidth, extents: context.extents,
            epsilon: context.epsilon
        )
        let boxCaptureWidth = captureWidth(for: boxWidth, contentWidth: context.contentWidth)
        let boxHard = hardBudget(boxCaptureWidth)
        if interval.height > maximumSide {
            throw .oversizeAtomicBox(heightPoints: interval.height)
        }
        if interval.height > boxHard {
            throw .oversizeCaptureArea(
                widthPoints: boxCaptureWidth, heightPoints: interval.height
            )
        }
        let bottom = min(interval.maxY, limit)
        let start = bottom - top > boxHard
            ? max(top, bottom - boxHard)
            : top
        return PageBounds(top: start, bottom: bottom)
    }

    private static func applyGapOwnership(
        _ initial: PageBounds,
        context: PageContext,
        capture: CGFloat
    ) -> PageBounds {
        var bounds = initial
        guard bounds.bottom < context.limit - context.epsilon,
              let nextIndex = context.intervals.firstIndex(where: {
                  $0.minY > bounds.bottom + context.epsilon
                      && $0.minY <= context.limit + context.epsilon
              })
        else { return bounds }
        let next = context.intervals[nextIndex]
        let nextWidth = pageWidth(
            top: next.minY, bottom: next.maxY, baseline: context.baseline,
            contentWidth: context.contentWidth, extents: context.extents,
            epsilon: context.epsilon
        )
        let nextCaptureWidth = captureWidth(for: nextWidth, contentWidth: context.contentWidth)
        let nextHard = hardBudget(nextCaptureWidth)
        guard next.height <= nextHard else { return bounds }
        let hard = hardBudget(capture)
        let soft = softBudget(capture, aspect: context.aspect)
        let need = next.maxY - nextHard
        if next.minY - bounds.top <= soft {
            bounds = PageBounds(top: bounds.top, bottom: next.minY)
        } else if next.maxY - bounds.bottom <= nextHard {
            return bounds
        } else if need <= bounds.top + hard {
            bounds = PageBounds(top: bounds.top, bottom: need)
        } else if let start = backoffStart(
            before: bounds.bottom, top: bounds.top, intervals: context.intervals,
            epsilon: context.epsilon
        ), need <= start + hard {
            bounds = PageBounds(top: bounds.top, bottom: start)
        } else {
            bounds = PageBounds(top: bounds.top, bottom: min(next.minY, bounds.top + hard))
        }
        return bounds
    }

    private static func backoffStart(
        before bottom: CGFloat,
        top: CGFloat,
        intervals: [Span],
        epsilon: CGFloat
    ) -> CGFloat? {
        intervals.last(where: { interval in
            interval.minY > top + epsilon
                && interval.minY < bottom - epsilon
                && intervals.contains {
                    $0.minY < interval.minY - epsilon && $0.maxY > top + epsilon
                }
        })?.minY
    }

    private static func hasSpan(_ bounds: PageBounds, context: PageContext) -> Bool {
        anyIntervalStrictlyIntersecting(
            minY: bounds.top, maxY: bounds.bottom,
            in: context.intervals, epsilon: context.epsilon
        )
    }

    /// The capture width for a page whose content needs `width`, plus overscan only
    /// after the page exceeds the PDF user-space maximum.
    static func captureWidth(for width: CGFloat, contentWidth: CGFloat) -> CGFloat {
        guard width > maximumSide else { return width }
        return min(width + widePageSlack, contentWidth + widePageSlack)
    }

    /// Whether any merged interval strictly intersects `(minY, maxY)`.
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
