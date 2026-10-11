import CoreGraphics
import Foundation

/// Variable-height, per-page-width page plan for Export as PDF… and Print…
/// (`docs/export-gates.md` D4, A1 + the 2026-10-08/09 owner decisions).
///
/// The caller measures **unsplittable spans** — every line box (Range.getClientRects over
/// non-whitespace text nodes) and every atomic box (images, SVG, media, controls, rules,
/// table rows, KaTeX, Mermaid) — in document coordinates. Padding, borders and
/// backgrounds are not spans; `paintedBottom` covers painted content after the last
/// span. A **safe break** is any
/// vertical position not strictly inside an unsplittable span. Gaps between top-level
/// blocks, between li/tr/blockquote/MDX-card children, and between the line boxes of
/// paragraphs and pre blocks all fall out of that complement automatically; no container
/// classification is needed.
///
/// Each page gets **its own width**: the maximum right edge of any content intersecting
/// its vertical span, never narrower than the document's baseline content width (the
/// measured `#preview-root` border edge). A page wider than `maximumSide` captures
/// `widePageSlack` extra points of overscan — WebKit can paint the tail of a very long
/// line past the measured right edge — capped at `contentWidth + widePageSlack`;
/// narrower pages capture exactly their content width, so a page that fits is never
/// shrunk by slack. A page is
/// scaled in PDF space only when its capture width exceeds 14,400 pt, so one wide
/// table or long line shrinks only the pages that contain it.
///
/// **Wide runs (E1, 2026-10-09; D4).** An extent whose right
/// edge crosses the product's wide threshold — `maximumSide` for PDF,
/// `baseline / printWideFraction` for Print — belongs to a *wide run*: the union of the
/// wide extents' vertical spans, merged on overlap or touch, snapped outward to
/// merged-unsplittable-interval edges (a boundary landing strictly inside an interval
/// moves to that interval's edge, which is always a safe break). Runs merge only when
/// the snapped ranges genuinely overlap; whitespace-separated runs stay separate and
/// retain their own pages and widths. Their edges form span-free **gap windows**:
/// Pages never cross a window's high edge, so prose and run content never share a page.
/// Inside a run the same rules apply: per-page width from that page's own
/// extents, greedy width growth, and the soft Print extension. Outside a run nothing
/// changes; by construction those pages hold no wide extents, so they are never scaled.
///
/// Each page respects the hard budget and all gap-window limits. A span-free candidate
/// grows through the next interval, while a leading gap too large for either adjacent
/// page is skipped rather than emitted by itself. The **hard** budget is
/// `maximumSide` — a flat 14,400 CSS pt whatever the page's width, because WebKit
/// splits an over-tall capture off any planned break and can terminate on very tall
/// full-size captures — lowered further when the page's own width would push its
/// capture raster past `captureAreaBudget` (below the observed near-2³⁰ px² WebContent
/// termination bound documented on the constant). `targetAspect` —
/// `imageableHeight / imageableWidth` — adds a **soft** budget of `width × aspect` for
/// Print. Gap ownership first assigns whitespace above when it fits the soft budget,
/// otherwise below when the next interval fits its own hard budget, then tries a
/// whitespace-only split, an earlier safe-break back-off, and finally the span-free skip
/// fallback. `.pageScaleToFit` shrinks over-soft pages onto paper.
/// An unbreakable interval taller than the hard budget for its own capture width,
/// including `widePageSlack`, still
/// fails truthfully, for both products: `oversizeAtomicBox` when it is taller than the
/// 14,400 pt user space, `oversizeCaptureArea` when it only overflows the capture-area
/// budget at its own capture width — wide runs merely over the area budget keep being
/// split instead. Spans that
/// merely touch — adjacent table rows, stacked line boxes — keep their shared edge as
/// a valid break; only a genuine overlap (> 0.5 pt) merges spans into one unbreakable
/// run.
///
/// Termination and invariants: run boundaries form a finite set, so `limit` is always
/// the smallest mandatory break past `top + ε` or `contentHeight`; the inner
/// fixed-point loop only ever increases `width` through the finite set {baseline} ∪
/// {ceil(maxX) over extents} ∪ {contentWidth}, so it terminates after at most one
/// growth step per width value; on exit `width == pageWidth(top, bottom)`, so the
/// emitted page height is ≤ soft(width) ≤ 14,400, or — after a soft extension — ≤
/// `hard(width)` or the plan throws. Every branch emits `bottom > top` (soft(width) > 0;
/// the limit branch requires `limit > top + ε`; the safe-break branch requires
/// `I.minY > top + ε`; the extension branch yields `I.maxY > target > top`), so the
/// outer loop terminates. Pages are ordered and non-overlapping; every uncovered strip
/// is span-free, and every page intersects a span except a painted end-tail page. Every
/// page's width lies within
/// [baseline, contentWidth + widePageSlack] and covers the right edge of every span it
/// contains, so no content is clipped. With `paintedBottom`, pages cover [0, E], where
/// E is the measured painted end clamped to the content height; the root's remaining
/// padding is excluded. Without it, trailing span-free pages retain the safety-net
/// behavior and `Plan.droppedTrailingBlankPages` reports them.
public enum ExportPDFPagePlanner {
    public static let maximumSide: CGFloat = 14400

