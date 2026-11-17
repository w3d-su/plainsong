import AppKit
import MarkdownCore
import PDFKit
@testable import Plainsong
@testable import PreviewKit
import XCTest

/// E5 (`docs/export-gates.md`): Export as PDF… and Print… capture the same finalized
/// offscreen snapshot, and both PDFs paint its raster image and its highlighted code
/// colors, not only their text. Print is light whatever the preference (B1); PDF keeps
/// the resolved invocation theme.
@MainActor
final class ExportPDFContentAppTests: XCTestCase {
    private static let source = """
    # PDF Content Fixture

    Plainprose control sentence without any highlighting.

    ![swatch](assets/swatch.png)

    ```swift
    struct ContentProbe {
        let value = 42
    }
    ```
    """

    private static let swatchSize = NSSize(width: 96, height: 48)

    func testPDFAndPrintPaintTheFinalizedImageAndHighlightedCodeFromOneSnapshot() async throws {
        let support = ExportHTMLCommandAppTests()
        let lightPDF = try await capture(.pdf, theme: .light, support: support)
        let darkPDF = try await capture(.pdf, theme: .dark, support: support)
        // A dark preference still prints light (B1).
        let print = try await capture(.print, theme: .dark, support: support)

        XCTAssertEqual(lightPDF.snapshot.theme, "light")
        XCTAssertEqual(darkPDF.snapshot.theme, "dark")
        XCTAssertEqual(print.snapshot.theme, "light")
        // One snapshot: PDF and Print captured the same finalized DOM content.
        XCTAssertEqual(print.snapshot.content, lightPDF.snapshot.content)
        XCTAssertEqual(darkPDF.snapshot.content, lightPDF.snapshot.content)

        for (label, result) in [("PDF light", lightPDF), ("PDF dark", darkPDF), ("Print", print)] {
            let snapshot = result.snapshot
            XCTAssertEqual(snapshot.images, ["data:96x48"], "\(label): image not finalized")
            XCTAssertGreaterThanOrEqual(snapshot.keywords, 2, "\(label): code not highlighted")
            let pages = (0 ..< result.document.pageCount).compactMap { result.document.page(at: $0) }
            let swatch = pages.map { Self.tealPixelCount(in: $0) }.reduce(0, +)
            // 96×48 pt at 2× is 18,432 pixels; demand most of them.
            XCTAssertGreaterThan(swatch, 12000, "\(label): the image was not painted")
            let page = try XCTUnwrap(pages.first { $0.string?.contains("ContentProbe") ?? false }, label)
            let keyword = Self.saturatedPixelCount(of: "struct", on: page)
            let prose = Self.saturatedPixelCount(of: "Plainprose", on: page)
            XCTAssertGreaterThan(keyword, 20, "\(label): the keyword is not painted in color")
            XCTAssertLessThan(prose, 3, "\(label): the prose control is colored")
        }
    }

    /// The pixel detector sees nothing teal when the image is missing, so the counts
    /// above come from the embedded image and not from theme or code colors.
    func testMissingImagePaintsNoSwatch() async throws {
        let support = ExportHTMLCommandAppTests()
        let result = try await capture(.pdf, theme: .light, support: support, writesSwatch: false)
        XCTAssertEqual(result.snapshot.images, [])
        let pages = (0 ..< result.document.pageCount).compactMap { result.document.page(at: $0) }
        XCTAssertEqual(pages.map { Self.tealPixelCount(in: $0) }.reduce(0, +), 0)
    }

    // MARK: - Capture

    private enum Product { case pdf, print }

    private struct CaptureFailed: Error {}

    private struct SnapshotSummary {
        var theme = ""
        var content = ""
        var images: [String] = []
        var keywords = 0
    }

    private struct Capture {
        let snapshot: SnapshotSummary
        let document: PDFDocument
    }

