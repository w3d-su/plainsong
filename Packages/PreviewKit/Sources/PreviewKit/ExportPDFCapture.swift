import AppKit
import CoreGraphics
import Foundation
@preconcurrency import WebKit

public enum ExportPDFCaptureError: Error, Equatable, Sendable {
    case invalidated
    case webContentProcessTerminated
    case geometryUnstable
    /// One unbreakable run (line/atomic box chain) exceeds the page budget; the value is
    /// its height in PDF points after the uniform scale.
    case oversizeAtomicBox(heightPoints: CGFloat)
    case captureFailed(String)
    case emptyDocument
}

/// PDF bytes from one barrier-completed offscreen render.
public struct ExportPDFDocument: Equatable, Sendable {
    public let data: Data
    public let pageCount: Int
    /// The tallest output page in PDF points (≤ 14,400 by construction).
    public let maximumPageHeight: CGFloat
    /// 1 unless the laid-out width exceeded 14,400 pt, in which case every page was
    /// scaled down by this factor in PDF space while joining.
    public let scale: CGFloat
    public let contentSize: CGSize
}

extension PreviewController {
    /// Export-only overflow expansion, then A1 variable-height pagination
    /// (`docs/export-gates.md` D4). Everything happens at full size: no zoom and no
    /// width ceiling; an over-maximum width is folded into the uniform PDF-space scale
    /// the joiner applies to every page. `pageAspect` — the paper imageable
    /// `height / width` — bounds page height for Print; nil plans plain PDF pages.
    public func captureExportPDF(pageAspect: CGFloat? = nil) async throws -> ExportPDFDocument {
        try checkExportAlive()
        try await applyExportOverflowStyle()
        let geometry = try await settleExportGeometry()
        try checkExportAlive()
        let scale = ExportPDFPagePlanner.uniformScale(containedWidth: geometry.width)
        let measured = try await measureUnsplittableSpans()
        try checkExportAlive()
        let plan = try ExportPDFPagePlanner.plan(
            contentSize: geometry,
            unsplittable: measured.spans,
            scale: scale,
            targetAspect: pageAspect
        )
        // A fixed/sticky/transformed/floated box cannot be proven safe across a break
        // (the A1 design stop): fail typed only when a planned break would cross one.
        for rect in plan.pageRects.dropLast() {
            if let offender = measured.offenders.first(where: {
                $0.minY + 0.5 < rect.maxY && rect.maxY < $0.maxY - 0.5
            }) {
                throw ExportPDFCaptureError.captureFailed(
                    "break-crosses-positioned-content: \(offender.tag).\(offender.className)"
                )
            }
        }
        let pieces = try await captureExportPages(plan.pageRects, inside: geometry)
        let joined = try await joinAndReparse(pieces, scale: scale)
        return ExportPDFDocument(
            data: joined.data,
            pageCount: joined.pageCount,
            maximumPageHeight: (plan.pageRects.map(\.height).max() ?? 0) * scale,
            scale: scale,
            contentSize: geometry
        )
    }

    /// Guarded between every WebKit await so a mid-capture teardown fails typed rather
    /// than hanging on a dead renderer.
    func checkExportAlive() throws {
        guard !isInvalidated else { throw ExportPDFCaptureError.invalidated }
        guard !webContentProcessTerminated else {
            throw ExportPDFCaptureError.webContentProcessTerminated
        }
    }

    private func captureExportPages(_ rects: [CGRect], inside contentSize: CGSize) async throws -> [Data] {
        let contentBounds = CGRect(origin: .zero, size: contentSize)
        var pages: [Data] = []
        pages.reserveCapacity(rects.count)
        for (index, rect) in rects.enumerated() {
            try checkExportAlive()
            try Task.checkCancellation()
            if let hook = exportPDFCaptureWillCaptureHook {
                try await hook(index)
            }
            guard contentBounds.insetBy(dx: -0.5, dy: -0.5).contains(rect) else {
                throw ExportPDFCaptureError.captureFailed("rect-outside-view")
            }
            let configuration = WKPDFConfiguration()
            configuration.rect = rect
            do {
                try await pages.append(webView.pdf(configuration: configuration))
            } catch {
                try checkExportAlive()
                throw ExportPDFCaptureError.captureFailed(error.localizedDescription)
            }
        }
        guard !pages.isEmpty else { throw ExportPDFCaptureError.emptyDocument }
        return pages
    }

    /// Joining and re-parsing is pure CoreGraphics on `Data`, so it runs off the main
    /// actor; WebKit calls stay on main. Cancellation is forwarded into the worker.
    private func joinAndReparse(
        _ pieces: [Data],
        scale: CGFloat
    ) async throws -> (data: Data, pageCount: Int) {
        let task = Task.detached(priority: .userInitiated) { () throws -> (Data, Int) in
            try Task.checkCancellation()
            let data = try ExportPDFPageJoiner.join(pieces, scale: scale)
            try Task.checkCancellation()
            guard let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider),
                  document.numberOfPages > 0
            else { throw ExportPDFCaptureError.emptyDocument }
            return (data, document.numberOfPages)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
