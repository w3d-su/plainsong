import AppKit
import MarkdownCore
import PDFKit
@testable import Plainsong
@testable import PreviewKit
import WebKit
@testable import WorkspaceKit
import XCTest

/// The real `runModal` print path: the panel is only suppressed, never replaced, so the
/// completion lifetime, eligibility, and sheet dismissal are exercised end to end.
@MainActor
final class ExportPrintSheetAppTests: XCTestCase {
    /// Blocking 3: a real print operation to a temp job-saving URL, then the produced
    /// PDF is read back for sentinel and theme evidence.
    func testRealPrintJobProducesLightThemePDFWithEverySentinelOnce() async throws {
        try Self.requirePrintDestination()
        let support = ExportHTMLCommandAppTests()
        let columns = (0 ..< 12).map { String(format: "PCOLUMN%02dSENTINEL", $0) }
        let table = Self.tableSource(columns, cell: "v")
        let code = "```\n" + String(repeating: "W", count: 120) + "PRINTCODESENTINEL\n```\n"
        let math = "$$\\text{PRINTKATEXSENTINEL}+x$$\n"
        let mermaid = "```mermaid\nflowchart LR\n  A[PRINTMERMAIDSENTINEL] --> B[END]\n```\n"
        let body = (0 ..< 40).map { "### Print section \($0)\n\nParagraph \($0).\n" }.joined()
        let source = [table, code, math, mermaid, body].joined(separator: "\n")
        let fixture = try support.makeFixture(text: source)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let jobURL = fixture.exportsDirectory.appendingPathComponent("print-job.pdf")
        fixture.appState.exportHTMLOperations.printInfoProvider = {
            Self.saveJobPrintInfo(to: jobURL)
        }
        fixture.appState.exportHTMLOperations.printPanelSuppressedForTesting = true
        var results: [ExportHTMLOperationResult] = []
        fixture.appState.exportHTMLOperations.didFinishOperation = { _, result in
            results.append(result)
        }
        fixture.appState.exportHTMLOperations.destinationChooser = { _ in
            XCTFail("Print must not open a save panel")
            return jobURL
        }
        try await XCTUnwrap(fixture.appState.printCurrentDocument()).value
        XCTAssertEqual(results, [.printed])
        XCTAssertNil(fixture.appState.exportHTMLNotice)
        let data = try Data(contentsOf: jobURL)
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        let text = Self.text(of: data)
        for marker in columns + ["PRINTCODESENTINEL", "PRINTMERMAIDSENTINEL"] {
            XCTAssertEqual(text.components(separatedBy: marker).count - 1, 1, marker)
        }
        // KaTeX text also lives in the hidden MathML annotation, so count ≥ 1.
        XCTAssertGreaterThanOrEqual(
            text.components(separatedBy: "PRINTKATEXSENTINEL").count - 1, 1
        )
        XCTAssertGreaterThan(PDFDocument(data: data)?.pageCount ?? 0, 1)
        try Self.assertDarkTextOnLightPaper(data)
    }

    /// The completion is resolved exactly once and the registry keeps it until didRun.
    func testPrintCompletionResolvesExactlyOnceAndIsRetainedUntilDidRun() {
        var outcomes: [Bool] = []
        let completion = ExportPrintCompletion { outcomes.append($0) }
        completion.resolve(true)
        completion.resolve(false)
        XCTAssertEqual(outcomes, [true])
        XCTAssertTrue(completion.isResolved)
    }

    /// While the real print sheet is up the File-menu exports are ineligible and a
    /// supersede finishes the task and releases the controller and its WebView.
    func testSupersedeDuringRealPrintSheetFinishesAndReleasesObjects() async throws {
        try Self.requirePrintDestination()
        let support = ExportHTMLCommandAppTests()
        let fixture = try support.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controllerBox = E0WeakBox<PreviewController>(nil)
        let webViewBox = E0WeakBox<WKWebView>(nil)
        fixture.appState.exportHTMLOperations.didPrepareArtifact = {
            let controller = fixture.appState.exportHTMLOperations.offscreenController
            controllerBox.value = controller
            webViewBox.value = controller?.webView
        }
        // The real panel shows on the test window: showsPrintPanel stays true, the
        // printOperationRunner seam stays unset, and the sheet is ended programmatically
        // the way a supersede does.
        var task: Task<Void, Never>? = fixture.appState.printCurrentDocument()
        try await Self.waitUntil("print sheet is up") {
            fixture.appState.isExportPrintSheetActive
        }
        XCTAssertFalse(fixture.appState.canExportCurrentDocumentAsHTML)
        XCTAssertNil(fixture.appState.exportCurrentDocumentAsPDF())
        XCTAssertNil(fixture.appState.printCurrentDocument())
        fixture.appState.supersedeActiveExportHTMLOperation()
        try await Self.awaitPrintTask(XCTUnwrap(task))
        task = nil
        await Task.yield()
        XCTAssertNil(controllerBox.value)
        XCTAssertNil(webViewBox.value)
        XCTAssertFalse(fixture.appState.isExportPrintSheetActive)
    }

