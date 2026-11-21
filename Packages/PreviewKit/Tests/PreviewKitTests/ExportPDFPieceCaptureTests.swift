import MarkdownCore
@testable import PreviewKit
import WebKit
import XCTest

/// One page capture is one WebKit call with no timeout of its own. The wait ends on the
/// first of WebKit's answer, the timeout, cancellation, invalidation, or a renderer death.
@MainActor
final class ExportPDFPieceCaptureTests: XCTestCase {
    private typealias Completion = @MainActor (Result<Data, Error>) -> Void
    private var controller: PreviewController!
    private var completions: [Completion] = []

    override func setUp() async throws {
        controller = PreviewController(previewIndexURL: nil)
        completions = []
        controller.pdfPieceCapture.capturer = { [unowned self] _, completion in
            completions.append(completion)
        }
    }

    override func tearDown() async throws {
        controller.invalidate()
        controller = nil
    }

    func testWebKitAnswerResolvesTheCapture() async throws {
        let task = startCapture()
        await waitForCapture()

        completions[0](.success(Data([1, 2, 3])))

        let piece = try await task.value
        XCTAssertEqual(piece, Data([1, 2, 3]))
    }

    func testSilentRendererTimesOut() async {
        controller.pdfPieceCapture.timeoutNanoseconds = 50_000_000
        let task = startCapture()

        await assertFailure(of: task) {
            XCTAssertEqual($0 as? ExportPDFCaptureError, .captureFailed("timeout"))
        }
        // A late WebKit answer after the timeout is ignored.
        completions.first?(.success(Data()))
    }

    func testCancellationWakesTheCapture() async {
        let task = startCapture()
        await waitForCapture()

        task.cancel()

        await assertFailure(of: task) { XCTAssertTrue($0 is CancellationError) }
    }

    func testInvalidationWakesTheCapture() async {
        let task = startCapture()
        await waitForCapture()

        controller.invalidate()

        await assertFailure(of: task) { _ in }
        XCTAssertThrowsError(try controller.checkExportAlive()) {
            XCTAssertEqual($0 as? ExportPDFCaptureError, .invalidated)
        }
    }

    func testWebContentTerminationWakesTheCapture() async {
        let task = startCapture()
        await waitForCapture()

        controller.webViewWebContentProcessDidTerminate(controller.webView)

        await assertFailure(of: task) { _ in }
        XCTAssertThrowsError(try controller.checkExportAlive()) {
            XCTAssertEqual($0 as? ExportPDFCaptureError, .webContentProcessTerminated)
        }
    }

    func testExportRenderRefusesADeadRendererWithoutWaitingForTheTimeout() async {
        controller.webViewWebContentProcessDidTerminate(controller.webView)
        let change = DocumentTextChange(text: "# Dead\n", version: 1, fileKind: .markdown, fileURL: nil)

        let result = await controller.renderForExport(change)

        XCTAssertEqual(result, .failed(reason: "web-content-process-terminated", renderID: -1))
        XCTAssertNil(controller.pendingExportRender)
    }

    private func startCapture() -> Task<Data, Error> {
        let controller = controller!
        return Task { try await controller.captureExportPDFPiece(WKPDFConfiguration()) }
    }

    private func waitForCapture() async {
        for _ in 0 ..< 200 where completions.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(completions.isEmpty, "capture started")
    }

    private func assertFailure(of task: Task<Data, Error>, _ check: (Error) -> Void) async {
        do {
            _ = try await task.value
            XCTFail("the capture must fail")
        } catch {
            check(error)
        }
    }
}
