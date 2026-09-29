@testable import PreviewKit
import XCTest

final class ExportHTMLProtocolTests: XCTestCase {
    func testExportHTMLDiscoveryRoundTrip() throws {
        let message = BridgeMessage.exportHTML(
            ExportHTMLPayload(exportID: 3, renderID: 8, phase: .discovery, documentTitle: "Frontmatter title")
        )
        let decoded = try JSONDecoder().decode(
            BridgeMessage.self,
            from: JSONEncoder().encode(message)
        )
        XCTAssertEqual(decoded, message)
    }

    func testExportHTMLResultStatesRoundTrip() throws {
        let needed = BridgeMessage.exportHTMLResult(
            ExportHTMLResultPayload(
                exportID: 3,
                renderID: 8,
                state: .resourcesNeeded(
                    resources: [
                        ExportResourceDescriptor(
                            resourceID: "image-0",
                            kind: .image,
                            src: "asset://images/a.png"
                        ),
                    ]
                )
            )
        )
        let ready = BridgeMessage.exportHTMLResult(
            ExportHTMLResultPayload(
                exportID: 3,
                renderID: 8,
                state: .ready(html: "<!DOCTYPE html><html></html>")
            )
        )
        let failed = BridgeMessage.exportHTMLResult(
            ExportHTMLResultPayload(
                exportID: 3,
                renderID: 8,
                state: .failed(reason: "mdx-stale-or-error")
            )
        )

        for message in [needed, ready, failed] {
            let decoded = try JSONDecoder().decode(
                BridgeMessage.self,
                from: JSONEncoder().encode(message)
            )
            XCTAssertEqual(decoded, message)
        }
    }

    func testRepeatedEmbedOutcomeReferencesTheFirstDataURIRoundTrip() throws {
        let first = ExportResourceOutcome(
            resourceID: "image-0",
            kind: .image,
            action: .embed,
            dataURI: "data:image/png;base64,AAAA"
        )
        let repeated = ExportResourceOutcome(
            resourceID: "image-1",
            kind: .image,
            action: .embed,
            dataURIFrom: "image-0"
        )
        let message = BridgeMessage.exportHTML(
            ExportHTMLPayload(exportID: 5, renderID: 9, phase: .finalization, resourceOutcomes: [first, repeated])
        )
        let encoded = try JSONEncoder().encode(message)
        XCTAssertEqual(try JSONDecoder().decode(BridgeMessage.self, from: encoded), message)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertEqual(json.components(separatedBy: "\"dataURI\"").count - 1, 1)
        XCTAssertTrue(json.contains("\"dataURIFrom\":\"image-0\""))
    }

    func testFinalizationOmitOutcomesRoundTrip() throws {
        let resource = ExportResourceDescriptor(
            resourceID: "image-0",
            kind: .image,
            src: "asset://images/a.png"
        )
        let message = BridgeMessage.exportHTML(
            ExportHTMLPayload(
                exportID: 4,
                renderID: 9,
                phase: .finalization,
                resourceOutcomes: [ExportResourceOutcome.omit(resource)]
            )
        )
        let decoded = try JSONDecoder().decode(
            BridgeMessage.self,
            from: JSONEncoder().encode(message)
        )
        XCTAssertEqual(decoded, message)
    }
}
