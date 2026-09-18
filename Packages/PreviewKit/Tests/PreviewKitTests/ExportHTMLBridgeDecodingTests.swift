import Foundation
@testable import PreviewKit
import XCTest

final class ExportHTMLBridgeDecodingTests: XCTestCase {
    func testDirectDecoderMatchesCodableForAllResultStates() throws {
        let states: [ExportHTMLResultState] = [
            .ready(html: "<html>中🙂</html>"), .failed(reason: "failed"),
            .resourcesNeeded(resources: [.init(resourceID: "image-0", kind: .image, src: "asset://a.png")]),
        ]
        for state in states {
            let payload = ExportHTMLResultPayload(exportID: 2, renderID: 3, state: state)
            let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))
            XCTAssertEqual(ExportHTMLResultPayload(bridgeBody: body), payload)
        }
    }

    func testDirectDecoderRejectsMalformedIDsStatesAndResourceEntries() {
        let good: [String: Any] = ["exportID": 1, "renderID": 2, "state": ["kind": "ready", "html": "x"]]
        for invalid in [true, -1, 1.5, "1", Double.infinity] as [Any] {
            var body = good
            body["exportID"] = invalid
            XCTAssertNil(ExportHTMLResultPayload(bridgeBody: body))
        }
        for state in [
            ["kind": "unknown"], ["kind": "ready", "html": 42], ["kind": "failed"],
            ["kind": "resourcesNeeded", "resources": [["resourceID": "x", "kind": "invalid", "src": "x"]]],
            ["kind": "resourcesNeeded", "resources": [["resourceID": "x", "kind": "image"]]],
        ] as [[String: Any]] {
            var body = good
            body["state"] = state
            XCTAssertNil(ExportHTMLResultPayload(bridgeBody: body))
        }
    }

    @MainActor
    func testMultiMegabyteReadyBridgeReceiptFitsExistingMainActorBudget() async throws {
        let controller = PreviewController(previewIndexURL: nil)
        defer { controller.invalidate() }
        // NSString-backed payload resembles WKScriptMessage's Foundation bridge.
        let html = NSString(string: String(repeating: "<p>中🙂 & content</p>\n", count: 250_000))
        let bytes = html.lengthOfBytes(using: String.Encoding.utf8.rawValue)
        XCTAssertGreaterThan(bytes, 4 * 1024 * 1024)
        var samples: [Double] = []
        for exportID in 0 ..< 5 {
            let body: NSDictionary = ["name": "exportHTMLResult", "payload": [
                "exportID": exportID, "renderID": 1, "state": ["kind": "ready", "html": html],
            ]]
            let result: PreviewHTMLExportResult = await withCheckedContinuation { continuation in
                var pending = PendingHTMLExport(exportID: exportID, renderID: 1, continuation: continuation)
                pending.phase = .finalization
                controller.pendingHTMLExport = pending
                let start = DispatchTime.now().uptimeNanoseconds
                controller.receiveBridgeBody(body)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            guard case let .ready(received, receivedID, _) = result else {
                return XCTFail("Expected large ready result")
            }
            XCTAssertEqual(receivedID, exportID)
            XCTAssertEqual(received, html as String)
            XCTAssertNil(controller.pendingHTMLExport)
        }
        print("E9_INFORMATIONAL bridgeBytes=\(bytes) mainActorMilliseconds=\(samples)")
        if ProcessInfo.processInfo.environment["CI"] != "true" {
            XCTAssertLessThan(
                try XCTUnwrap(samples.max()),
                16,
                "Existing main-actor budget; not a full typing measurement"
            )
        }
    }
}