    /// The largest raster area a `WKWebView.pdf` capture may ask WebKit to paint, in
    /// CSS px². Measured 2026-10-09 (probe, `docs/perf-log.md`): captures succeed at
    /// 1,064,098,819 px and terminate the WebContent process at 1,088,802,597 px —
    /// the true limit sits near 2³⁰ px (1,073,741,824), independent of aspect ratio
    /// and device pixel ratio. The budget stays at half of it (2²⁹) so the same
    /// guarantee holds on machines and OS versions whose limit is lower; it only
    /// lowers the height budget of pages wider than ~37,300 pt.
    public static let captureAreaBudget: CGFloat = 536_870_912

    /// The fraction of the baseline width a printed page's content may occupy before it
    /// is isolated as a wide run: past `baseline / printWideFraction` (≈ 1.11 ×
    /// baseline) the page would print more than 10% smaller than a normal page under
    /// `.pageScaleToFit`. PDF uses the absolute `maximumSide` threshold instead, since
    /// pages up to 14,400 pt stay at 100% (2026-10-09 owner decision).
    public static let printWideFraction: CGFloat = 0.9

    /// Extra capture width appended only to pages wider than `maximumSide`: WebKit
    /// can paint the tail of a very long line past the right edge the geometry
    /// measurement reports, so a capture rect cut at the measured edge clips the
    /// last glyphs.
    /// Calibrated 2026-10-10 (`docs/perf-log.md`): the minimum capture overscan that
    /// restores a line-end sentinel was ≈0 pt at ~101k pt content width, ~10 pt at
    /// ~130k, ~68 pt at ~812k, ~98 pt at ~1.95M and ~5–66 pt at ~3.35M — bounded and
    /// non-monotonic (a glyph-boundary effect, not proportional to width), so the
    /// slack is a constant twice the worst observed need (~100 pt). It applies only
    /// after run classification — it can never promote a page into a run — and only
    /// past `maximumSide`, where every page already has to shrink; adding it to a
    /// narrower page would lower its print scale for no benefit (E1 forbids that).
    /// A 1-glyph loss was measured at 130k pt with slack 0.
    public static let widePageSlack: CGFloat = 200

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

    struct GapWindow: Equatable, Sendable {
        let lo: CGFloat
        let hi: CGFloat
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

    /// The capture plan: ordered full-size page rects, each with its own width and
    /// PDF-space scale.
    public struct Plan: Equatable, Sendable {
        public let pages: [Page]

        /// Without a painted end, trailing pages dropped by the span-intersection
        /// safety net. With one, `ceil((contentHeight - E - bottomInset) / softBudget)`
        /// when the excess is greater than 1 pt, where E is the painted end.
        public let droppedTrailingBlankPages: Int

        public init(pages: [Page], droppedTrailingBlankPages: Int = 0) {
            self.pages = pages
            self.droppedTrailingBlankPages = droppedTrailingBlankPages
        }
    }

    /// 1 while a page's own width fits the 14,400 pt default user space; otherwise the
    /// factor that brings that page's width down to the maximum.
    public static func pageScale(width: CGFloat) -> CGFloat {
        guard width > maximumSide, width.isFinite else { return 1 }
        return maximumSide / width
    }

    /// Splits the painted document end into safe pages, giving each page the width its
    /// own content requires.
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
        targetAspect: CGFloat? = nil,
        paintedBottom: CGFloat? = nil,
        bottomInset: CGFloat = 0
    ) throws(ExportPDFCaptureError) -> Plan {
        try buildPlan(PagePlanRequest(
            contentSize: contentSize, baselineWidth: baselineWidth,
            unsplittable: unsplittable, widthExtents: widthExtents,
            targetAspect: targetAspect, paintedBottom: paintedBottom,
            bottomInset: bottomInset
        ))
    }

    /// The width the page [top, bottom) needs: the baseline, raised to the widest right
    /// edge of any extent intersecting that span and clamped to the content width.
    /// `extents` is sorted by `minY`; the binary search bounds the scan to extents that
    /// can reach into the page.
    static func pageWidth(
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
    static func intervalStrictlyContaining(
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
