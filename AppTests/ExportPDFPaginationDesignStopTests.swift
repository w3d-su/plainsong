import AppKit
import MarkdownCore
@testable import PreviewKit
import WebKit
import XCTest

/// Diagnostic only: reproduces handoff 20's no-dropped-content design stop.
/// A passing test records the current limitation, not E5/E8 product acceptance.
@MainActor
final class ExportPDFPaginationDesignStopTests: XCTestCase {
    func testFixedHeightCaptureDropsHorizontallyClippedTableContentAfterReadyBarrier() async throws {
        let controller = try await PreviewController.makeHTMLExportController()
        defer { controller.invalidate() }
        let probe = E0OffscreenPDFProbe(controller: controller)
        XCTAssertNil(controller.webView.window)
        controller.setTheme("light")
        let fixture = ExportPDFMechanismSpikeTests.tallFixture
        let columns = (0 ..< 12).map { String(format: "GCOLUMN%02dSENTINEL", $0) }
        let table = "| " + columns.joined(separator: " | ") + " |\n"
            + "| " + columns.map { _ in "---" }.joined(separator: " | ") + " |\n"
            + "| " + columns.map { _ in "value" }.joined(separator: " | ") + " |\n"
        let source = table + "\n" + fixture.markdown
        let render = await controller.renderForExport(DocumentTextChange(
            text: source, version: 1, fileKind: .markdown, fileURL: nil
        ))
        guard case let .completed(renderID) = render else {
            return XCTFail("Expected exact render completion: \(render)")
        }
        let ready = await controller.exportHTML(matchingRenderID: renderID)
        guard case let .ready(html, _, completedRenderID) = ready else {
            return XCTFail("Expected D2 resource readiness: \(ready)")
        }
        XCTAssertEqual(completedRenderID, renderID)
        for marker in columns {
            XCTAssertTrue(html.contains(marker))
        }
        let dom = try await probe.domState()
        for marker in columns {
            XCTAssertTrue(dom.text.contains(marker))
        }
        XCTAssertFalse(dom.stale)

        let geometry = try await probe.settleFullContentGeometry()
        XCTAssertGreaterThan(geometry.contentBounds.height, 14400)
        let measuredWidths = try await controller.webView.evaluateJavaScript("""
        (() => {
          const table = document.querySelector('#preview-root table');
          return [table.clientWidth, table.scrollWidth, document.documentElement.scrollWidth];
        })()
        """)
        let widths = try XCTUnwrap(measuredWidths as? [Double])
        XCTAssertEqual(widths.count, 3)
        XCTAssertGreaterThan(widths[1], widths[0])
        XCTAssertLessThanOrEqual(widths[2], geometry.contentBounds.width)
        let height = try await probe.chooseFixedPaginationHeight(contentBounds: geometry.contentBounds)
        let pages = try await probe.captureFixedHeightPages(
            contentBounds: geometry.contentBounds, pageHeight: height
        )
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertTrue(pages.flatMap(\.pageClaims).allSatisfy(\.hasValidDefaultUserSpace))
        let capturedText = pages.map(\.extractedText).joined(separator: "\n")
        try ExportPDFMechanismSpikeTests.assertEverySentinelAppearsOnceInOrder(
            fixture.sentinels, in: capturedText
        )
        XCTAssertTrue(capturedText.contains(columns[0]))
        XCTAssertFalse(capturedText.contains(columns[11]), "Reassess design stop if WebKit no longer clips")
        let missing = columns.filter { !capturedText.contains($0) }
        print("G DESIGN STOP width=\(geometry.contentBounds.width) tableWidths=\(widths) "
            + "height=\(geometry.contentBounds.height) pageHeight=\(height) "
            + "pages=\(pages.count) missing=\(missing)")
        attach(pages[0].data, name: "G-original-clipped-table.pdf")

        // Positive control only: expand this diagnostic DOM's table overflow, then recapture.
        // A production layout policy requires an owner decision; this is not a product fix.
        _ = try await controller.webView.evaluateJavaScript("""
        document.querySelector('#preview-root table').style.overflow = 'visible';
        document.querySelector('#preview-root table').style.maxWidth = 'none';
        """)
        let expanded = try await probe.settleFullContentGeometry()
        let control = try await probe.capturePDF(rect: CGRect(
            x: 0, y: 0, width: expanded.contentBounds.width, height: 600
        ))
        for marker in columns {
            XCTAssertTrue(control.extractedText.contains(marker))
        }
        print("G POSITIVE CONTROL expandedWidth=\(expanded.contentBounds.width) allTableSentinels=true")
        attach(control.data, name: "G-expanded-table-control.pdf")
        XCTAssertNil(controller.webView.window)
    }

    private func attach(_ data: Data, name: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "com.adobe.pdf")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
