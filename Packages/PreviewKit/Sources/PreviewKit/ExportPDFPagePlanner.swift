import CoreGraphics
import Foundation

/// Variable-height, per-page-width page plan for Export as PDF… and Print…
/// (`docs/export-gates.md` D4, A1 + the 2026-10-08 owner decision).
///
/// The caller measures **unsplittable spans** — every line box (Range.getClientRects over
/// non-whitespace text nodes) and every atomic box (images, SVG, media, controls, rules,
/// table rows, KaTeX, Mermaid) — in document coordinates. A **safe break** is any
/// vertical position not strictly inside an unsplittable span. Gaps between top-level
/// blocks, between li/tr/blockquote/MDX-card children, and between the line boxes of
/// paragraphs and pre blocks all fall out of that complement automatically; no container
/// classification is needed.
///
/// Each page gets **its own width**: the maximum right edge of any content intersecting
/// its vertical span, never narrower than the document's baseline content width (the
/// measured `#preview-root` border edge) and never wider than the full content width.
/// A page is scaled in PDF space only when its own width exceeds 14,400 pt, so one wide
/// table or long line shrinks only the pages that contain it.
///
/// Each page ends at the last safe break at or below its CSS-height budget from its
/// top. The **hard** budget is `maximumSide / pageScale(width)` (equal to
/// `max(14,400, width)`). `targetAspect` — `imageableHeight / imageableWidth` — adds a
/// **soft** budget of `width × aspect` for Print: when a planned break would land inside
/// an unbreakable run that already reaches the page top, the page extends to the run's
/// end instead of failing, and `.pageScaleToFit` shrinks that one page onto paper. A run
/// taller than the hard budget still fails as `oversizeAtomicBox`, for both products.
/// Spans that merely touch — adjacent table rows, stacked line boxes — keep their shared
/// edge as a valid break; only a genuine overlap (> 0.5 pt) merges spans into one
/// unbreakable run.
///
/// Termination and invariants: the inner fixed-point loop only ever increases `width`,
/// through the finite set {baseline} ∪ {ceil(maxX) over extents} ∪ {contentWidth}, so it
/// terminates after at most one growth step per width value; on exit
/// `width == pageWidth(top, bottom)`, so the emitted page height is ≤ soft(width), or —
/// after a soft extension — ≤ hard(width) or the plan throws. Every branch emits
/// `bottom > top` (soft(width) > 0; the safe-break branch requires `I.minY > top + ε`;
/// the extension branch yields `I.maxY > target > top`), so the outer loop terminates.
/// Pages are contiguous, cover [0, contentHeight], and are never empty; every page's
/// width lies within [baseline, contentWidth] and covers the right edge of every span it
/// contains, so no content is clipped.
public enum ExportPDFPagePlanner {
    public static let maximumSide: CGFloat = 14400

    /// One unsplittable vertical interval in full-size layout coordinates.
    public struct Span: Equatable, Sendable {
        public let minY: CGFloat
        public let maxY: CGFloat

        public init(minY: CGFloat, maxY: CGFloat) {
            self.minY = minY
            self.maxY = maxY
        }

        public var height: CGFloat {
            maxY - minY
        }
    }

    /// The rightmost edge (`maxX`, right padding included) of content occupying one
    /// vertical interval. The measurement layer emits one only for content wider than
    /// the baseline, so this list stays small.
    public struct WidthExtent: Equatable, Sendable {
        public let minY: CGFloat
        public let maxY: CGFloat
        public let maxX: CGFloat

        public init(minY: CGFloat, maxY: CGFloat, maxX: CGFloat) {
            self.minY = minY
            self.maxY = maxY
            self.maxX = maxX
        }
    }

    /// One output page: its full-size capture rect in document coordinates (always
    /// `x: 0`) and the PDF-space scale the joiner applies to it (≤ 1).
    public struct Page: Equatable, Sendable {
        public let rect: CGRect
        public let scale: CGFloat

        public init(rect: CGRect, scale: CGFloat) {
            self.rect = rect
            self.scale = scale
        }
    }

    /// The capture plan: contiguous full-size page rects, each with its own width and
    /// PDF-space scale.
    public struct Plan: Equatable, Sendable {
        public let pages: [Page]

        public init(pages: [Page]) {
            self.pages = pages
        }
    }

    /// 1 while a page's own width fits the 14,400 pt default user space; otherwise the
    /// factor that brings that page's width down to the maximum.
    public static func pageScale(width: CGFloat) -> CGFloat {
        guard width > maximumSide, width.isFinite else { return 1 }
        return maximumSide / width
    }

