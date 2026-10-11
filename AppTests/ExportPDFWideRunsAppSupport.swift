import AppKit
import MarkdownCore
import PDFKit
@testable import Plainsong
@testable import PreviewKit
@testable import WorkspaceKit
import XCTest

/// Shared fixtures and invariants for the hosted wide-run export tests
/// (`ExportPDFWideRunsAppTests`, `ExportPDFWideRunsEdgeAppTests`).
@MainActor
enum ExportPDFWideRunsAppSupport {
    /// Run pages shrink to fit (scale < 1); every other page keeps the baseline
    /// width at scale 1 — prose never shrinks for somebody else's overflow.
    static func assertRunPagesShrinkProsePagesDoNot(
        pdf: ExportPDFDocument,
        document: PDFDocument,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(pdf.pageScales.count, document.pageCount, file: file, line: line)
        for index in 0 ..< document.pageCount {
            let scale = pdf.pageScales[index]
            let box = document.page(at: index)?.bounds(for: .mediaBox) ?? .zero
            if scale < 1 {
                XCTAssertEqual(
                    box.width, 14400, accuracy: 1,
                    "Run page \(index + 1) must fill the user space", file: file, line: line
                )
            } else {
                XCTAssertEqual(
                    pdf.pageWidths[index], box.width, accuracy: 1,
                    file: file, line: line
                )
                XCTAssertLessThan(
                    box.width, 1100,
                    "Page \(index + 1) outside the run must keep baseline width",
                    file: file, line: line
                )
            }
            XCTAssertLessThanOrEqual(box.height, 14400.5, file: file, line: line)
        }
    }

    /// No output page has empty PDFKit text extraction; that is the blank-page proxy.
    static func assertNoBlankPage(
        _ document: PDFDocument,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for index in 0 ..< document.pageCount {
            let text = document.page(at: index)?.string ?? ""
            XCTAssertFalse(
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Page \(index + 1) is blank",
                file: file, line: line
            )
        }
    }

    static func assertEveryPageWithinHardBudget(
        pdf: ExportPDFDocument,
        document: PDFDocument,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(pdf.pageWidths.count, document.pageCount, file: file, line: line)
        XCTAssertEqual(pdf.pageScales.count, document.pageCount, file: file, line: line)
        for index in 0 ..< document.pageCount {
            let page = document.page(at: index)
            let scale = pdf.pageScales[index]
            let captureWidth = pdf.pageWidths[index] / scale
            let captureHeight = (page?.bounds(for: .mediaBox).height ?? 0) / scale
            let hardBudget = min(
                ExportPDFPagePlanner.maximumSide,
                ExportPDFPagePlanner.captureAreaBudget / captureWidth
            )
            XCTAssertLessThanOrEqual(
                captureHeight, hardBudget + 0.5,
                "Page \(index + 1) height \(captureHeight) exceeds hard budget \(hardBudget)",
                file: file, line: line
            )
        }
    }

