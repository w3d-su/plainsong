import AppKit
import CoreGraphics
import Foundation
@preconcurrency import WebKit

public enum ExportPDFCaptureError: Error, Equatable, Sendable {
    case invalidated
    case geometryUnstable
    case widerThanMaximum
    case unsplittableBlock
    case noSafePageHeight
    case captureFailed(String)
    case emptyDocument
}

/// PDF bytes from one barrier-completed offscreen render.
public struct ExportPDFDocument: Equatable, Sendable {
    public let data: Data
    public let pageCount: Int
    /// The operation-fixed height. The last page may be shorter.
    public let pageHeight: CGFloat
    /// 1 unless the laid-out width exceeded 14,400 pt, in which case the whole capture
    /// was scaled uniformly before pagination.
    public let scale: CGFloat
    public let contentSize: CGSize
}

extension PreviewController {
    /// Export-only overflow expansion, then one uniform zoom when the width exceeds
    /// 14,400 pt. Pagination uses the post-scale block bounds. The live preview is a
    /// different controller and never receives this style.
    public func captureExportPDF() async throws -> ExportPDFDocument {
        guard !isInvalidated else { throw ExportPDFCaptureError.invalidated }
        // Read overflow scroll widths before expanding. Expanding a document wider than
        // about 14,000 pt tears this WebKit process down, so zoom is applied first and
        // only when that contained width already exceeds 14,400 pt.
        let containedWidth = try await measureContainedOverflowWidth()
        let scale = ExportPDFPagePlanner.uniformScale(containedWidth: containedWidth)
        if scale < 1 {
            try await setExportZoom(scale)
        }
        try await applyExportOverflowStyle()
        let geometry = try await settleExportGeometry()
        guard geometry.width <= ExportPDFPagePlanner.maximumSide + 0.5 else {
            throw ExportPDFCaptureError.widerThanMaximum
        }
        let blocks = try await exportPaginationBlocks()
        if blocks.contains(where: { $0.height > ExportPDFPagePlanner.maximumSide }) {
            throw ExportPDFCaptureError.unsplittableBlock
        }
        let content = CGRect(origin: .zero, size: geometry)
        guard let pageHeight = ExportPDFPagePlanner.fixedHeight(
            contentMinY: content.minY, contentMaxY: content.maxY, blocks: blocks
        ) else { throw ExportPDFCaptureError.noSafePageHeight }
        let pages = try await captureExportPages(contentBounds: content, pageHeight: pageHeight)
        let data = try ExportPDFPageJoiner.join(pages)
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages > 0
        else { throw ExportPDFCaptureError.emptyDocument }
        return ExportPDFDocument(
            data: data, pageCount: document.numberOfPages, pageHeight: pageHeight,
            scale: scale, contentSize: geometry
        )
    }

    /// Same overflow expansion as PDF, with no 14,400 pt zoom. Paper width is
    /// `NSPrintInfo.horizontalPagination = .fit`. The standard panel, including its
    /// scaling control, stays in place. The web view is not placed in a window.
    public func makeExportPrintOperation() async throws -> NSPrintOperation {
        guard !isInvalidated else { throw ExportPDFCaptureError.invalidated }
        guard webView.window == nil else { throw ExportPDFCaptureError.captureFailed("mounted-webview") }
        try await applyExportOverflowStyle()
        webView.layoutSubtreeIfNeeded()
        guard webView.window == nil else { throw ExportPDFCaptureError.captureFailed("mounted-webview") }
        guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else {
            throw ExportPDFCaptureError.captureFailed("print-info")
        }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = true
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        if !operation.printPanel.options.contains(.showsScaling) {
            operation.printPanel.options.insert(.showsScaling)
        }
        return operation
    }

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

