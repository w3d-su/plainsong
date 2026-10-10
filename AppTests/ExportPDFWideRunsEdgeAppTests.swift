import AppKit
import MarkdownCore
import PDFKit
@testable import Plainsong
@testable import PreviewKit
@testable import WorkspaceKit
import XCTest

/// 20d edge coverage for the hosted wide-run pipeline (`docs/export-gates.md`
/// D4): the leading-run gap absorbs into the run's first page, the settled
/// content height leaves no trailing blank page, clipped hidden text cannot
/// fabricate a run, an over-area atomic box fails typed, and a joiner
/// page-count mismatch surfaces the internal-pagination notice.
@MainActor
final class ExportPDFWideRunsEdgeAppTests: XCTestCase {
    private typealias Support = ExportPDFWideRunsAppSupport

    /// X1 hosted: a document that *begins* with a very wide table must not emit
    /// a blank leading page — the run absorbs the small gap above its first
    /// span, page 1 holds table markers, and no page mixes run and prose.
    func testDocumentStartingWithAWideTableHasNoBlankFirstPage() async throws {
        let (after, afterMarkers) = Support.prose(prefix: "LEADAFTER", count: 150)
        let columnMarkers = (0 ..< 40).map { String(format: "LEADTBLCOL%02dSENTINEL", $0) }
        let header = columnMarkers.map { $0 + String(repeating: "x", count: 520) }
        let rowMarkers = (0 ..< 60).map { String(format: "LEADTBLROW%04dSENTINEL", $0) }
        let table = Support.tableSource(headerRow: header, bodyRows: rowMarkers.map { "| \($0) |" })
        let source = [table, after].joined(separator: "\n\n")
        let (controller, pdf) = try await Support.capture(source)
        defer { controller.invalidate() }
        XCTAssertEqual(pdf.pageCount, pdf.plannedPageCount)
        let document = try XCTUnwrap(PDFDocument(data: pdf.data))
        XCTAssertEqual(document.pageCount, pdf.plannedPageCount)
        Support.assertNoBlankPage(document)
        let first = try XCTUnwrap(document.page(at: 0)?.string)
        XCTAssertTrue(
            first.contains("LEADTBLCOL") || first.contains("LEADTBLROW"),
            "Page 1 must hold the leading table, not blank space"
        )
        Support.assertNoPageMixesMarkers(
            document,
            runMarkerPrefixes: ["LEADTBLCOL", "LEADTBLROW"],
            proseMarkerPrefixes: ["LEADAFTER"]
        )
        try ExportPDFMechanismSpikeTests.assertEverySentinelAppearsOnceInOrder(
            Support.markers(columnMarkers, rowMarkers, afterMarkers),
            in: Support.text(of: pdf.data)
        )
    }