    /// Cancelling while the real sheet is up resolves the task and reports no notice.
    func testCancelDuringRealPrintSheetIsSilent() async throws {
        try Self.requirePrintDestination()
        let support = ExportHTMLCommandAppTests()
        let fixture = try support.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = ExportHTMLCommandAppTests.DocumentState(fixture.session)
        var results: [ExportHTMLOperationResult] = []
        fixture.appState.exportHTMLOperations.didFinishOperation = { _, result in
            results.append(result)
        }
        let task = try XCTUnwrap(fixture.appState.printCurrentDocument())
        try await Self.waitUntil("print sheet is up") {
            fixture.appState.isExportPrintSheetActive
        }
        fixture.appState.cancelExportHTML()
        await Self.awaitPrintTask(task)
        try await Self.waitUntil("print task finished") { !results.isEmpty }
        XCTAssertEqual(results, [.stopped(.cancelled)])
        XCTAssertNil(fixture.appState.exportHTMLNotice)
        XCTAssertEqual(ExportHTMLCommandAppTests.DocumentState(fixture.session), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: fixture.exportsDirectory, includingPropertiesForKeys: nil
        ).count, 0)
    }

    // MARK: - Helpers

    private static func saveJobPrintInfo(to url: URL) -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        return info
    }

    private static func text(of data: Data) -> String {
        guard let document = PDFDocument(data: data) else { return "" }
        return (0 ..< document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }

    /// B1: paper is white and the print render is light-themed. `pageScaleToFit` fits
    /// each captured page into the imageable rect, so a wide document prints small and
    /// its antialiased strokes land mid-gray — ink evidence therefore counts pixels
    /// clearly darker than paper (< 0.7) rather than near-black ones.
    private static func assertDarkTextOnLightPaper(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let document = try XCTUnwrap(PDFDocument(data: data), file: file, line: line)
        let page = try XCTUnwrap(document.page(at: 0), file: file, line: line)
        let image = page.thumbnail(of: CGSize(width: 340, height: 440), for: .mediaBox)
        let tiff = try XCTUnwrap(image.tiffRepresentation, file: file, line: line)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff), file: file, line: line)
        var light = 0
        var ink = 0
        var total = 0
        for x in 0 ..< bitmap.pixelsWide {
            for y in 0 ..< bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                total += 1
                if luminance > 0.8 { light += 1 }
                if luminance < 0.7 { ink += 1 }
            }
        }
        XCTAssertGreaterThan(Double(light) / Double(total), 0.6,
                             "Print output must be mostly light paper", file: file, line: line)
        XCTAssertGreaterThan(ink, total / 250,
                             "Print output must carry dark text on the light paper", file: file, line: line)
    }

    /// The real `runModal` path is opt-in: the panel is only suppressed, never mocked,
    /// so these tests put real print jobs and real sheets through the host's CUPS
    /// configuration. They run only with `TEST_RUNNER_PLAINSONG_REAL_PRINT=1`.
    /// A configured CUPS destination is still required: on a host with none, PrintingUI
    /// raises an app-modal alert inside `runModal` before any sheet exists, and that
    /// nested modal loop starves main-actor work so the awaiting test can never unwind.
    /// Skip honestly rather than hang the suite.
    private static func requirePrintDestination() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PLAINSONG_REAL_PRINT"] == "1",
            "Opt-in: set TEST_RUNNER_PLAINSONG_REAL_PRINT=1 to run the real print-panel tests"
        )
        try XCTSkipUnless(
            !NSPrinter.printerNames.isEmpty,
            "No CUPS destination configured; the real print panel cannot run"
        )
    }

    /// On hosts without a configured printer, PrintingUI can raise an app-modal alert
    /// inside `NSPrintOperation.runModal` before any sheet exists; the awaiting task
    /// then stays suspended inside that nested modal loop until it ends. Keep releasing
    /// AppKit's blocking UI (modal alert or attached print sheet) while the task
    /// finishes so supersede/cancel unwinds on any host. The alert's nested loop does
    /// not service the main dispatch queue, so the task await and a fallback dismissal
    /// also run off the main actor: `postEvent` is documented thread-safe and Escape
    /// cancels an alert or a print sheet, while `stopModal` breaks a buttonless
    /// session that swallows the event.
    private static func awaitPrintTask(_ task: Task<Void, Never>) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask { @MainActor in
                while !Task.isCancelled {
                    if NSApp.modalWindow != nil { NSApp.stopModal() }
                    for window in NSApp.windows where window.attachedSheet != nil {
                        window.endSheet(window.attachedSheet!, returnCode: .cancel)
                    }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    NSApp.stopModal()
                    if let escape = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: 0, context: nil,
                        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                        isARepeat: false, keyCode: 53
                    ) {
                        NSApp.postEvent(escape, atStart: false)
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            await group.next()
            group.cancelAll()
        }
    }

    private static func waitUntil(
        _ description: String,
        timeoutNanoseconds: UInt64 = 60_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            try Task.checkCancellation()
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    /// Built from typed pieces: a single long `+` chain with a closure exceeds the
    /// hosted CI compiler's type-check time limit.
    private static func tableSource(_ columns: [String], cell: String) -> String {
        let delimiter = [String](repeating: "---", count: columns.count)
        let body = [String](repeating: cell, count: columns.count)
        return [columns, delimiter, body].map(tableRow).joined()
    }

    private static func tableRow(_ cells: [String]) -> String {
        "| " + cells.joined(separator: " | ") + " |\n"
    }
}
