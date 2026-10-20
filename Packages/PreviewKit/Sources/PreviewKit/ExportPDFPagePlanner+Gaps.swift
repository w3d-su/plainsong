import CoreGraphics

extension ExportPDFPagePlanner {
    struct PaintedTailContext {
        let lastInterval: Span
        let lastSpanMax: CGFloat
        let intervals: [Span]
        let end: CGFloat
        let baseline: CGFloat
        let contentWidth: CGFloat
        let aspect: CGFloat?
        let extents: [WidthExtent]
        let epsilon: CGFloat
    }

    static func appendPaintedTail(
        to pages: inout [Page],
        context: PaintedTailContext
    ) {
        guard let lastPage = pages.last,
              lastPage.rect.minY < context.lastSpanMax - context.epsilon
        else {
            appendTailPages(
                to: &pages, from: context.lastSpanMax, to: context.end, context: context
            )
            return
        }
        let width = pageWidth(
            top: lastPage.rect.minY, bottom: context.end, baseline: context.baseline,
            contentWidth: context.contentWidth, extents: context.extents,
            epsilon: context.epsilon
        )
        let capture = captureWidth(for: width, contentWidth: context.contentWidth)
        if context.end - lastPage.rect.minY <= softBudget(capture, aspect: context.aspect) {
            pages[pages.count - 1] = makePage(
                top: lastPage.rect.minY, bottom: context.end, context: context
            )
            return
        }
        let finalWidth = pageWidth(
            top: context.lastInterval.minY, bottom: context.end, baseline: context.baseline,
            contentWidth: context.contentWidth, extents: context.extents,
            epsilon: context.epsilon
        )
        let finalCapture = captureWidth(for: finalWidth, contentWidth: context.contentWidth)
        if context.end - context.lastInterval.minY <= hardBudget(finalCapture) {
            truncatePages(&pages, at: context.lastInterval.minY, context: context)
            pages.append(makePage(
                top: context.lastInterval.minY, bottom: context.end, context: context
            ))
            return
        }
        truncatePages(&pages, at: context.lastInterval.minY, context: context)
        pages.append(makePage(
            top: context.lastInterval.minY, bottom: context.lastSpanMax, context: context
        ))
        appendTailPages(
            to: &pages, from: context.lastSpanMax, to: context.end, context: context
        )
    }

    private static func truncatePages(
        _ pages: inout [Page],
        at end: CGFloat,
        context: PaintedTailContext
    ) {
        while let last = pages.last, last.rect.maxY > end + context.epsilon {
            pages.removeLast()
            if last.rect.minY < end - context.epsilon {
                let truncated = makePage(
                    top: last.rect.minY, bottom: end, context: context
                )
                if anyIntervalStrictlyIntersecting(
                    minY: truncated.rect.minY, maxY: truncated.rect.maxY,
                    in: context.intervals, epsilon: context.epsilon
                ) {
                    pages.append(truncated)
                }
                break
            }
        }
    }

    private static func appendTailPages(
        to pages: inout [Page],
        from start: CGFloat,
        to end: CGFloat,
        context: PaintedTailContext
    ) {
        let width = pageWidth(
            top: start, bottom: end, baseline: context.baseline,
            contentWidth: context.contentWidth, extents: context.extents,
            epsilon: context.epsilon
        )
        let capture = captureWidth(for: width, contentWidth: context.contentWidth)
        let hard = hardBudget(capture)
        var top = start
        while top < end - context.epsilon {
            let bottom = min(end, top + hard)
            pages.append(makePage(
                top: top, bottom: bottom, context: context
            ))
            top = bottom
        }
    }

    private static func makePage(
        top: CGFloat,
        bottom: CGFloat,
        context: PaintedTailContext
    ) -> Page {
        let width = pageWidth(
            top: top, bottom: bottom, baseline: context.baseline,
            contentWidth: context.contentWidth, extents: context.extents,
            epsilon: context.epsilon
        )
        let capture = captureWidth(for: width, contentWidth: context.contentWidth)
        return Page(
            rect: CGRect(x: 0, y: top, width: capture, height: bottom - top),
            scale: pageScale(width: capture)
        )
    }
}
