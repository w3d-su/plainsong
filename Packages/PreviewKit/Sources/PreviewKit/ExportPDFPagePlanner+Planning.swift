import CoreGraphics

extension ExportPDFPagePlanner {
    struct PagePlanRequest {
        let contentSize: CGSize
        let baselineWidth: CGFloat
        let unsplittable: [Span]
        let widthExtents: [WidthExtent]
        let targetAspect: CGFloat?
        let paintedBottom: CGFloat?
        let bottomInset: CGFloat
    }

    private struct PreparedPlan {
        let epsilon: CGFloat
        let contentWidth: CGFloat
        let contentHeight: CGFloat
        let baseline: CGFloat
        let aspect: CGFloat?
        let intervals: [Span]
        let lastSpanMax: CGFloat
        let paintedEnd: CGFloat?
        let end: CGFloat
        let extents: [WidthExtent]
        let windows: [GapWindow]
    }

    private struct PagePlanningContext {
        let pageEnd: CGFloat
        let end: CGFloat
        let baseline: CGFloat
        let aspect: CGFloat?
        let intervals: [Span]
        let extents: [WidthExtent]
        let contentWidth: CGFloat
        let epsilon: CGFloat
        let windows: [GapWindow]
    }

    private struct TrailingPageContext {
        let paintedEnd: CGFloat?
        let contentHeight: CGFloat
        let bottomInset: CGFloat
        let baseline: CGFloat
        let aspect: CGFloat?
        let intervals: [Span]
        let epsilon: CGFloat
    }

    static func buildPlan(_ request: PagePlanRequest) throws(ExportPDFCaptureError) -> Plan {
        let prepared = try preparePlan(request)
        return try finishPlan(prepared, bottomInset: request.bottomInset)
    }

    private static func preparePlan(
        _ request: PagePlanRequest
    ) throws(ExportPDFCaptureError) -> PreparedPlan {
        let epsilon: CGFloat = 0.5
        let contentWidth = request.contentSize.width
        let contentHeight = request.contentSize.height
        guard contentWidth > 0, contentHeight > 0,
              contentWidth.isFinite, contentHeight.isFinite
        else {
            throw .emptyDocument
        }
        let baseline = min(
            contentWidth, max(request.baselineWidth.isFinite ? request.baselineWidth : 1, 1)
        )
        let aspect = request.targetAspect.flatMap { $0.isFinite && $0 > 0.01 ? $0 : nil }
        let sorted = request.unsplittable
            .filter { $0.maxY > $0.minY }
            .sorted { $0.minY < $1.minY }
        var intervals: [Span] = []
        intervals.reserveCapacity(sorted.count)
        for span in sorted {
            if let last = intervals.last, span.minY < last.maxY - epsilon {
                intervals[intervals.count - 1] = Span(
                    minY: last.minY,
                    maxY: max(last.maxY, span.maxY)
                )
            } else {
                intervals.append(span)
            }
        }
        let lastSpanMax = intervals.last?.maxY ?? 0
        let paintedEnd = request.paintedBottom.map {
            min(contentHeight, max($0.isFinite ? $0 : 0, lastSpanMax))
        }
        let end = paintedEnd ?? contentHeight
        guard end > 0 else { throw .emptyDocument }
        let extents = request.widthExtents
            .filter { $0.maxY > $0.minY && $0.maxX > baseline }
            .sorted { $0.minY < $1.minY }
        let wideThreshold = aspect == nil ? maximumSide : baseline / printWideFraction
        let windows = gapWindows(
            extents: extents, intervals: intervals,
            wideThreshold: wideThreshold, end: end, epsilon: epsilon
        )
        return PreparedPlan(
            epsilon: epsilon, contentWidth: contentWidth,
            contentHeight: contentHeight, baseline: baseline, aspect: aspect,
            intervals: intervals, lastSpanMax: lastSpanMax,
            paintedEnd: paintedEnd, end: end, extents: extents, windows: windows
        )
    }

