import AppKit
import MarkdownCore
import PDFKit
@testable import Plainsong
@testable import PreviewKit
@testable import WorkspaceKit
import XCTest

/// C2 (`docs/export-gates.md`): a page wider than the 14,400 pt user space is scaled
/// down in PDF space and the export still succeeds — with a warning notice that names
/// the shrunk pages and the smallest percentage, not a failure. Print of the same
/// document stays silent.
@MainActor
final class ExportPDFShrunkPagesAppTests: XCTestCase {
    /// One minified line in a code fence stays on a single line and measures far past
    /// 14,400 pt wide, so its page shrinks to ~7% and the file still commits.
    func testMinifiedLongLineWritesFileWithAShrunkPagesWarning() async throws {
        let support = ExportHTMLCommandAppTests()
        // `text`, not a bare fence: highlight.js auto-detection of a 40,000-char line
        // took ~12 s a test on hosted CI and does not change the line's width.
        let source = "# Minified\n\n```text\n" + String(repeating: "W", count: 40000) + "\n```\n"
        let fixture = try support.makeFixture(text: source)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.exportsDirectory.appendingPathComponent("minified.pdf")
        let recorder = fixture.record(returning: [destination])
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsPDF()).value
        guard case let .exported(_, _, shrunkPages) = recorder.results.first?.result else {
            return XCTFail("Expected a committed export, got \(recorder.results)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let data = try Data(contentsOf: destination)
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        XCTAssertFalse(shrunkPages.isEmpty)
        let notice = try XCTUnwrap(fixture.appState.exportHTMLNotice)
        XCTAssertEqual(notice.group, .exportedWithShrunkPages)
        XCTAssertEqual(notice.severity, .warning)
        XCTAssertEqual(notice.title, "Exported as PDF with Shrunk Pages")
        for page in shrunkPages {
            XCTAssertTrue(
                notice.message.contains("Page \(page.pageNumber)"),
                "The notice must name page \(page.pageNumber): \(notice.message)"
            )
        }
        XCTAssertTrue(notice.message.contains("%"))
        XCTAssertTrue(notice.message.contains("200 inches"))
    }

    /// A fixture under the width limit still lands on the ordinary success notice.
    func testNormalWidthExportKeepsTheExportedSuccessNotice() async throws {
        let support = ExportHTMLCommandAppTests()
        let fixture = try support.makeFixture(text: "# Ordinary\n\nA paragraph.\n")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.exportsDirectory.appendingPathComponent("ordinary.pdf")
        let recorder = fixture.record(returning: [destination])
        try await XCTUnwrap(fixture.appState.exportCurrentDocumentAsPDF()).value
        guard case let .exported(_, _, shrunkPages) = recorder.results.first?.result else {
            return XCTFail("Expected a committed export, got \(recorder.results)")
        }
        XCTAssertTrue(shrunkPages.isEmpty)
        XCTAssertEqual(fixture.appState.exportHTMLNotice?.group, .exported)
        XCTAssertEqual(fixture.appState.exportHTMLNotice?.title, "Exported as PDF")
    }

    /// A wide document prints silently: shrunk pages are a PDF-file concern, and the
    /// print path reports no notice.
    func testShrunkPrintStaysSilent() async throws {
        let support = ExportHTMLCommandAppTests()
        let source = "```text\n" + String(repeating: "W", count: 40000) + "\n```\n"
        let fixture = try support.makeFixture(text: source)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var results: [ExportHTMLOperationResult] = []
        fixture.appState.exportHTMLOperations.didFinishOperation = { _, result in
            results.append(result)
        }
        fixture.appState.exportHTMLOperations.printOperationRunner = { _, _ in true }
        try await XCTUnwrap(fixture.appState.printCurrentDocument()).value
        XCTAssertEqual(results, [.printed])
        XCTAssertNil(fixture.appState.exportHTMLNotice)
    }

    /// The warning sentence names up to three pages, then counts the rest, and floors
    /// the smallest scale to a percentage.
    func testShrunkPagesDetailWording() {
        let pages: (ClosedRange<Int>, CGFloat) -> [ExportPDFShrunkPage] = { range, scale in
            range.map { ExportPDFShrunkPage(pageNumber: $0, scale: scale) }
        }
        var detail = ExportHTMLNoticeMapper.shrunkPagesDetail(pages(3 ... 3, 0.07))
        XCTAssertTrue(detail.contains("Page 3 was shrunk to 7%"))
        detail = ExportHTMLNoticeMapper.shrunkPagesDetail(pages(3 ... 4, 0.5))
        XCTAssertTrue(detail.contains("Pages 3 and 4 were shrunk (to as little as 50%)"))
        detail = ExportHTMLNoticeMapper.shrunkPagesDetail(pages(3 ... 5, 0.5))
        XCTAssertTrue(detail.contains("Pages 3, 4, and 5 were shrunk (to as little as 50%)"))
        detail = ExportHTMLNoticeMapper.shrunkPagesDetail(pages(1 ... 4, 0.5))
        XCTAssertTrue(detail.contains("Pages 1, 2, 3, and 1 other were shrunk"))
        detail = ExportHTMLNoticeMapper.shrunkPagesDetail(pages(1 ... 7, 0.5))
        XCTAssertTrue(detail.contains("Pages 1, 2, 3, and 4 others were shrunk"))
        detail = ExportHTMLNoticeMapper.shrunkPagesDetail(pages(1 ... 1, 0.004))
        XCTAssertTrue(detail.contains("less than 1%"))
        XCTAssertTrue(ExportHTMLNoticeMapper.shrunkPagesDetail([]).isEmpty)
    }
}
