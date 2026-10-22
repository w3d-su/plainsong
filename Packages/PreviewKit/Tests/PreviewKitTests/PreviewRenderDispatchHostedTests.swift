import Foundation
import MarkdownCore
@testable import PreviewKit
import XCTest

/// Single-flight render dispatch against real WebKit pages.
@MainActor
final class PreviewRenderDispatchHostedTests: XCTestCase {
    /// `callAsyncJavaScript` hands JavaScript the same message `JSONEncoder` produced
    /// before: same keys, same values, JavaScript Booleans and numbers.
    func testRenderArrivesAsTheCodableMessage() async throws {
        let directory = try makeDirectory()
        let indexURL = directory.appendingPathComponent("index.html")
        try Data(Self.recordingBridgeHTML.utf8).write(to: indexURL)
        let controller = PreviewController(previewIndexURL: indexURL)
        defer { controller.shutdownForTesting() }
        try await wait("recording bridge ready") { controller.isReady }

        let text = "# Title \"quoted\" \\ back`tick` </script> \u{2028}\u{2029} \u{0} 🎉 漢字\n"
        controller.setWorkspaceAssetRoot(directory)
        controller.setTheme("dark")
        let withBaseDir = controller.renderForTesting(DocumentTextChange(
            text: text,
            version: 7,
            fileKind: .mdx,
            fileURL: directory.appendingPathComponent("content/post.mdx")
        ))
        try await wait("render recorded") { try await self.recordedCount(controller) == 1 }
        let withoutBaseDir = controller.renderForTesting(DocumentTextChange(
            text: "plain",
            version: 8,
            fileKind: .markdown,
            fileURL: nil
        ))
        try await wait("second render recorded") { try await self.recordedCount(controller) == 2 }

        let first = try await recorded(controller, at: 0)
        XCTAssertEqual(first.message, .render(RenderPayload(
            renderID: withBaseDir,
            version: 7,
            fileKind: .mdx,
            text: text,
            baseDir: "content",
            theme: "dark",
            allowRemoteImages: false,
            assetRootID: first.assetRootID
        )))
        XCTAssertFalse(first.assetRootID.isEmpty)
        XCTAssertEqual(first.types, [
            "allowRemoteImages": "boolean", "assetRootID": "string", "baseDir": "string",
            "fileKind": "string", "renderID": "number", "text": "string", "theme": "string",
            "version": "number",
        ])

        let second = try await recorded(controller, at: 1)
        XCTAssertEqual(second.message.name, .render)
        if case let .render(payload) = second.message {
            XCTAssertEqual(payload.renderID, withoutBaseDir)
            XCTAssertNil(payload.baseDir)
        }
        XCTAssertNil(second.types["baseDir"], "A nil baseDir stays absent, as JSONEncoder omits it")
    }

    /// A burst submitted while a render is in flight runs the pipeline twice: the in-flight
    /// render and the newest one. Every queued `evaluateJavaScript` render used to run it.
    func testRenderBurstRunsThePipelineForTheInFlightAndNewestRenderOnly() async throws {
        let controller = try PreviewController(previewIndexURL: PreviewBundleFixture.indexURL())
        defer { controller.shutdownForTesting() }
        controller.renderWatchdogNanoseconds = 60_000_000_000
        try await wait("bundle ready") { controller.isReady }
        _ = try await PreviewHostedTestWait.javascript(Self.countRenderMessagesScript, in: controller.webView)

        var newest = -1
        for index in 1 ... 10 {
            newest = controller.renderForTesting(DocumentTextChange(
                text: Self.document(marker: "BURST_\(index)"),
                version: index,
                fileKind: .markdown,
                fileURL: nil
            ))
        }
        try await wait("newest render completes") {
            controller.scrollDeliveryState.completedRenderID == newest
        }
        let renderMessages = try await PreviewHostedTestWait.javascript(
            "window.__renderMessages",
            in: controller.webView
        ) as? Int
        XCTAssertEqual(renderMessages, 2)
        let text = try await PreviewHostedTestWait.javascript("document.body.innerText", in: controller.webView)
        XCTAssertTrue((text as? String)?.contains("BURST_10") == true)
    }

