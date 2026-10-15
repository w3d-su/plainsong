import AppKit
import MarkdownCore
import PDFKit
@testable import Plainsong
@testable import PreviewKit
@testable import WorkspaceKit
import XCTest

/// Print's per-page-width path hosted end to end (`docs/export-gates.md` D4 + the
/// 2026-10-08 owner decision): a tall atomic box extends its page past the soft paper
/// budget instead of failing, a wide element widens only the pages that hold it,
/// landscape paper yields landscape-shaped pages, and a completed panel run persists
/// its paper choices for the next Print… while a cancelled one does not. These tests
/// drive the `printOperationRunner` seam, never the real CUPS path.
@MainActor
final class ExportPrintPaginationAppTests: XCTestCase {
    /// A 400×1600 px image renders ~1,200 pt tall — past a Letter portrait imageable
    /// budget (~1,120 pt for the ~868 pt baseline width) — so its page must soft-extend.
    func testTallImageExtendsItsPrintPageWithoutFailing() async throws {
        try await assertTallPrint(
            label: "400x1600 image",
            text: "# Tall image\n\nIMGALPHASENTINEL paragraph.\n\n![tall](assets/tall-400x1600.png)"
                + "\n\nIMGOMEGASENTINEL paragraph.\n",
            imageName: "tall-400x1600.png",
            imageSize: NSSize(width: 400, height: 1600),
            sentinels: ["IMGALPHASENTINEL", "IMGOMEGASENTINEL"]
        )
    }

    /// A phone-screenshot proportioned image (~1,584 pt rendered) is the owner's tall
    /// Print case: it must print once, not fail as oversize.
    func testPhoneScreenshotPrintsOnceWithoutFailing() async throws {
        try await assertTallPrint(
            label: "phone screenshot",
            text: "# Screenshot\n\nSHOTALPHASENTINEL paragraph.\n\n![shot](assets/phone-shot.png)"
                + "\n\nSHOTOMEGASENTINEL paragraph.\n",
            imageName: "phone-shot.png",
            imageSize: NSSize(width: 380, height: 2112),
            sentinels: ["SHOTALPHASENTINEL", "SHOTOMEGASENTINEL"]
        )
    }

    /// A 30-node vertical flowchart renders an atomic SVG taller than the paper budget:
    /// every node label must appear exactly once in the captured print PDF.
    func testTallMermaidFlowchartPrintsEveryNodeOnce() async throws {
        let nodes = (0 ..< 30).map {
            "N\($0)[TALLNODE\($0)SENTINEL]"
        }.joined(separator: " --> ")
        let sentinels = (0 ..< 30).map { "TALLNODE\($0)SENTINEL" }
        try await assertTallPrint(
            label: "flowchart TD",
            text: "# Flow\n\n```mermaid\nflowchart TD\n  \(nodes)\n```\n",
            imageName: nil,
            imageSize: .zero,
            sentinels: sentinels
        )
    }

