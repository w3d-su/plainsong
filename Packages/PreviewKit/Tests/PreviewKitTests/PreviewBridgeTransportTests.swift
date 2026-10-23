import Foundation
import MarkdownCore
@testable import PreviewKit
import XCTest

@MainActor
final class PreviewBridgeTransportTests: XCTestCase {
    // MARK: Viewport scroll traffic

    func testViewportScrollsKeepOneInFlightAndTheNewestWaiting() {
        let harness = RenderDispatchHarness(testCase: self)
        harness.markReady()

        for line in 1 ... 5 {
            harness.controller.scrollToLine(line, animated: false)
        }
        XCTAssertEqual(harness.sentScrollLines, [1])

        harness.finishOldestScroll()
        XCTAssertEqual(harness.sentScrollLines, [1, 5], "Only the newest waiting line is sent")
        harness.finishOldestScroll()
        harness.controller.scrollToLine(6, animated: false)
        XCTAssertEqual(harness.sentScrollLines, [1, 5, 6])
    }

    func testDocumentNavigationDiscardsWaitingViewportTraffic() {
        let harness = RenderDispatchHarness(testCase: self)
        harness.markReady()
        harness.controller.setPresentedDocumentIdentifier("post")
        let renderID = harness.controller.renderForTesting(DocumentTextChange(
            text: "# Post",
            version: 1,
            fileKind: .markdown,
            fileURL: nil
        ))
        harness.complete(renderID)

        harness.controller.scrollToLine(10, animated: false)
        harness.controller.scrollToLine(11, animated: false)
        var navigationResult: Bool?
        harness.controller.scrollToLine(40, animated: false, documentIdentifier: "post") {
            navigationResult = $0
        }
        XCTAssertEqual(harness.sentScrollLines, [10, 40], "Navigation is not queued behind viewport traffic")

        harness.finishOldestScroll()
        harness.finishOldestScroll()
        XCTAssertEqual(navigationResult, true)
        XCTAssertEqual(harness.sentScrollLines, [10, 40], "The older viewport line must not undo navigation")
    }

    func testTerminationFencesLateViewportCompletions() {
        let harness = RenderDispatchHarness(testCase: self)
        harness.markReady()
        harness.controller.scrollToLine(1, animated: false)
        harness.controller.webViewWebContentProcessDidTerminate(harness.controller.webView)

        harness.controller.scrollToLine(2, animated: false)
        harness.controller.scrollToLine(3, animated: false)
        XCTAssertEqual(harness.sentScrollLines, [1, 2])
        harness.finishOldestScroll()
        XCTAssertEqual(harness.sentScrollLines, [1, 2], "A completion from before the reset frees nothing")
        harness.finishOldestScroll()
        XCTAssertEqual(harness.sentScrollLines, [1, 2, 3])
    }

    func testExplicitCompletionBypassesTheViewportQueue() {
        let harness = RenderDispatchHarness(testCase: self)
        harness.markReady()
        harness.controller.scrollToLine(1, animated: false)
        var delivered: Bool?
        harness.controller.scrollToLine(2, animated: false) { delivered = $0 }
        XCTAssertEqual(harness.sentScrollLines, [1, 2])
        harness.finishOldestScroll()
        harness.finishOldestScroll(succeeded: false)
        XCTAssertEqual(delivered, false)
    }

    // MARK: Inbound bridge bodies

    func testInboundReaderMatchesTheCodableDecoder() throws {
        let bodies: [[String: Any]] = [
            ["name": "ready", "payload": ["protocolVersion": 8]],
            ["name": "renderComplete", "payload": ["renderID": 4, "version": 2, "blockCount": 17]],
            ["name": "renderComplete", "payload": ["renderID": -1, "version": 0, "blockCount": 0, "extra": "x"]],
            ["name": "previewScrolled", "payload": ["topVisibleLine": 120]],
            ["name": "linkClicked", "payload": ["href": "../other.md#part"]],
            ["name": "checkboxToggled", "payload": ["renderID": 9, "line": 3, "checked": true, "version": 5]],
            ["name": "checkboxToggled", "payload": ["renderID": 9, "line": 3, "checked": false, "version": 5]],
        ]
        for body in bodies {
            let data = try JSONSerialization.data(withJSONObject: body)
            let decoded = try JSONDecoder().decode(BridgeMessage.self, from: data)
            XCTAssertEqual(BridgeMessage(inboundBridgeBody: body), decoded, "\(body)")
        }
    }

    func testInboundReaderRejectsWhatTheDecoderRejects() throws {
        let bodies: [Any] = [
            "ready",
            ["name": "ready"],
            ["name": "ready", "payload": ["protocolVersion": "8"]],
            ["name": "ready", "payload": ["protocolVersion": true]],
            ["name": "renderComplete", "payload": ["renderID": 4.5, "version": 2, "blockCount": 1]],
            ["name": "renderComplete", "payload": ["renderID": 4, "blockCount": 1]],
            ["name": "previewScrolled", "payload": ["topVisibleLine": NSNull()]],
            ["name": "linkClicked", "payload": ["href": 3]],
            ["name": "checkboxToggled", "payload": ["renderID": 9, "line": 3, "checked": 1, "version": 5]],
            ["name": "checkboxToggled", "payload": ["line": 3, "checked": true, "version": 5]],
            ["name": "unknown", "payload": [:]],
            ["name": "render", "payload": ["renderID": 1]],
        ]
        for body in bodies {
            XCTAssertNil(BridgeMessage(inboundBridgeBody: body), "\(body)")
            if JSONSerialization.isValidJSONObject(body) {
                let data = try JSONSerialization.data(withJSONObject: body)
                if let decoded = try? JSONDecoder().decode(BridgeMessage.self, from: data) {
                    // Outbound names decode but are never accepted from JavaScript.
                    XCTAssertEqual(decoded.name, .render, "\(body)")
                }
            }
        }
    }

    func testRenderCompleteBodyDrivesTheDispatch() {
        let harness = RenderDispatchHarness(testCase: self)
        harness.markReady()
        let first = harness.controller.renderForTesting(DocumentTextChange(
            text: "one", version: 1, fileKind: .markdown, fileURL: nil
        ))
        let second = harness.controller.renderForTesting(DocumentTextChange(
            text: "two", version: 2, fileKind: .markdown, fileURL: nil
        ))
        harness.controller.receiveBridgeBody([
            "name": "renderComplete",
            "payload": ["renderID": first, "version": 1, "blockCount": 1],
        ])
        XCTAssertEqual(harness.sentRenderIDs, [first, second])
    }
}
