import Foundation
import MarkdownCore
@testable import PreviewKit
import XCTest

/// Paired A/B diagnostics for `docs/perf/2026-10-22-preview-render-single-flight.md`.
/// Opt-in: `PLAINSONG_RUN_PREVIEW_DISPATCH_PROBE=1 swift test --filter PreviewRenderDispatchProbeTests`.
/// The probe uses only API that predates single-flight, so the same file runs on the base tree.
@MainActor
final class PreviewRenderDispatchProbeTests: XCTestCase {
    /// Typing into a 500 KB document with the 150 ms debounce delivering a render every
    /// 150 ms: how long the last keystroke's text takes to appear, and how many pipeline
    /// runs JavaScript performed for twelve submissions.
    func testTypingBurstProbe() async throws {
        try requireOptIn()
        let source = try fixture("perf-500kb.md")
        let controller = try await readyController()
        defer { controller.shutdownForTesting() }
        _ = try await settle(controller, controller.renderForTesting(change(source, version: 1)))
        _ = try await PreviewHostedTestWait.javascript(Self.countRenderMessagesScript, in: controller.webView)

        var lastRenderID = -1
        var lastSubmission = DispatchTime.now().uptimeNanoseconds
        for keystroke in 1 ... 12 {
            lastSubmission = DispatchTime.now().uptimeNanoseconds
            lastRenderID = controller.renderForTesting(change(source + "\nTyped \(keystroke)", version: keystroke + 1))
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        try await settle(controller, lastRenderID)
        let latency = DispatchTime.now().uptimeNanoseconds - lastSubmission
        let runs = try await PreviewHostedTestWait.javascript("window.__renderMessages", in: controller.webView)
        print(String(
            format: "PREVIEW_DISPATCH_PROBE typing_burst last_text_visible_ms=%.1f pipeline_runs=%d",
            Double(latency) / 1_000_000,
            (runs as? Int) ?? -1
        ))
    }

    /// Main-thread time of one idle render submission of the 1 MiB fixture (nothing in
    /// flight, so both trees send at once), median of nine.
    func testIdleSubmissionMainThreadProbe() async throws {
        try requireOptIn()
        let source = try fixture("large-1mb.md")
        let controller = try await readyController()
        defer { controller.shutdownForTesting() }
        _ = try await settle(controller, controller.renderForTesting(change(source, version: 1)))

        var samples: [Double] = []
        for version in 2 ... 10 {
            let text = source + "\nEdit \(version)"
            let start = DispatchTime.now().uptimeNanoseconds
            let renderID = controller.renderForTesting(change(text, version: version))
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            try await settle(controller, renderID)
        }
        samples.sort()
        print(String(format: "PREVIEW_DISPATCH_PROBE idle_submit_1mb_median_ms=%.2f", samples[samples.count / 2]))
    }

    private func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment["PLAINSONG_RUN_PREVIEW_DISPATCH_PROBE"] == "1" else {
            throw XCTSkip("Paired preview dispatch diagnostics are opt-in: PLAINSONG_RUN_PREVIEW_DISPATCH_PROBE=1")
        }
    }

    private func readyController() async throws -> PreviewController {
        let controller = try PreviewController(previewIndexURL: PreviewBundleFixture.indexURL())
        controller.exportTimeoutNanoseconds = 120_000_000_000
        try await PreviewHostedTestWait.until("bundle ready", timeoutNanoseconds: 30_000_000_000) {
            controller.isReady
        }
        return controller
    }

    @discardableResult
    private func settle(_ controller: PreviewController, _ renderID: Int) async throws -> Int {
        try await PreviewHostedTestWait.until("render \(renderID) completes", timeoutNanoseconds: 120_000_000_000) {
            controller.scrollDeliveryState.completedRenderID == renderID
        }
        return renderID
    }

    private func change(_ text: String, version: Int) -> DocumentTextChange {
        DocumentTextChange(text: text, version: version, fileKind: .markdown, fileURL: nil)
    }

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static let countRenderMessagesScript = """
    (() => {
      const original = window.PlainsongBridge.receive;
      window.__renderMessages = 0;
      window.PlainsongBridge.receive = function (message) {
        if (message.name === "render") window.__renderMessages += 1;
        return original.call(this, message);
      };
      return true;
    })()
    """
}
