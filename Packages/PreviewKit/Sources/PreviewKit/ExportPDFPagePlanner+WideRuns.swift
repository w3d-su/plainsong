import CoreGraphics
import Foundation

extension ExportPDFPagePlanner {
    /// Builds the whitespace windows at snapped wide-run edges. Whitespace-separated
    /// runs remain distinct; facing edges share and deduplicate one window.
    static func gapWindows(
        extents: [WidthExtent],
        intervals: [Span],
        wideThreshold: CGFloat,
        end: CGFloat,
        epsilon: CGFloat
    ) -> [GapWindow] {
        let runs = wideRuns(extents, threshold: wideThreshold)
        let snappedRuns = snappedWideRuns(
            runs, intervals: intervals, end: end, epsilon: epsilon
        )
        return windows(for: snappedRuns, intervals: intervals, end: end)
    }

    private static func wideRuns(
        _ extents: [WidthExtent],
        threshold: CGFloat
    ) -> [Span] {
        var runs: [Span] = []
        for extent in extents where extent.maxX > threshold {
            if let last = runs.last, extent.minY <= last.maxY {
                runs[runs.count - 1] = Span(
                    minY: last.minY,
                    maxY: max(last.maxY, extent.maxY)
                )
            } else {
                runs.append(Span(minY: extent.minY, maxY: extent.maxY))
            }
        }
        return runs
    }

    private static func snappedWideRuns(
        _ runs: [Span],
        intervals: [Span],
        end: CGFloat,
        epsilon: CGFloat
    ) -> [Span] {
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
            maxY = min(end, maxY)
            guard maxY > minY else { continue }
            if let last = snapped.last, minY < last.maxY - epsilon {
                snapped[snapped.count - 1] = Span(minY: last.minY, maxY: max(last.maxY, maxY))
            } else if let last = snapped.last, minY == last.maxY {
                snapped.append(Span(minY: last.maxY, maxY: maxY))
            } else {
                snapped.append(Span(minY: minY, maxY: maxY))
            }
        }
        return snapped
    }

    private static func windows(
        for snapped: [Span],
        intervals: [Span],
        end: CGFloat
    ) -> [GapWindow] {
        var windows: [GapWindow] = []
        for index in snapped.indices {
            let run = snapped[index]
            let previousBottom = index > snapped.startIndex ? snapped[index - 1].maxY : 0
            let nextTop = index + 1 < snapped.endIndex ? snapped[index + 1].minY : end
            let topLo = max(
                previousBottom,
                intervals.last(where: { $0.maxY <= run.minY })?.maxY ?? 0
            )
            let bottomHi = min(
                nextTop,
                intervals.first(where: { $0.minY >= run.maxY })?.minY ?? end
            )
            let candidates = [
                GapWindow(lo: topLo, hi: run.minY),
                GapWindow(lo: run.maxY, hi: bottomHi),
            ]
            for window in candidates where window.hi >= window.lo {
                if !windows.contains(window) {
                    windows.append(window)
                }
            }
        }
        return windows.sorted { $0.lo < $1.lo }
    }

    /// The first window above the page start limits the page at its high edge. A page
    /// beginning inside a window or at its low edge belongs to its lower side.
    static func pageLimit(
        after top: CGFloat,
        windows: [GapWindow],
        end: CGFloat,
        epsilon: CGFloat
    ) -> CGFloat {
        windows.first(where: { $0.lo > top + epsilon })?.hi ?? end
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
