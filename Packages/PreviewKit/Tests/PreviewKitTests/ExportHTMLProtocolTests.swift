@testable import PreviewKit
import XCTest

final class ExportHTMLProtocolTests: XCTestCase {
    func testExportHTMLDiscoveryRoundTrip() throws {
        let message = BridgeMessage.exportHTML(
            ExportHTMLPayload(exportID: 3, renderID: 8, phase: .discovery)
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
