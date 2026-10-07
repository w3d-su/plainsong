import CoreGraphics
import Foundation

/// Variable-height page plan for Export as PDF… (`docs/export-gates.md` D4, A1).
///
/// The caller measures **unsplittable spans** — every line box (Range.getClientRects over
/// non-whitespace text nodes) and every atomic box (images, SVG, media, controls, rules,
/// table rows, KaTeX, Mermaid) — in document coordinates. A **safe break** is any
/// vertical position not strictly inside an unsplittable span. Gaps between top-level
/// blocks, between li/tr/blockquote/MDX-card children, and between the line boxes of
/// paragraphs and pre blocks all fall out of that complement automatically; no container
/// classification is needed.
///
/// Each page ends at the last safe break at or below its CSS-height budget
/// (`maximumSide / scale`, optionally `width × targetAspect` for Print) from its top.
/// Spans that merely touch — adjacent table rows, stacked line boxes — keep their shared
/// edge as a valid break; only a genuine overlap (> 0.5 pt) merges spans into one
/// unbreakable interval. A break can therefore only fail when one unbreakable run is
/// taller than the budget, reported as `oversizeAtomicBox`.
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

    /// The capture plan: contiguous full-size rects in document coordinates plus the
    /// uniform PDF-space scale the joiner applies (≤ 1).
    public struct Plan: Equatable, Sendable {
        public let pageRects: [CGRect]
        public let scale: CGFloat

        public init(pageRects: [CGRect], scale: CGFloat) {
            self.pageRects = pageRects
            self.scale = scale
        }
    }

    /// 1 until the contained overflow width exceeds 14,400 pt, then the single factor that
    /// brings that width down to the maximum. Applied to the whole capture, not per element.
    public static func uniformScale(containedWidth: CGFloat) -> CGFloat {
        guard containedWidth > maximumSide, containedWidth.isFinite else { return 1 }
        return maximumSide / containedWidth
    }

    /// Splits [0, `contentSize.height`] into page rects at safe breaks.
    ///
    /// `scale` is the uniform PDF-space factor from `uniformScale` (pages are captured at
    /// full size and scaled when joined, so the CSS height budget is `maximumSide /
    /// scale`). `targetAspect` — `imageableHeight / imageableWidth` — further bounds a
    /// page to the paper's imageable aspect for Print; nil plans PDF pages bounded only
    /// by the 14,400 pt default user space.
    ///
    /// Invariants: pages are contiguous, cover [0, contentHeight], are never taller than
    /// the budget, are never empty, and all share `contentSize.width`.
    public static func plan(
        contentSize: CGSize,
        unsplittable: [Span],
        scale: CGFloat,
        targetAspect: CGFloat? = nil
    ) throws(ExportPDFCaptureError) -> Plan {
        let epsilon: CGFloat = 0.5
        let contentWidth = contentSize.width
        let contentHeight = contentSize.height
        guard contentWidth > 0, contentHeight > 0, scale > 0, scale.isFinite else {
            throw .emptyDocument
        }
        var budget = maximumSide / scale
        if let targetAspect {
            budget = min(budget, contentWidth * targetAspect)
        }

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

        var pageRects: [CGRect] = []
        var top: CGFloat = 0
        while top < contentHeight - epsilon {
            let target = top + budget
            var breakY = target
            if target >= contentHeight - epsilon {
                breakY = contentHeight
            } else if let interval = intervalStrictlyContaining(
                target, in: intervals, epsilon: epsilon
            ) {
                breakY = interval.minY
                guard breakY > top + epsilon else {
                    throw .oversizeAtomicBox(heightPoints: interval.height * scale)
                }
            }
            pageRects.append(CGRect(
                x: 0, y: top, width: contentWidth, height: breakY - top
            ))
            top = breakY
        }
        return Plan(pageRects: pageRects, scale: scale)
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