    static func inkPixelCount(in page: PDFPage) -> Int {
        let bounds = page.bounds(for: .mediaBox)
        let maxPixels: CGFloat = 2_000_000
        let pixelScale = min(1, sqrt(maxPixels / (bounds.width * bounds.height)))
        let pixelWidth = max(1, Int(ceil(bounds.width * pixelScale)))
        let pixelHeight = max(1, Int(ceil(bounds.height * pixelScale)))
        var pixels = [UInt8](repeating: 255, count: pixelWidth * pixelHeight * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let drewPage = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            context.scaleBy(x: pixelScale, y: pixelScale)
            page.draw(with: .mediaBox, to: context)
            return true
        }
        guard drewPage else { return 0 }
        var count = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[offset] < 245 || pixels[offset + 1] < 245 || pixels[offset + 2] < 245 {
                count += 1
            }
        }
        return count
    }

    static func assertEveryPageHasInk(
        in document: PDFDocument,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for index in 0 ..< document.pageCount {
            let page = document.page(at: index)
            let inkPixels = page.map { inkPixelCount(in: $0) } ?? 0
            XCTAssertGreaterThan(
                inkPixels, 0,
                "Page \(index + 1) contains no rendered ink",
                file: file, line: line
            )
        }
    }

    static func prose(prefix: String, count: Int) -> (markdown: String, markers: [String]) {
        let markers = (0 ..< count).map { String(format: "%@%04d", prefix, $0) }
        let markdown = markers.map { "\($0) prose paragraph." }.joined(separator: "\n\n")
        return (markdown, markers)
    }

    /// ~40-word paragraphs that reflow when the root widens during the geometry
    /// settle — the Y1 fixture shape the one-line `prose` paragraphs cannot
    /// produce.
    static func wrappingProse(
        prefix: String, count: Int
    ) -> (markdown: String, markers: [String]) {
        let markers = (0 ..< count).map { String(format: "%@%04d", prefix, $0) }
        let markdown = markers.map { marker in
            marker + " " + (0 ..< 5).map { sentence in
                "wraps onto several lines in the preview so sentence \(sentence) reflows."
            }.joined(separator: " ")
        }.joined(separator: "\n\n")
        return (markdown, markers)
    }

    /// Marker groups flattened in order — a typed helper instead of `+` chains.
    static func markers(_ groups: [String]...) -> [String] {
        groups.flatMap { $0 }
    }

    /// No page may mix run markers with prose markers; every page holds one kind
    /// or the other (a page with neither would be blank).
    static func assertNoPageMixesMarkers(
        _ document: PDFDocument,
        runMarkerPrefixes: [String],
        proseMarkerPrefixes: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for index in 0 ..< document.pageCount {
            let text = document.page(at: index)?.string ?? ""
            let holdsRun = runMarkerPrefixes.contains { text.contains($0) }
            let holdsProse = proseMarkerPrefixes.contains { text.contains($0) }
            XCTAssertNotEqual(
                holdsRun, holdsProse,
                "Page \(index + 1) mixes run and prose markers (or is blank)",
                file: file, line: line
            )
        }
    }

    /// A solid-color PNG at an exact pixel size, for atomic boxes of a known
    /// rendered height.
    static func pngData(size: NSSize) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        for x in stride(from: 0, to: Int(size.width), by: 8) {
            for y in stride(from: 0, to: Int(size.height), by: 8) {
                bitmap.setColor(.systemTeal, atX: x, y: y)
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    /// One wide header row plus short single-cell body rows; the header drives the
    /// `max-content` table width while the rows give the run its height.
    static func tableSource(headerRow: [String], bodyRows: [String]) -> String {
        let header = "| " + headerRow.joined(separator: " | ") + " |\n"
        let delimiter = "| " + [String](repeating: "---", count: headerRow.count)
            .joined(separator: " | ") + " |\n"
        return header + delimiter + bodyRows.joined(separator: "\n") + "\n"
    }

    static func g3TableSource(imageHeight: Int) throws -> String {
        let image = try pngData(size: NSSize(width: 10, height: imageHeight))
        let token = String(repeating: "W", count: 20000)
        return "| image | blob |\n| --- | --- |\n"
            + "| ![tall](data:image/png;base64,\(image.base64EncodedString())) | \(token) |\n"
    }

    static func capture(
        _ markdown: String,
        fileKind: FileKind = .markdown
    ) async throws -> (PreviewController, ExportPDFDocument) {
        let controller = try await preparedController(markdown, fileKind: fileKind)
        let start = Date()
        let pdf = try await controller.captureExportPDF()
        let seconds = Date().timeIntervalSince(start)
        XCTAssertEqual(pdf.droppedTrailingBlankPages, 0)
        print(String(
            format: "E1 CAPTURE pages=%d planned=%d widest=%.1fpt minScale=%.3f time=%.2fs content=%.0fx%.0f",
            pdf.pageCount, pdf.plannedPageCount, pdf.pageWidths.max() ?? 0,
            pdf.minimumScale, seconds, pdf.contentSize.width, pdf.contentSize.height
        ))
        return (controller, pdf)
    }

    static func preparedController(
        _ markdown: String,
        fileKind: FileKind = .markdown
    ) async throws -> PreviewController {
        let controller = try await PreviewController.makeHTMLExportController()
        controller.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        controller.setAllowsRemoteImages(false)
        controller.setTheme("light")
        let render = await controller.renderForExport(DocumentTextChange(
            text: markdown, version: 1, fileKind: fileKind, fileURL: nil
        ))
        guard case let .completed(renderID) = render else {
            controller.invalidate()
            throw ExportPDFCaptureError.captureFailed("render")
        }
        guard case .ready = await controller.exportHTML(matchingRenderID: renderID) else {
            controller.invalidate()
            throw ExportPDFCaptureError.captureFailed("barrier")
        }
        return controller
    }

    static func text(of data: Data) -> String {
        guard let document = PDFDocument(data: data) else { return "" }
        return (0 ..< document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }
}
