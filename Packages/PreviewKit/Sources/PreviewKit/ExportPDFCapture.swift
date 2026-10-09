import AppKit
import CoreGraphics
import Foundation
@preconcurrency import WebKit

public enum ExportPDFCaptureError: Error, Equatable, Sendable {
    case invalidated
    case webContentProcessTerminated
    case geometryUnstable
    /// One unbreakable run (line/atomic box chain) exceeds the hard height budget —
    /// a flat 14,400 CSS pt, lowered when the page's width would push the capture
    /// raster past `captureAreaBudget`; the value is its height in CSS points.
    case oversizeAtomicBox(heightPoints: CGFloat)
    /// A planned break would land strictly inside a fixed/sticky/transformed/floated
    /// element; the value identifies it as "tag.className".
    case breakCrossesPositionedContent(String)
    /// WebKit returned a different number of PDF pages than the plan asked for — an
    /// off-break split the plan cannot represent, so the export fails typed rather than
    /// emitting a mis-split document.
    case pageCountMismatch(planned: Int, captured: Int)
    case captureFailed(String)
    case emptyDocument
}

/// One PDF page that was scaled down in PDF space because its own width exceeded the
/// 14,400 pt user space.
public struct ExportPDFShrunkPage: Equatable, Sendable {
    /// 1-based page number in the written document.
    public let pageNumber: Int
    /// The PDF-space factor the page was drawn at (< 1).
    public let scale: CGFloat

    public init(pageNumber: Int, scale: CGFloat) {
        self.pageNumber = pageNumber
        self.scale = scale
    }
}

/// PDF bytes from one barrier-completed offscreen render.
public struct ExportPDFDocument: Equatable, Sendable {
    public let data: Data
    public let pageCount: Int
    /// The number of pages the planner emitted; equal to `pageCount` on success — a
    /// WebKit split would have thrown `pageCountMismatch` instead.
    public let plannedPageCount: Int
    /// The PDF-space scale applied to each output page; 1 unless the content on that
    /// page was wider than 14,400 pt.
    public let pageScales: [CGFloat]
    /// Each output page's media-box width in PDF points, after its scale.
    public let pageWidths: [CGFloat]
    /// The tallest output page in PDF points (≤ 14,400 by construction).
    public let maximumPageHeight: CGFloat
    public let contentSize: CGSize

    /// The smallest scale any output page received; 1 when nothing had to shrink.
    public var minimumScale: CGFloat {
        pageScales.min() ?? 1
    }

    /// The output pages (1-based) that were scaled down, in document order.
    public var shrunkPages: [ExportPDFShrunkPage] {
        pageScales.enumerated().compactMap { index, scale in
            scale < 1
                ? ExportPDFShrunkPage(pageNumber: index + 1, scale: scale)
                : nil
        }
    }
}

extension PreviewController {
    /// Export-only overflow expansion, then variable-height, per-page-width pagination
    /// (`docs/export-gates.md` D4). Everything happens at full size: no zoom and no
    /// width ceiling; a page whose own width exceeds 14,400 pt is scaled down in PDF
    /// space when joined, leaving the rest at 100%. `pageAspect` — the paper imageable
    /// `height / width` — bounds page height for Print as a soft budget; nil plans
    /// plain PDF pages.
    public func captureExportPDF(pageAspect: CGFloat? = nil) async throws -> ExportPDFDocument {
        try checkExportAlive()
        try await applyExportOverflowStyle()
        let geometry = try await settleExportGeometry()
        try checkExportAlive()
        // The root's measured border edge after the settle: the baseline width every
        // page at least covers, clamped into the settled content width.
        let measured = try await measureUnsplittableSpans()
        try checkExportAlive()
        let baselineWidth = min(geometry.width, max(measured.baselineWidth, 1))
        let plan = try ExportPDFPagePlanner.plan(
            contentSize: geometry,
            baselineWidth: baselineWidth,
            unsplittable: measured.spans,
            widthExtents: measured.wide,
            targetAspect: pageAspect
        )
        // A fixed/sticky/transformed/floated box cannot be proven safe across a break
        // (the A1 design stop): fail typed only when a planned break would cross one.
        for page in plan.pages.dropLast() {
            if let offender = measured.offenders.first(where: {
                $0.minY + 0.5 < page.rect.maxY && page.rect.maxY < $0.maxY - 0.5
            }) {
                throw ExportPDFCaptureError.breakCrossesPositionedContent(
                    "\(offender.tag).\(offender.className)"
                )
            }
        }
        let pieces = try await captureExportPages(plan.pages.map(\.rect), inside: geometry)
        let joined = try await joinAndReparse(pieces, scales: plan.pages.map(\.scale))
        return ExportPDFDocument(
            data: joined.data,
            pageCount: joined.pageSizes.count,
            plannedPageCount: plan.pages.count,
            pageScales: joined.pageScales,
            pageWidths: joined.pageSizes.map(\.width),
            maximumPageHeight: joined.pageSizes.map(\.height).max() ?? 0,
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
            let piece: Data
            do {
                piece = try await webView.pdf(configuration: configuration)
            } catch {
                try checkExportAlive()
                throw ExportPDFCaptureError.captureFailed(error.localizedDescription)
            }
            // One planned page must come back as exactly one PDF page: a piece WebKit
            // split or merged on its own means the file no longer matches the plan.
            let captured = CGDataProvider(data: piece as CFData)
                .flatMap(CGPDFDocument.init)?
                .numberOfPages ?? 0
            guard captured == 1 else {
                throw ExportPDFCaptureError.pageCountMismatch(planned: 1, captured: captured)
            }
            pages.append(piece)
        }
        guard !pages.isEmpty else { throw ExportPDFCaptureError.emptyDocument }
        return pages
    }

    /// Joining and re-parsing is pure CoreGraphics on `Data`, so it runs off the main
    /// actor; WebKit calls stay on main. Cancellation is forwarded into the worker.
    private func joinAndReparse(
        _ pieces: [Data],
        scales: [CGFloat]
    ) async throws -> (data: Data, pageScales: [CGFloat], pageSizes: [CGSize]) {
        let task = Task.detached(priority: .userInitiated) { () throws -> (Data, [CGFloat], [CGSize]) in
            try Task.checkCancellation()
            let joined = try ExportPDFPageJoiner.join(pieces, scales: scales)
            try Task.checkCancellation()
            // One planned page must come back as exactly one PDF page: a piece WebKit
            // split on its own means the file no longer matches the plan.
            guard joined.pageScales.count == scales.count else {
                throw ExportPDFCaptureError.pageCountMismatch(
                    planned: scales.count,
                    captured: joined.pageScales.count
                )
            }
            guard let provider = CGDataProvider(data: joined.data as CFData),
                  let document = CGPDFDocument(provider),
                  document.numberOfPages > 0
            else { throw ExportPDFCaptureError.emptyDocument }
            var pageSizes: [CGSize] = []
            pageSizes.reserveCapacity(document.numberOfPages)
            for number in 1 ... document.numberOfPages {
                guard let page = document.page(at: number) else {
                    throw ExportPDFCaptureError.captureFailed("pdf-page")
                }
                let box = page.getBoxRect(.mediaBox)
                pageSizes.append(CGSize(width: box.width, height: box.height))
            }
            return (joined.data, joined.pageScales, pageSizes)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