    /// The shared tall-content body: Print succeeds, the notice stays silent, every
    /// sentinel survives once, and at least one captured page is taller than its own
    /// soft aspect budget — the extension is the only way that can happen.
    private func assertTallPrint(
        label: String,
        text: String,
        imageName: String?,
        imageSize: NSSize,
        sentinels: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let support = ExportHTMLCommandAppTests()
        let fixture = try support.makeFixture(text: text)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        if let imageName {
            try ExportPDFWideRunsAppSupport.pngData(size: imageSize)
                .write(to: fixture.root.appendingPathComponent("assets/\(imageName)"))
        }
        let printInfo = Self.portraitPrintInfo()
        fixture.appState.exportHTMLOperations.printInfoProvider = { printInfo }
        var observed: PDFDocument?
        fixture.appState.exportHTMLOperations.printDocumentObserver = { observed = $0 }
        fixture.appState.exportHTMLOperations.printOperationRunner = { _, _ in true }
        var results: [ExportHTMLOperationResult] = []
        fixture.appState.exportHTMLOperations.didFinishOperation = { _, result in
            results.append(result)
        }
        fixture.appState.exportHTMLOperations.destinationChooser = { _ in
            XCTFail("Print must not open a save panel", file: file, line: line)
            return nil
        }
        try await XCTUnwrap(fixture.appState.printCurrentDocument(), label).value
        XCTAssertEqual(results, [.printed], label, file: file, line: line)
        XCTAssertNil(fixture.appState.exportHTMLNotice, label, file: file, line: line)
        let document = try XCTUnwrap(observed, "\(label): printDocumentObserver saw nothing")
        let text = (0 ..< document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
        for sentinel in sentinels {
            XCTAssertEqual(
                text.components(separatedBy: sentinel).count - 1,
                1, "\(label): \(sentinel)", file: file, line: line
            )
        }
        // The atomic box must sit on one captured page: that page is taller than the
        // paper's imageable height, which a soft-extended page legally is (the print
        // operation's pageScaleToFit shrinks it onto the sheet).
        let imageableHeight = printInfo.imageablePageBounds.height
        let exceeded = (0 ..< document.pageCount).contains { index in
            guard let box = document.page(at: index)?.bounds(for: .mediaBox) else { return false }
            return box.height > imageableHeight + 5
        }
        XCTAssertTrue(
            exceeded,
            "\(label): a tall atomic box must sit on one page taller than the imageable height",
            file: file, line: line
        )
    }

    /// A wide table in the middle widens only the pages that intersect it; text-only
    /// pages keep the baseline width, and nothing exceeds 14,400 pt so no page scales.
    func testWideTableWidensOnlyItsPrintPages() async throws {
        let support = ExportHTMLCommandAppTests()
        let columns = (0 ..< 60).map { String(format: "WIDEPAGECOLUMN%02dSENTINEL", $0) }
        let table = Self.tableSource(columns, cell: "x")
        let before = (0 ..< 30).map { "NARRROWBEFORESENTINEL paragraph \($0) of prose." }
            .joined(separator: "\n\n")
        let after = (0 ..< 30).map { "NARRROWAFTERSENTINEL paragraph \($0) of prose." }
            .joined(separator: "\n\n")
        let fixture = try support.makeFixture(text: "\(before)\n\n\(table)\n\n\(after)\n")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.appState.exportHTMLOperations.printInfoProvider = { Self.portraitPrintInfo() }
        var observed: PDFDocument?
        fixture.appState.exportHTMLOperations.printDocumentObserver = { observed = $0 }
        fixture.appState.exportHTMLOperations.printOperationRunner = { _, _ in true }
        try await XCTUnwrap(fixture.appState.printCurrentDocument()).value
        let document = try XCTUnwrap(observed)
        var baselinePages = 0
        var widePages = 0
        for index in 0 ..< document.pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            let box = page.bounds(for: .mediaBox)
            XCTAssertLessThanOrEqual(box.width, 14400.5)
            if page.string?.contains("WIDEPAGECOLUMN") == true {
                widePages += 1
                XCTAssertGreaterThan(box.width, 1100, "A table page must be wider than baseline")
            } else {
                baselinePages += 1
                XCTAssertLessThan(box.width, 1100, "A text page must keep the baseline width")
            }
        }
        XCTAssertGreaterThan(widePages, 0)
        XCTAssertGreaterThan(baselinePages, 0)
        let text = (0 ..< document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
        XCTAssertEqual(text.components(separatedBy: "WIDEPAGECOLUMN59SENTINEL").count - 1, 1)
    }

    /// Landscape paper (orientation-aware imageable bounds) makes every page wider
    /// than tall.
    func testLandscapePrintInfoProducesLandscapeShapedPages() async throws {
        let support = ExportHTMLCommandAppTests()
        let prose = (0 ..< 40).map { "LANDSCAPESENTINEL paragraph \($0) fills the page." }
            .joined(separator: "\n\n")
        let fixture = try support.makeFixture(text: prose)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.orientation = .landscape
        fixture.appState.exportHTMLOperations.printInfoProvider = { info }
        var observed: PDFDocument?
        fixture.appState.exportHTMLOperations.printDocumentObserver = { observed = $0 }
        fixture.appState.exportHTMLOperations.printOperationRunner = { _, _ in true }
        var results: [ExportHTMLOperationResult] = []
        fixture.appState.exportHTMLOperations.didFinishOperation = { _, result in
            results.append(result)
        }
        try await XCTUnwrap(fixture.appState.printCurrentDocument()).value
        XCTAssertEqual(results, [.printed])
        let document = try XCTUnwrap(observed)
        XCTAssertGreaterThan(document.pageCount, 0)
        for index in 0 ..< document.pageCount {
            let box = try XCTUnwrap(document.page(at: index)?.bounds(for: .mediaBox))
            XCTAssertLessThanOrEqual(
                box.height, box.width + 0.5,
                "Landscape page \(index) must be wider than tall: \(box)"
            )
        }
    }

    /// A completed panel run persists paper size and orientation for the next Print…;
    /// a cancelled run must not overwrite them.
    func testPrintPanelChoicesPersistOnlyWhenTheRunCompletes() async throws {
        let support = ExportHTMLCommandAppTests()
        let prose = (0 ..< 40).map { "PERSISTSENTINEL paragraph \($0) fills the page." }
            .joined(separator: "\n\n")
        let fixture = try support.makeFixture(text: prose)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var results: [ExportHTMLOperationResult] = []
        fixture.appState.exportHTMLOperations.didFinishOperation = { _, result in
            results.append(result)
        }
        var observed: PDFDocument?
        fixture.appState.exportHTMLOperations.printDocumentObserver = { observed = $0 }

        // A cancelled run persists nothing.
        fixture.appState.exportHTMLOperations.printOperationRunner = { operation, _ in
            operation.printInfo.orientation = .landscape
            return false
        }
        try await XCTUnwrap(fixture.appState.printCurrentDocument()).value
        XCTAssertEqual(results.last, .stopped(.cancelled))
        XCTAssertNil(fixture.appState.exportHTMLOperations.lastPrintInfo)

        // A completed run persists the panel's orientation.
        fixture.appState.exportHTMLOperations.printOperationRunner = { operation, _ in
            operation.printInfo.orientation = .landscape
            return true
        }
        try await XCTUnwrap(fixture.appState.printCurrentDocument()).value
        XCTAssertEqual(results.last, .printed)
        XCTAssertEqual(
            fixture.appState.exportHTMLOperations.lastPrintInfo?.orientation, .landscape
        )

        // The next Print with no provider observes the persisted landscape info and
        // plans landscape-shaped pages.
        var observedOrientation: NSPrintInfo.PaperOrientation?
        fixture.appState.exportHTMLOperations.printOperationRunner = { operation, _ in
            observedOrientation = operation.printInfo.orientation
            return true
        }
        try await XCTUnwrap(fixture.appState.printCurrentDocument()).value
        XCTAssertEqual(results.last, .printed)
        XCTAssertEqual(observedOrientation, .landscape)
        let document = try XCTUnwrap(observed)
        for index in 0 ..< document.pageCount {
            let box = try XCTUnwrap(document.page(at: index)?.bounds(for: .mediaBox))
            XCTAssertLessThanOrEqual(
                box.height, box.width + 0.5,
                "Persisted-landscape page \(index) must be wider than tall: \(box)"
            )
        }
    }

    /// M2: a completed run persists only the page setup — paper name and size,
    /// orientation, printer. The panel's page range, copies, scaling and save
    /// disposition must come back from a fresh shared copy on the next Print….
    func testPrintJobSettingsDoNotPersistBeyondPageSetup() async throws {
        let support = ExportHTMLCommandAppTests()
        let prose = (0 ..< 10).map { "JOBSETTINGSENTINEL paragraph \($0)." }
            .joined(separator: "\n\n")
        let fixture = try support.makeFixture(text: prose)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var chosenSize = NSSize.zero
        var chosenPaperName: NSPrinter.PaperName?
        fixture.appState.exportHTMLOperations.printOperationRunner = { operation, _ in
            // Simulate the panel's choices: a page range, copies, scaling and a save
            // disposition, plus a landscape orientation on a custom paper size.
            let info = operation.printInfo
            info.dictionary()[NSPrintInfo.AttributeKey.jobDisposition] =
                NSPrintInfo.JobDisposition.save.rawValue
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] =
                URL(fileURLWithPath: "/tmp/panel-choice.pdf")
            info.dictionary()[NSPrintInfo.AttributeKey.copies] = 3
            info.dictionary()[NSPrintInfo.AttributeKey.firstPage] = 2
            info.dictionary()[NSPrintInfo.AttributeKey.lastPage] = 3
            info.dictionary()[NSPrintInfo.AttributeKey.scalingFactor] = 0.5
            info.orientation = .landscape
            info.paperSize = NSSize(width: 612, height: 1008)
            chosenSize = info.paperSize
            chosenPaperName = info.paperName
            return true
        }
        var results: [ExportHTMLOperationResult] = []
        fixture.appState.exportHTMLOperations.didFinishOperation = { _, result in
            results.append(result)
        }
        try await XCTUnwrap(fixture.appState.printCurrentDocument()).value
        XCTAssertEqual(results.last, .printed)
        let persisted = try XCTUnwrap(fixture.appState.exportHTMLOperations.lastPrintInfo)
        XCTAssertEqual(persisted.orientation, .landscape)
        XCTAssertEqual(persisted.paperName, chosenPaperName)
        // paperSize is reported as the completed operation reported it (landscape
        // swaps the axes); what matters is the persisted copy matches that value.
        XCTAssertEqual(persisted.paperSize, chosenSize)
        // Everything else matches a fresh shared copy — the job fields must not leak.
        let fresh = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        for key: NSPrintInfo.AttributeKey in
            [.jobDisposition, .jobSavingURL, .copies, .firstPage, .lastPage, .scalingFactor]
        {
            let persistedValue = persisted.dictionary()[key] as? NSObject
            let freshValue = fresh.dictionary()[key] as? NSObject
            XCTAssertEqual(persistedValue, freshValue, "\(key) leaked from the panel")
        }
    }

    private static func portraitPrintInfo() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.orientation = .portrait
        return info
    }

    private static func tableSource(_ columns: [String], cell: String) -> String {
        let delimiter = [String](repeating: "---", count: columns.count)
        let body = [String](repeating: cell, count: columns.count)
        return [columns, delimiter, body].map(tableRow).joined()
    }

    private static func tableRow(_ cells: [String]) -> String {
        "| " + cells.joined(separator: " | ") + " |\n"
    }
}