    private static func finishPlan(
        _ prepared: PreparedPlan,
        bottomInset: CGFloat
    ) throws(ExportPDFCaptureError) -> Plan {
        let pageEnd = prepared.paintedEnd == nil
            ? prepared.end
            : (prepared.intervals.last?.maxY ?? prepared.end)
        var pages = try makePages(PagePlanningContext(
            pageEnd: pageEnd, end: prepared.end, baseline: prepared.baseline,
            aspect: prepared.aspect, intervals: prepared.intervals,
            extents: prepared.extents, contentWidth: prepared.contentWidth,
            epsilon: prepared.epsilon, windows: prepared.windows
        ))
        if let paintedEnd = prepared.paintedEnd,
           let lastInterval = prepared.intervals.last,
           paintedEnd > prepared.lastSpanMax + prepared.epsilon
        {
            appendPaintedTail(
                to: &pages,
                context: PaintedTailContext(
                    lastInterval: lastInterval, lastSpanMax: prepared.lastSpanMax,
                    intervals: prepared.intervals, end: paintedEnd,
                    baseline: prepared.baseline, contentWidth: prepared.contentWidth,
                    aspect: prepared.aspect, extents: prepared.extents,
                    epsilon: prepared.epsilon
                )
            )
        }
        let dropped = dropTrailingBlankPages(
            from: &pages,
            context: TrailingPageContext(
                paintedEnd: prepared.paintedEnd, contentHeight: prepared.contentHeight,
                bottomInset: bottomInset, baseline: prepared.baseline,
                aspect: prepared.aspect, intervals: prepared.intervals,
                epsilon: prepared.epsilon
            )
        )
        return Plan(pages: pages, droppedTrailingBlankPages: dropped)
    }

    private static func makePages(
        _ context: PagePlanningContext
    ) throws(ExportPDFCaptureError) -> [Page] {
        var pages: [Page] = []
        var top: CGFloat = 0
        while top < context.pageEnd - context.epsilon {
            let limit = min(context.pageEnd, pageLimit(
                after: top, windows: context.windows,
                end: context.end, epsilon: context.epsilon
            ))
            if limit > top + context.epsilon,
               limit < context.pageEnd - context.epsilon,
               !context.intervals.isEmpty,
               !anyIntervalStrictlyIntersecting(
                   minY: top, maxY: limit,
                   in: context.intervals, epsilon: context.epsilon
               )
            {
                top = limit
                continue
            }
            let pageContext = PageContext(
                top: top, limit: limit, baseline: context.baseline,
                aspect: context.aspect, intervals: context.intervals,
                extents: context.extents, contentWidth: context.contentWidth,
                epsilon: context.epsilon
            )
            let page = try pageFromTop(pageContext)
            guard page.rect.maxY > top + context.epsilon else { throw .emptyDocument }
            let pageHasSpan = anyIntervalStrictlyIntersecting(
                minY: page.rect.minY, maxY: page.rect.maxY,
                in: context.intervals, epsilon: context.epsilon
            )
            let nextInterval = context.intervals.first {
                $0.minY >= page.rect.maxY - context.epsilon
            }
            if !pageHasSpan, let nextInterval {
                top = nextInterval.minY
                continue
            }
            pages.append(page)
            top = page.rect.maxY
        }
        return pages
    }

    private static func dropTrailingBlankPages(
        from pages: inout [Page],
        context: TrailingPageContext
    ) -> Int {
        if let paintedEnd = context.paintedEnd {
            let inset = max(0, context.bottomInset.isFinite ? context.bottomInset : 0)
            let excess = context.contentHeight - paintedEnd - inset
            return excess > 1
                ? Int(ceil(excess / softBudget(context.baseline, aspect: context.aspect)))
                : 0
        }
        // The height is measured from content; remove trailing slices that intersect no
        // span. Without painted-bottom evidence, a document with no spans is retained.
        var dropped = 0
        while pages.count > 1, !context.intervals.isEmpty, let last = pages.last,
              !context.intervals.contains(where: {
                  $0.minY < last.rect.maxY - context.epsilon
                      && $0.maxY > last.rect.minY + context.epsilon
              })
        {
            pages.removeLast()
            dropped += 1
        }
        return dropped
    }
}