    private func capture(
        _ product: Product,
        theme: PlainsongPreferences.PreviewTheme,
        support: ExportHTMLCommandAppTests,
        writesSwatch: Bool = true
    ) async throws -> Capture {
        let fixture = try support.makeFixture(name: "content.md", text: Self.source)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        if writesSwatch {
            try Self.swatchPNG().write(to: fixture.root.appendingPathComponent("assets/swatch.png"))
        }
        fixture.appState.preferences.setPreviewTheme(theme)
        var results: [ExportHTMLOperationResult] = []
        var snapshot = SnapshotSummary()
        var printed: PDFDocument?
        fixture.appState.exportHTMLOperations.didFinishOperation = { _, result in results.append(result) }
        // Runs after the capture, against the offscreen DOM that was just captured.
        fixture.appState.exportHTMLOperations.didPrepareArtifact = {
            guard let webView = fixture.appState.exportHTMLOperations.offscreenController?.webView else { return }
            let json = try? await webView.evaluateJavaScript(Self.snapshotScript) as? String
            snapshot = Self.summary(json)
        }
        let destination = fixture.exportsDirectory.appendingPathComponent("content-\(theme.rawValue).pdf")
        switch product {
        case .pdf:
            fixture.appState.exportHTMLOperations.destinationChooser = { _ in destination }
            try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsPDF()).value
            guard case .exported = results.first else {
                XCTFail("PDF export under \(theme) did not commit: \(results)")
                throw CaptureFailed()
            }
            let document = try XCTUnwrap(PDFDocument(data: Data(contentsOf: destination)))
            return Capture(snapshot: snapshot, document: document)
        case .print:
            fixture.appState.exportHTMLOperations.destinationChooser = { _ in
                XCTFail("Print must not open a save panel")
                return nil
            }
            fixture.appState.exportHTMLOperations.printDocumentObserver = { printed = $0 }
            fixture.appState.exportHTMLOperations.printOperationRunner = { _, _ in true }
            try await XCTUnwrap(fixture.appState.printCurrentDocument()).value
            XCTAssertEqual(results, [.printed])
            return try Capture(snapshot: snapshot, document: XCTUnwrap(printed, "no print PDF observed"))
        }
    }

    private static let snapshotScript = """
    JSON.stringify({
      theme: document.documentElement.dataset.theme,
      content: document.body.innerText,
      images: [...document.images].filter((image) => image.complete && image.naturalWidth > 0)
        .map((image) => image.src.split(':')[0] + ':' + image.naturalWidth + 'x' + image.naturalHeight),
      keywords: document.querySelectorAll('pre code.hljs .hljs-keyword').length,
    })
    """

    private static func summary(_ json: String?) -> SnapshotSummary {
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return SnapshotSummary() }
        return SnapshotSummary(
            theme: object["theme"] as? String ?? "",
            content: object["content"] as? String ?? "",
            images: object["images"] as? [String] ?? [],
            keywords: object["keywords"] as? Int ?? 0
        )
    }

    // MARK: - Pixels

    private static func swatchPNG() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(swatchSize.width),
            pixelsHigh: Int(swatchSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        for column in 0 ..< Int(swatchSize.width) {
            for row in 0 ..< Int(swatchSize.height) {
                bitmap.setColor(ExportPDFWideRunsAppSupport.fixtureTeal, atX: column, y: row)
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    /// Pixels within a few levels of `fixtureTeal` (48, 176, 199) at 2×.
    private static func tealPixelCount(in page: PDFPage) -> Int {
        let pixels = render(page, rect: page.bounds(for: .mediaBox), scale: 2)
        var count = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
            if abs(red - 48) <= 12, abs(green - 176) <= 12, abs(blue - 199) <= 12 {
                count += 1
            }
        }
        return count
    }

    /// Pixels whose channels differ by at least 60 inside the first occurrence of `word`
    /// at 3×: colored ink. Body text and code backgrounds are gray in both themes.
    private static func saturatedPixelCount(of word: String, on page: PDFPage) -> Int {
        guard let text = page.string else { return -1 }
        let range = (text as NSString).range(of: word)
        guard range.location != NSNotFound, let selection = page.selection(for: range) else { return -1 }
        let pixels = render(page, rect: selection.bounds(for: page), scale: 3)
        var count = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let channels = [pixels[offset], pixels[offset + 1], pixels[offset + 2]]
            if let high = channels.max(), let low = channels.min(), Int(high) - Int(low) >= 60 {
                count += 1
            }
        }
        return count
    }

    /// RGBA bytes of `rect` (page space) drawn on white at `scale`.
    private static func render(_ page: PDFPage, rect: CGRect, scale: CGFloat) -> [UInt8] {
        let box = page.bounds(for: .mediaBox)
        let width = max(1, Int(ceil(rect.width * scale)))
        let height = max(1, Int(ceil(rect.height * scale)))
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: box.minX - rect.minX, y: box.minY - rect.minY)
            page.draw(with: .mediaBox, to: context)
        }
        return pixels
    }
}
