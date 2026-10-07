import AppKit
import CoreGraphics
import Foundation
@preconcurrency import WebKit

/// DOM measurement for the A1 capture (`docs/export-gates.md` D4): the export-only
/// overflow style, the full-size geometry settle, and the unsplittable-span walk.
extension PreviewController {
    /// Injected once on the dedicated export controller so tables, code, display math,
    /// and Mermaid draw their overflow instead of scrolling inside the viewport. The
    /// live preview is a different controller and never receives this style.
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

    private func measureExportContentSize() async throws -> CGSize {
        let script = """
        JSON.stringify({
          width: Math.max(document.documentElement.scrollWidth, document.body.scrollWidth,
            document.documentElement.clientWidth, document.body.clientWidth),
          height: Math.max(document.documentElement.scrollHeight, document.body.scrollHeight,
            document.documentElement.clientHeight, document.body.clientHeight)
        })
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
    /// Elements with computed position fixed/sticky, a non-none transform, or a float are
    /// returned as offenders: a break cannot be proven safe across one (the A1 design
    /// stop in `docs/export-gates.md`), so the caller fails typed when a planned break
    /// would land strictly inside one.
    func measureUnsplittableSpans() async throws -> (
        spans: [ExportPDFPagePlanner.Span],
        offenders: [ExportPositionedOffender]
    ) {
        let script = """
        JSON.stringify((() => {
          const root = document.getElementById("preview-root");
          if (!root) return { spans: [], offenders: [] };
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
          const pushRect = (rect) => {
            if (rect.height <= 0) return;
            spans.push(rect.top + window.scrollY, rect.bottom + window.scrollY);
          };
          for (const el of atomics) pushRect(el.getBoundingClientRect());
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
            for (const rect of range.getClientRects()) pushRect(rect);
          }
          const offenders = [];
          for (const el of root.querySelectorAll("*")) {
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
          return { spans: spans, offenders: offenders };
        })())
        """
        guard let json = try await evaluateExportJavaScript(script, label: "unsplittable spans") as? String,
              let data = json.data(using: .utf8),
              let measurement = try? JSONDecoder().decode(ExportSpanMeasurement.self, from: data)
        else { throw ExportPDFCaptureError.geometryUnstable }
        guard measurement.spans.count % 2 == 0 else {
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
        return (spans, measurement.offenders)
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
}

/// A fixed/sticky/transformed/floated element inside the export DOM, with its document
/// bounds so the caller can test whether any planned break would cross it.
struct ExportPositionedOffender: Codable, Equatable, Sendable {
    let tag: String
    let className: String
    let minY: CGFloat
    let maxY: CGFloat
}