    /// A render JavaScript never answers (the md pipeline rethrows without
    /// `renderComplete`) must not wedge the preview: the watchdog sends the newest text.
    func testWatchdogRecoversFromARenderThatNeverCompletes() async throws {
        let controller = try PreviewController(previewIndexURL: PreviewBundleFixture.indexURL())
        defer { controller.shutdownForTesting() }
        try await wait("bundle ready") { controller.isReady }
        _ = try await PreviewHostedTestWait.javascript(Self.swallowRenderScript, in: controller.webView)

        controller.renderWatchdogNanoseconds = 200_000_000
        _ = controller.renderForTesting(DocumentTextChange(
            text: "SWALLOWED",
            version: 1,
            fileKind: .markdown,
            fileURL: nil
        ))
        let recovered = controller.renderForTesting(DocumentTextChange(
            text: "# Recovered after the watchdog",
            version: 2,
            fileKind: .markdown,
            fileURL: nil
        ))
        try await wait("watchdog delivers the newest render") {
            controller.scrollDeliveryState.completedRenderID == recovered
        }
        let text = try await PreviewHostedTestWait.javascript("document.body.innerText", in: controller.webView)
        XCTAssertTrue((text as? String)?.contains("Recovered after the watchdog") == true)
    }

    // MARK: Support

    private struct RecordedMessage {
        let message: BridgeMessage
        let types: [String: String]
        let assetRootID: String
    }

    private func recordedCount(_ controller: PreviewController) async throws -> Int {
        try await PreviewHostedTestWait.javascript("window.__received.length", in: controller.webView) as? Int ?? 0
    }

    private func recorded(_ controller: PreviewController, at index: Int) async throws -> RecordedMessage {
        let rawJSON = try await PreviewHostedTestWait.javascript(
            "window.__received[\(index)].json",
            in: controller.webView
        )
        let rawTypes = try await PreviewHostedTestWait.javascript(
            "window.__received[\(index)].types",
            in: controller.webView
        )
        let json = try XCTUnwrap(rawJSON as? String)
        let types = try XCTUnwrap(rawTypes as? [String: String])
        let message = try JSONDecoder().decode(BridgeMessage.self, from: Data(json.utf8))
        guard case let .render(payload) = message else {
            throw XCTSkip("Recorded message \(index) is not a render")
        }
        return RecordedMessage(message: message, types: types, assetRootID: payload.assetRootID)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewRenderDispatchHostedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("content", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.standardizedFileURL
    }

    private func wait(
        _ description: String,
        condition: @escaping @MainActor () async throws -> Bool
    ) async throws {
        try await PreviewHostedTestWait.until(description, timeoutNanoseconds: 15_000_000_000, condition: condition)
    }

    private static func document(marker: String) -> String {
        var lines = ["# \(marker)", ""]
        for index in 1 ... 400 {
            lines.append("Paragraph \(index) with **bold**, `code`, and a [link](https://example.com/\(index)).")
            lines.append("")
        }
        return lines.joined(separator: "\n")
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

    private static let swallowRenderScript = """
    (() => {
      const original = window.PlainsongBridge.receive;
      window.PlainsongBridge.receive = function (message) {
        if (message.name === "render" && message.payload.text === "SWALLOWED") return;
        return original.call(this, message);
      };
      return true;
    })()
    """

    private static let recordingBridgeHTML = """
    <!doctype html><meta charset="utf-8"><body></body>
    <script>
    window.PlainsongPreview = { PROTOCOL_VERSION: \(PreviewBridge.protocolVersion) };
    window.__received = [];
    window.PlainsongBridge = {
      receive(message) {
        if (message.name !== "render") return;
        const types = {};
        for (const key of Object.keys(message.payload)) types[key] = typeof message.payload[key];
        window.__received.push({ json: JSON.stringify(message), types });
        window.webkit.messageHandlers.bridge.postMessage({
          name: "renderComplete",
          payload: { renderID: message.payload.renderID, version: message.payload.version, blockCount: 1 }
        });
      }
    };
    </script>
    """
}