    private func measureContainedOverflowWidth() async throws -> CGFloat {
        let script = """
        (() => {
          const nodes = document.querySelectorAll([
            "#preview-root table", "#preview-root pre",
            "#preview-root .plainsong-math-block", "#preview-root .mermaid-rendered"
          ].join(", "));
          let width = 0;
          for (const node of nodes) width = Math.max(width, node.scrollWidth);
          return width;
        })()
        """
        guard let width = try await evaluateExportJavaScript(script, label: "contained overflow width") as? Double,
              width.isFinite, width >= 0
        else { throw ExportPDFCaptureError.geometryUnstable }
        return width
    }

    private func setExportZoom(_ scale: CGFloat) async throws {
        let literal = String(format: "%.8f", scale)
        _ = try await evaluateExportJavaScript(
            "document.documentElement.style.zoom = '\(literal)'; true",
            label: "export zoom"
        )
    }

    private func settleExportGeometry(timeoutNanoseconds: UInt64 = 10_000_000_000) async throws -> CGSize {
        guard webView.bounds.width > 0, webView.bounds.height > 0 else {
            throw ExportPDFCaptureError.geometryUnstable
        }
        let start = DispatchTime.now().uptimeNanoseconds
        var previous: CGSize?
        while DispatchTime.now().uptimeNanoseconds &- start < timeoutNanoseconds {
            try Task.checkCancellation()
            let measured = try await measureExportContentSize()
            guard measured.width <= ExportPDFPagePlanner.maximumSide + 0.5 else {
                throw ExportPDFCaptureError.widerThanMaximum
            }
            webView.frame = CGRect(origin: .zero, size: measured)
            webView.layoutSubtreeIfNeeded()
            let remeasured = try await measureExportContentSize()
            if let previous, sizesMatch(previous, remeasured), sizesMatch(webView.bounds.size, remeasured) {
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

    private func exportPaginationBlocks() async throws -> [ExportPDFPagePlanner.Block] {
        let script = """
        JSON.stringify(Array.from(document.querySelectorAll(
          "#preview-root [data-line], #preview-root table, #preview-root pre, " +
          "#preview-root .katex-display, #preview-root .plainsong-math-block, #preview-root .mermaid-rendered"
        )).map(element => {
          const rect = element.getBoundingClientRect();
          return { minY: rect.top + window.scrollY, maxY: rect.bottom + window.scrollY };
        }))
        """
        guard let json = try await evaluateExportJavaScript(script, label: "export block bounds") as? String,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ExportBlockMeasurement].self, from: data)
        else { throw ExportPDFCaptureError.geometryUnstable }
        let blocks = decoded.map { ExportPDFPagePlanner.Block(minY: $0.minY, maxY: $0.maxY) }
        if blocks.isEmpty {
            let size = webView.bounds.size
            return [ExportPDFPagePlanner.Block(minY: 0, maxY: size.height)]
        }
        return blocks
    }

    private func captureExportPages(contentBounds: CGRect, pageHeight: CGFloat) async throws -> [Data] {
        guard pageHeight > 0, pageHeight <= ExportPDFPagePlanner.maximumSide else {
            throw ExportPDFCaptureError.noSafePageHeight
        }
        var pages: [Data] = []
        var offset = contentBounds.minY
        while offset < contentBounds.maxY - 0.5 {
            try Task.checkCancellation()
            let height = min(pageHeight, contentBounds.maxY - offset)
            let rect = CGRect(x: contentBounds.minX, y: offset, width: contentBounds.width, height: height)
            guard webView.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect) else {
                throw ExportPDFCaptureError.captureFailed("rect-outside-view")
            }
            let configuration = WKPDFConfiguration()
            configuration.rect = rect
            do {
                try await pages.append(webView.pdf(configuration: configuration))
            } catch {
                throw ExportPDFCaptureError.captureFailed(error.localizedDescription)
            }
            offset += height
        }
        guard !pages.isEmpty else { throw ExportPDFCaptureError.emptyDocument }
        return pages
    }

    private func evaluateExportJavaScript(_ script: String, label: String) async throws -> Any? {
        try Task.checkCancellation()
        do {
            return try await webView.evaluateJavaScript(script)
        } catch {
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

private struct ExportBlockMeasurement: Codable {
    let minY: CGFloat
    let maxY: CGFloat
}