    /// Y1: B2 exercised with real reflow — 300 wrapping paragraphs of ~60 words,
    /// so the root's settle-time widening reflows every line — and the web view
    /// starts with a frame far taller than the content, the shape that once hid
    /// the height bug: `clientHeight` echoes the *current frame*, so the old
    /// `max(scrollHeight, clientHeight)` measure pinned the settle at 80,000 pt
    /// and produced blank tail pages, while the content measure converges to
    /// ~32,476 pt. The settled content height must track the last child's
    /// bottom plus the root's bottom padding (within 60 pt), and the
    /// trailing-page safety net must drop nothing.
    func testWrappingParagraphsMeasureTheContentHeight() async throws {
        let (source, markers) = Support.wrappingProse(prefix: "WRAPB2", count: 300)
        let controller = try await Support.preparedController(source)
        controller.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 80000)
        let start = Date()
        let pdf = try await controller.captureExportPDF()
        print(String(
            format: "E1 CAPTURE pages=%d planned=%d widest=%.1fpt minScale=%.3f time=%.2fs content=%.0fx%.0f",
            pdf.pageCount, pdf.plannedPageCount, pdf.pageWidths.max() ?? 0,
            pdf.minimumScale, Date().timeIntervalSince(start),
            pdf.contentSize.width, pdf.contentSize.height
        ))
        defer { controller.invalidate() }
        let lastBottom = try await controller.webView.evaluateJavaScript("""
        (() => {
          const root = document.getElementById("preview-root");
          const style = getComputedStyle(root);
          const padB = parseFloat(style.paddingBottom) || 0;
          const borderB = parseFloat(style.borderBottomWidth) || 0;
          return root.lastElementChild.getBoundingClientRect().bottom
            + window.scrollY + padB + borderB;
        })()
        """) as? Double
        XCTAssertEqual(
            pdf.contentSize.height, CGFloat(lastBottom ?? -1), accuracy: 60,
            "Content height must come from the last child's bottom, not scrollHeight"
        )
        XCTAssertEqual(
            pdf.droppedTrailingBlankPages, 0,
            "The safety net must drop nothing on a content-measured height"
        )
        let document = try XCTUnwrap(PDFDocument(data: pdf.data))
        Support.assertNoBlankPage(document)
        try ExportPDFMechanismSpikeTests.assertEverySentinelAppearsOnceInOrder(
            markers, in: Support.text(of: pdf.data)
        )
    }

    /// X2: a clipped `.mdx-esm-placeholder` — an `import` line the pill truncates
    /// and hides behind `overflow: hidden` — must not measure past the pill's
    /// painted edge: the hidden text's ~1,000+ pt right edge is clipped away, so
    /// no extent crosses the run threshold and no run can form (Print's
    /// threshold is baseline / 0.9; PDF's is 14,400). The pill's own element box
    /// may still report a sub-pixel extent a fraction past the content edge —
    /// its painted background legitimately ends there — so the assertion is
    /// against the run threshold, not emptiness.
    func testClippedMdxPlaceholderProducesNoWideExtent() async throws {
        let source = """
        ---
        title: Imports
        ---
        import { Tabs, TabItem, Aside, Card, CardGrid, LinkButton, FileTree, Steps } from '@astrojs/starlight/components';
        import MyLongComponentName from '../../../components/demo/MyLongComponentNameForPlaceholderClipping.astro';

        # Imports

        Short post body.
        """
        let controller = try await Support.preparedController(source, fileKind: .mdx)
        defer { controller.invalidate() }
        _ = try await controller.captureExportPDF()
        let measured = try await controller.measureUnsplittableSpans()
        let printWideThreshold = measured.baselineWidth / ExportPDFPagePlanner.printWideFraction
        XCTAssertTrue(
            measured.wide.allSatisfy { $0.maxX < printWideThreshold },
            "Clipped placeholder text produced a run-wide extent "
                + "(threshold \(printWideThreshold)): \(measured.wide)"
        )
    }

    /// G3: one unbreakable box whose own capture raster exceeds the 2²⁹ px² area
    /// budget — a ~2,000 pt tall image in a ~286,000 pt wide table row — fails
    /// typed `oversizeCaptureArea` reporting CSS points, surfaces the truthful
    /// "too large" notice, and writes nothing.
    func testOversizeCaptureAreaBoxFailsTypedAndWritesNothing() async throws {
        let image = try Support.pngData(size: NSSize(width: 10, height: 2000))
        let token = String(repeating: "W", count: 20000)
        let source = "# Oversize\n\nOAINTROSENTINEL before.\n\n| image | blob |\n"
            + "| --- | --- |\n| ![tall](data:image/png;base64,\(image.base64EncodedString())) | "
            + token + " |\n\nOAOUTROSENTINEL after.\n"
        let controller = try await Support.preparedController(source)
        defer { controller.invalidate() }
        do {
            _ = try await controller.captureExportPDF()
            XCTFail("An over-budget box must fail the capture")
        } catch let ExportPDFCaptureError.oversizeCaptureArea(widthPoints, heightPoints) {
            XCTAssertGreaterThan(
                widthPoints * heightPoints, ExportPDFPagePlanner.captureAreaBudget
            )
            XCTAssertLessThanOrEqual(
                heightPoints, ExportPDFPagePlanner.maximumSide + 0.5,
                "A box taller than 14,400 pt would be oversizeAtomicBox instead"
            )
        }
        // The full command path: typed failure reaches the notice and no file.
        let support = ExportHTMLCommandAppTests()
        let fixture = try support.makeFixture(text: source)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.exportsDirectory.appendingPathComponent("oversize.pdf")
        fixture.appState.exportHTMLOperations.destinationChooser = { _ in destination }
        var results: [ExportHTMLOperationResult] = []
        fixture.appState.exportHTMLOperations.didFinishOperation = { _, result in
            results.append(result)
        }
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsPDF()).value
        guard case .stopped(.captureFailed(.oversizeCaptureArea)) = results.first else {
            return XCTFail("Expected stopped(.captureFailed(.oversizeCaptureArea)), got \(results)")
        }
        let notice = try XCTUnwrap(fixture.appState.exportHTMLNotice)
        XCTAssertTrue(notice.message.contains("too large to export as one PDF page"))
        XCTAssertTrue(notice.message.contains("inches"))
        XCTAssertTrue(notice.message.contains("Split the table or make the image smaller"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// Low 1: a joined document whose page count does not match the plan — here
    /// driven through the joiner seam — fails typed `pageCountMismatch`, writes
    /// nothing, and surfaces the internal-pagination notice rather than a
    /// "try again" that cannot help.
    func testJoinerPageCountMismatchFailsTypedAndWritesNothing() async throws {
        let support = ExportHTMLCommandAppTests()
        let fixture = try support.makeFixture(
            text: "# Mismatch\n\nMISMATCHSENTINEL A short post.\n"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.exportsDirectory.appendingPathComponent("mismatch.pdf")
        fixture.appState.exportHTMLOperations.destinationChooser = { _ in
            fixture.appState.exportHTMLOperations.offscreenController?
                .exportPDFPageJoiner = { pieces, scales in
                    // Join faithfully but report one page more than the pieces
                    // produced — the re-parse guard reads it as an off-plan split.
                    let joined = try ExportPDFPageJoiner.join(pieces, scales: scales)
                    return (data: joined.data, pageScales: joined.pageScales + [1])
                }
            return destination
        }
        var results: [ExportHTMLOperationResult] = []
        fixture.appState.exportHTMLOperations.didFinishOperation = { _, result in
            results.append(result)
        }
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsPDF()).value
        guard case .stopped(.captureFailed(.pageCountMismatch)) = results.first else {
            return XCTFail("Expected stopped(.captureFailed(.pageCountMismatch)), got \(results)")
        }
        XCTAssertEqual(
            fixture.appState.exportHTMLNotice?.message,
            "Nothing was written. Export failed because of an internal pagination error. "
                + "Please report this issue."
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
