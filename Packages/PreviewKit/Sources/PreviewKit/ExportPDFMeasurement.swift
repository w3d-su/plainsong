import AppKit
import CoreGraphics
import Foundation
@preconcurrency import WebKit

/// DOM measurement for the A1 capture (`docs/export-gates.md` D4): the export-only
/// overflow style, the full-size geometry settle, and the unsplittable-span walk.
extension PreviewController {
    /// Injected once on the dedicated export controller so tables, code, display math,
    /// and Mermaid draw their overflow instead of scrolling inside the viewport, and so
    /// `#preview-root`'s `min-height: 100vh` cannot pin the root to a previous (taller)
    /// frame height while the settle loop shrinks the document. The live preview is a
    /// different controller and never receives this style.
    func applyExportOverflowStyle() async throws {
        let script = """
        (() => {
          const id = "plainsong-export-layout";
          let style = document.getElementById(id);
          if (!style) {
            style = document.createElement("style");
            style.id = id;
            document.head.appendChild(style);
          }
          style.textContent = `
            #preview-root table,
            #preview-root pre,
            #preview-root pre code,
            #preview-root .plainsong-math-block,
            #preview-root .plainsong-math-block > .katex-display,
            #preview-root .mermaid-rendered,
            #preview-root .mermaid-rendered svg {
              overflow: visible !important;
              max-width: none !important;
            }
            #preview-root table,
            #preview-root pre,
            #preview-root pre code,
            #preview-root .plainsong-math-block > .katex-display {
              width: max-content !important;
            }
            #preview-root pre,
            #preview-root pre code {
              white-space: pre !important;
            }
            #preview-root .plainsong-math-block > .katex-display {
              min-width: 0 !important;
            }
            #preview-root {
              min-height: 0 !important;
            }
          `;
          return true;
        })()
        """
        _ = try await evaluateExportJavaScript(script, label: "export overflow style")
    }