    /// Splits [0, `contentSize.height`] into pages at safe breaks, giving each page the
    /// width its own content requires.
    ///
    /// `baselineWidth` is the document's normal content width including padding (the
    /// `#preview-root` border edge measured after the geometry settle); it is clamped
    /// into [1, contentSize.width]. `widthExtents` carries the overflow right edges.
    /// `targetAspect` — the paper imageable `height / width` — bounds a page to
    /// `width × aspect` for Print as a *soft* budget; nil plans PDF pages bounded only
    /// by the hard 14,400 pt user-space cap. A non-finite aspect or one ≤ 0.01 (below
    /// any real paper) is treated as nil.
    public static func plan(
        contentSize: CGSize,
        baselineWidth: CGFloat,
        unsplittable: [Span],
        widthExtents: [WidthExtent],
        targetAspect: CGFloat? = nil
    ) throws(ExportPDFCaptureError) -> Plan {
        let epsilon: CGFloat = 0.5
        let contentWidth = contentSize.width
        let contentHeight = contentSize.height
        guard contentWidth > 0, contentHeight > 0,
              contentWidth.isFinite, contentHeight.isFinite
        else {
            throw .emptyDocument
        }
        let baseline = min(contentWidth, max(baselineWidth.isFinite ? baselineWidth : 1, 1))
        let aspect = targetAspect.flatMap { $0.isFinite && $0 > 0.01 ? $0 : nil }

        // Union of the unsplittable intervals. Merge only on a real overlap so spans that
        // merely touch keep their shared edge as a valid break.
        let sorted = unsplittable
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

        let extents = widthExtents
            .filter { $0.maxY > $0.minY && $0.maxX > baseline }
            .sorted { $0.minY < $1.minY }

        func hard(_ width: CGFloat) -> CGFloat {
            maximumSide / pageScale(width: width)
        }
        func soft(_ width: CGFloat) -> CGFloat {
            guard let aspect else { return hard(width) }
            return min(hard(width), width * aspect)
        }

        var pages: [Page] = []
        var top: CGFloat = 0
        while top < contentHeight - epsilon {
            var width = baseline
            while true {
                let target = top + soft(width)
                let bottom: CGFloat
                var extended: Span?
                if target >= contentHeight - epsilon {
                    bottom = contentHeight
                } else if let interval = intervalStrictlyContaining(
                    target, in: intervals, epsilon: epsilon
                ) {
                    if interval.minY > top + epsilon {
                        bottom = interval.minY
                    } else {
                        // Soft extension: no safe break exists before this unbreakable
                        // run, so the page grows to its end and stays capped by `hard`.
                        bottom = min(interval.maxY, contentHeight)
                        extended = interval
                    }
                } else {
                    bottom = target
                }
                let measured = pageWidth(
                    top: top, bottom: bottom, baseline: baseline,
                    contentWidth: contentWidth, extents: extents, epsilon: epsilon
                )
                if measured > width {
                    width = measured
                    continue
                }
                if let extended, bottom - top > hard(width) + epsilon {
                    throw .oversizeAtomicBox(heightPoints: extended.height * pageScale(width: width))
                }
                pages.append(Page(
                    rect: CGRect(x: 0, y: top, width: width, height: bottom - top),
                    scale: pageScale(width: width)
                ))
                top = bottom
                break
            }
        }
        return Plan(pages: pages)
    }

    /// The width the page [top, bottom) needs: the baseline, raised to the widest right
    /// edge of any extent intersecting that span and clamped to the content width.
    /// `extents` is sorted by `minY`; the binary search bounds the scan to extents that
    /// can reach into the page.
    private static func pageWidth(
        top: CGFloat,
        bottom: CGFloat,
        baseline: CGFloat,
        contentWidth: CGFloat,
        extents: [WidthExtent],
        epsilon: CGFloat
    ) -> CGFloat {
        var low = 0
        var high = extents.count
        while low < high {
            let mid = (low + high) / 2
            if extents[mid].minY < bottom - epsilon {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var width = baseline
        for extent in extents[..<low] where extent.maxY > top + epsilon {
            width = max(width, ceil(extent.maxX))
        }
        return min(contentWidth, width)
    }

    /// The merged interval whose interior (`minY + ε`, `maxY − ε`) holds `y`, if any.
    /// Intervals are sorted and disjoint, so only the last one starting before `y` can
    /// contain it — O(log n) per page.
    private static func intervalStrictlyContaining(
        _ y: CGFloat,
        in intervals: [Span],
        epsilon: CGFloat
    ) -> Span? {
        var low = 0
        var high = intervals.count
        while low < high {
            let mid = (low + high) / 2
            if intervals[mid].minY < y {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low > 0 else { return nil }
        let candidate = intervals[low - 1]
        guard candidate.minY + epsilon < y, y < candidate.maxY - epsilon else { return nil }
        return candidate
    }
}
