import AppKit
import MarkdownCore
import PDFKit
@testable import PreviewKit
import XCTest

/// A1 hosted acceptance (`docs/export-gates.md` D4): every fixture captures through the
/// production `captureExportPDF`, every injected marker appears exactly once in order,
/// and every page stays inside the 14,400 pt default user space.
@MainActor
final class ExportPDFAcceptanceAppTests: XCTestCase {
    func testNamedFixtureAcceptance() async throws {
        for (name, ext, kind) in [
            ("perf-500kb", "md", FileKind.markdown),
            ("math-dense-100kb", "md", FileKind.markdown),
            ("perf-100kb", "md", FileKind.markdown),
            ("kitchen-sink", "md", FileKind.markdown),
            ("kitchen-sink", "mdx", FileKind.mdx),
            ("math", "md", FileKind.markdown),
        ] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
            let source = try String(contentsOf: url, encoding: .utf8)
            try await acceptFixture(label: "\(name).\(ext)", source: source, fileKind: kind)
        }
    }

    func testGeneratedLongFixturesAcceptance() async throws {
        // Zero-padded so no marker is a prefix of another one.
        let listMarkers = (0 ..< 700).map { String(format: "LISTSENTINEL%04d", $0) }
        let list = listMarkers.map { "- \($0) item with a little wrapping text" }
            .joined(separator: "\n")
        try await acceptFixture(
            label: "700-item list",
            source: "# List\n\n\(list)\n",
            fileKind: .markdown,
            markers: listMarkers
        )
        // Every one of the 800 line sentinels must appear exactly once and in order —
        // no line box may be dropped or duplicated across page breaks.
        let codeMarkers = (0 ..< 800).map { String(format: "CODESENTINEL%04d", $0) }
        let codeLines = codeMarkers.enumerated().map {
            String(format: "let codeline%04d = \"%@\"", $0, $1)
        }.joined(separator: "\n")
        try await acceptFixture(
            label: "800-line code",
            source: "# Code\n\n```swift\n\(codeLines)\n```\n",
            fileKind: .markdown,
            markers: codeMarkers
        )
        // Same contract for every row of the 2,000-row table.
        let tableMarkers = (0 ..< 2000).map { String(format: "TABLECELLSENTINEL%04d", $0) }
        let rows = tableMarkers.enumerated().map {
            String(format: "| ROW%04d | %@ |", $0, $1)
        }.joined(separator: "\n")
        let table = "| A | B |\n| --- | --- |\n\(rows)\n"
        try await acceptFixture(
            label: "2000-row table",
            source: table,
            fileKind: .markdown,
            markers: tableMarkers
        )
    }

    /// Opt-in: the 1 MB fixture belongs outside the always-run suite. Enable with
    /// `TEST_RUNNER_PLAINSONG_PDF_ACCEPTANCE_1MB=1`; its time and page count go to
    /// `docs/perf-log.md` under the recorded load.
    func testLarge1MBAcceptanceOptIn() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PLAINSONG_PDF_ACCEPTANCE_1MB"] == "1",
            "Opt-in only. Rerun with TEST_RUNNER_PLAINSONG_PDF_ACCEPTANCE_1MB=1; see docs/perf-log.md."
        )
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "large-1mb", withExtension: "md"))
        let source = try String(contentsOf: url, encoding: .utf8)
        try await acceptFixture(label: "large-1mb.md", source: source, fileKind: .markdown)
    }

    private func acceptFixture(
        label: String,
        source: String,
        fileKind: FileKind,
        markers: [String]? = nil
    ) async throws {
        let (marked, sentinels) = markers.map { (source, $0) }
            ?? Self.injectAcceptanceSentinels(into: source)
        let controller = try await PreviewController.makeHTMLExportController()
        defer { controller.invalidate() }
        controller.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        controller.setAllowsRemoteImages(false)
        controller.setTheme("light")
        let render = await controller.renderForExport(DocumentTextChange(
            text: marked, version: 1, fileKind: fileKind, fileURL: nil
        ))
        guard case let .completed(renderID) = render else {
            return XCTFail("\(label): render failed \(render)")
        }
        guard case .ready = await controller.exportHTML(matchingRenderID: renderID) else {
            return XCTFail("\(label): export barrier failed")
        }
        let start = Date()
        let pdf = try await controller.captureExportPDF()
        let seconds = Date().timeIntervalSince(start)
        let document = try XCTUnwrap(PDFDocument(data: pdf.data), "\(label): empty PDF")
        XCTAssertEqual(document.pageCount, pdf.pageCount, label)
        XCTAssertLessThanOrEqual(pdf.maximumPageHeight, 14400, label)
        for index in 0 ..< document.pageCount {
            let box = document.page(at: index)?.bounds(for: .mediaBox) ?? .zero
            XCTAssertLessThanOrEqual(box.width, 14400.5, label)
            XCTAssertLessThanOrEqual(box.height, 14400.5, label)
            XCTAssertGreaterThan(box.height, 0, label)
        }
        let text = Self.text(of: pdf.data)
        try ExportPDFMechanismSpikeTests.assertEverySentinelAppearsOnceInOrder(sentinels, in: text)
        let widestPage = pdf.pageWidths.max() ?? 0
        XCTContext.runActivity(named: String(
            format: "A1 acceptance %@ pages=%d widestPage=%.1fpt minScale=%.3f capture=%.2fs content=%.0fx%.0f",
            label, pdf.pageCount, widestPage, pdf.minimumScale, seconds,
            pdf.contentSize.width, pdf.contentSize.height
        )) { _ in }
        print(String(
            format: "A1 ACCEPTANCE %@ pages=%d widestPage=%.1fpt minScale=%.3f time=%.2fs",
            label, pdf.pageCount, widestPage, pdf.minimumScale, seconds
        ))
    }

    /// Three heading markers at the third boundaries so once-and-in-order can be
    /// asserted on fixtures that carry no sentinels of their own. Fixtures that open
    /// with a YAML frontmatter block get the markers after it — inserting inside the
    /// `---` fences would corrupt the parse and change what the fixture measures.
    private static func injectAcceptanceSentinels(into markdown: String) -> (String, [String]) {
        let markers = ["ACCEPTSENTINELBEGIN", "ACCEPTSENTINELMID", "ACCEPTSENTINELEND"]
        var lines = markdown.components(separatedBy: "\n")
        var bodyStart = 0
        if lines.first == "---",
           let close = lines.dropFirst().firstIndex(of: "---")
        {
            bodyStart = close + 1
        }
        let third = max((lines.count - bodyStart) / 3, 1)
        lines.insert("## \(markers[2])\n", at: min(bodyStart + third * 2 + 1, lines.count))
        lines.insert("## \(markers[1])\n", at: min(bodyStart + third, lines.count))
        lines.insert("## \(markers[0])\n", at: min(bodyStart + 1, lines.count))
        return (lines.joined(separator: "\n"), markers)
    }

    private static func text(of data: Data) -> String {
        guard let document = PDFDocument(data: data) else { return "" }
        return (0 ..< document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }
}