    /// Resizes the offscreen WebView to the settled full scroll size — no zoom, no width
    /// ceiling. The width includes the document's left/right padding.
    func settleExportGeometry(timeoutNanoseconds: UInt64 = 10_000_000_000) async throws -> CGSize {
        guard webView.bounds.width > 0, webView.bounds.height > 0 else {
            throw ExportPDFCaptureError.geometryUnstable
        }
        let start = DispatchTime.now().uptimeNanoseconds
        var previous: CGSize?
        while DispatchTime.now().uptimeNanoseconds &- start < timeoutNanoseconds {
            try checkExportAlive()
            try Task.checkCancellation()
            let measured = try await measureExportContentSize()
            webView.frame = CGRect(origin: .zero, size: measured)
            webView.layoutSubtreeIfNeeded()
            let remeasured = try await measureExportContentSize()
            if let previous,
               sizesMatch(previous, remeasured),
               sizesMatch(webView.bounds.size, remeasured)
            {
                return remeasured
            }
            previous = remeasured
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ExportPDFCaptureError.geometryUnstable
    }

    /// Width comes from the document's scroll/client boxes as before, but the height is
    /// measured **from content**: the maximum bottom of any `#preview-root` descendant —
    /// in-flow, floated, or positioned; anything that can reach below its ancestors —
    /// plus the root's padding-bottom and border, in document coordinates, falling back
    /// to the root's own border box when the root is empty. `clientHeight` is
    /// frame's own height and would pin the measure to the previous iteration, which is
    /// how wide content once produced trailing blank pages (B2, 2026-10-09).
    private func measureExportContentSize() async throws -> CGSize {
        let script = """
        JSON.stringify((() => {
          const root = document.getElementById("preview-root");
          let height = 0;
          if (root) {
            const rootStyle = getComputedStyle(root);
            const padB = parseFloat(rootStyle.paddingBottom) || 0;
            const borderB = parseFloat(rootStyle.borderBottomWidth) || 0;
            let bottom = 0;
            for (const el of root.querySelectorAll("*")) {
              bottom = Math.max(bottom, el.getBoundingClientRect().bottom);
            }
            if (bottom > 0) {
              height = bottom + window.scrollY + padB + borderB;
            } else {
              height = root.getBoundingClientRect().bottom + window.scrollY;
            }
          }
          return {
            width: Math.max(document.documentElement.scrollWidth, document.body.scrollWidth,
              document.documentElement.clientWidth, document.body.clientWidth),
            height: Math.ceil(height)
          };
        })())
        """
        guard let json = try await evaluateExportJavaScript(script, label: "export content size") as? String,
              let data = json.data(using: .utf8),
              let measurement = try? JSONDecoder().decode(ExportContentMeasurement.self, from: data),
              measurement.width.isFinite, measurement.height.isFinite,
              measurement.width > 0, measurement.height > 0
        else { throw ExportPDFCaptureError.geometryUnstable }
        return CGSize(width: measurement.width, height: measurement.height)
    }

    /// The unsplittable spans the planner complements into safe breaks: every atomic box
    /// (one span per element, its bounding rect) plus every line box (`Range.getClientRects`
    /// over non-whitespace text nodes, atomic subtrees rejected). Emitted as a flat
    /// [minY, maxY, …] number array in document coordinates to keep the JSON small.
    ///
    /// `baselineWidth` is the root border-box's right edge — the normal content width
    /// including padding — measured after the geometry settle, when the overflow style
    /// may already have grown the root past the export viewport. `wide` is a flat
    /// [minY, maxY, maxX, …] triple list of every measured element or line box whose
    /// right edge overflows the root's content box; the planner uses it to give each
    /// page the width of the widest content on that page (`maxX` re-adds the right
    /// padding so a page covers the padded overflow edge). Measured rects are first
    /// intersected with the padding box of every ancestor whose computed overflow-x
    /// clips (hidden, clip, auto, scroll) — text an `overflow: hidden` pill hides or
    /// ellipsizes must not mark the document wide — while elements the export style
    /// forces to `overflow: visible` (wide code, tables, math, Mermaid) still measure
    /// at their painted edge.
    ///
    /// Elements with computed position fixed/sticky, a non-none transform, or a float are
    /// returned as offenders: a break cannot be proven safe across one (the A1 design
    /// stop in `docs/export-gates.md`), so the caller fails typed when a planned break
    /// would land strictly inside one.
    func measureUnsplittableSpans() async throws -> ExportSpanMeasurementResult {
        let script = PreviewController.measureUnsplittableSpansScript
        guard let json = try await evaluateExportJavaScript(script, label: "unsplittable spans") as? String,
              let data = json.data(using: .utf8)
        else { throw ExportPDFCaptureError.geometryUnstable }
        return try await decodeSpanMeasurement(data)
    }

    /// The unsplittable-span walker, kept as a constant so `measureUnsplittableSpans`
    /// stays under the function-length budget. Everything below — the atomic selector,
    /// the per-ancestor `clipRightFor` cache, and the positioned-offender walk — is
    /// documented on `measureUnsplittableSpans` itself.
    private static let measureUnsplittableSpansScript = """
    JSON.stringify((() => {
      const root = document.getElementById("preview-root");
      if (!root) return { spans: [], offenders: [], wide: [], baselineWidth: 0 };
      const rootRect = root.getBoundingClientRect();
      const padR = parseFloat(getComputedStyle(root).paddingRight) || 0;
      const baselineWidth = Math.ceil(rootRect.right + window.scrollX);
      const contentRight = rootRect.right + window.scrollX - padR;
      const atomicSelector = [
        "img", "svg", "video", "canvas", "iframe", "input", "hr", "tr",
        ".katex", ".katex-display", ".plainsong-math-block", ".mermaid-rendered"
      ].join(", ");
      const atomics = new Set(root.querySelectorAll(atomicSelector));
      const insideAtomic = (node) => {
        let el = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
        for (; el && el !== root; el = el.parentElement) {
          if (atomics.has(el)) return true;
        }
        return false;
      };
      const spans = [];
      const wide = [];
      // The painted right edge a piece of content is clipped to, in document
      // coordinates: the minimum padding-box right edge (border-left +
      // clientWidth, i.e. rect.left + clientLeft + clientWidth + scrollX) over
      // every ancestor up to the export root whose computed overflow-x is not
      // visible — hidden, clip, auto and scroll all clip horizontally while
      // overflow-y alone cannot reach the right edge. clipRightFor(el) is the
      // limit on content painted *inside* el; a rect belonging to el itself is
      // clipped only by el's strict ancestors. Each element's limit is computed
      // once and cached, so the ancestor walk stays linear.
      const clipCache = new Map();
      const clipRightFor = (el) => {
        if (clipCache.has(el)) return clipCache.get(el);
        let limit = el === root ? Infinity : clipRightFor(el.parentElement || root);
        if (getComputedStyle(el).overflowX !== "visible") {
          const box = el.getBoundingClientRect();
          limit = Math.min(limit, box.left + el.clientLeft + el.clientWidth + window.scrollX);
        }
        clipCache.set(el, limit);
        return limit;
      };
      const pushWide = (rect, clipRight) => {
        if (rect.height <= 0) return;
        const right = Math.min(rect.right + window.scrollX, clipRight);
        if (right > contentRight + 0.5) {
          wide.push(rect.top + window.scrollY, rect.bottom + window.scrollY, right + padR);
        }
      };
      const pushRect = (rect, clipRight) => {
        if (rect.height <= 0) return;
        spans.push(rect.top + window.scrollY, rect.bottom + window.scrollY);
        pushWide(rect, clipRight);
      };
      for (const el of atomics) {
        pushRect(el.getBoundingClientRect(), clipRightFor(el.parentElement || root));
      }
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
        acceptNode: (node) => {
          if (!node.textContent.trim()) return NodeFilter.FILTER_REJECT;
          if (insideAtomic(node)) return NodeFilter.FILTER_REJECT;
          return NodeFilter.FILTER_ACCEPT;
        }
      });
      const range = document.createRange();
      let node;
      while ((node = walker.nextNode())) {
        range.selectNodeContents(node);
        // A text node's rects are content of its parent element, so the parent's
        // own overflow-x clip applies to them too.
        const clipRight = clipRightFor(node.parentElement || root);
        for (const rect of range.getClientRects()) pushRect(rect, clipRight);
      }
      const offenders = [];
      for (const el of root.querySelectorAll("*")) {
        pushWide(el.getBoundingClientRect(), clipRightFor(el.parentElement || root));
        const style = getComputedStyle(el);
        const positioned = style.position === "fixed" || style.position === "sticky";
        const transformed = style.transform && style.transform !== "none";
        const floated = style.float === "left" || style.float === "right";
        if (!positioned && !transformed && !floated) continue;
        const rect = el.getBoundingClientRect();
        offenders.push({
          tag: el.tagName.toLowerCase(),
          className: typeof el.className === "string" ? el.className : "",
          minY: rect.top + window.scrollY,
          maxY: rect.bottom + window.scrollY
        });
      }
      return {
        spans: spans,
        offenders: offenders,
        wide: wide,
        baselineWidth: baselineWidth
      };
    })())
    """

    /// Decoding and flattening the span payload is pure `Data` work, so it runs off the
    /// main actor; WebKit evaluation stays on main. Cancellation is forwarded into the
    /// worker, mirroring `joinAndReparse`.
    private func decodeSpanMeasurement(
        _ data: Data
    ) async throws -> ExportSpanMeasurementResult {
        let task = Task.detached(priority: .userInitiated) { () throws -> ExportSpanMeasurementResult in
            try Task.checkCancellation()
            guard let measurement = try? JSONDecoder().decode(ExportSpanMeasurement.self, from: data) else {
                throw ExportPDFCaptureError.geometryUnstable
            }
            guard measurement.spans.count % 2 == 0, measurement.wide.count % 3 == 0 else {
                throw ExportPDFCaptureError.geometryUnstable
            }
            var spans: [ExportPDFPagePlanner.Span] = []
            spans.reserveCapacity(measurement.spans.count / 2)
            for index in stride(from: 0, to: measurement.spans.count, by: 2) {
                let minY = measurement.spans[index]
                let maxY = measurement.spans[index + 1]
                guard minY.isFinite, maxY.isFinite, maxY > minY else { continue }
                spans.append(ExportPDFPagePlanner.Span(minY: minY, maxY: maxY))
            }
            var wide: [ExportPDFPagePlanner.WidthExtent] = []
            wide.reserveCapacity(measurement.wide.count / 3)
            for index in stride(from: 0, to: measurement.wide.count, by: 3) {
                let minY = measurement.wide[index]
                let maxY = measurement.wide[index + 1]
                let maxX = measurement.wide[index + 2]
                guard minY.isFinite, maxY.isFinite, maxX.isFinite, maxY > minY, maxX > 0 else { continue }
                wide.append(ExportPDFPagePlanner.WidthExtent(minY: minY, maxY: maxY, maxX: maxX))
            }
            guard measurement.baselineWidth.isFinite else {
                throw ExportPDFCaptureError.geometryUnstable
            }
            return ExportSpanMeasurementResult(
                spans: spans,
                offenders: measurement.offenders,
                wide: wide,
                baselineWidth: measurement.baselineWidth
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func evaluateExportJavaScript(_ script: String, label: String) async throws -> Any? {
        try checkExportAlive()
        try Task.checkCancellation()
        do {
            return try await webView.evaluateJavaScript(script)
        } catch {
            try checkExportAlive()
            throw ExportPDFCaptureError.captureFailed("\(label): \(error.localizedDescription)")
        }
    }

    private func sizesMatch(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= 0.5 && abs(lhs.height - rhs.height) <= 0.5
    }
}

private struct ExportContentMeasurement: Codable {
    let width: Double
    let height: Double
}

private struct ExportSpanMeasurement: Codable {
    let spans: [CGFloat]
    let offenders: [ExportPositionedOffender]
    let wide: [CGFloat]
    let baselineWidth: CGFloat
}

/// The decoded span measurement: unsplittable spans, positioned offenders, overflow
/// width extents, and the post-settle baseline content width.
struct ExportSpanMeasurementResult: Sendable {
    let spans: [ExportPDFPagePlanner.Span]
    let offenders: [ExportPositionedOffender]
    let wide: [ExportPDFPagePlanner.WidthExtent]
    let baselineWidth: CGFloat
}

/// A fixed/sticky/transformed/floated element inside the export DOM, with its document
/// bounds so the caller can test whether any planned break would cross it.
struct ExportPositionedOffender: Codable, Equatable, Sendable {
    let tag: String
    let className: String
    let minY: CGFloat
    let maxY: CGFloat
}
