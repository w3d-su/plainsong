import AppKit
@testable import PreviewKit
import XCTest

final class PreviewKitTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertFalse(PreviewKitInfo.version.isEmpty)
    }

    func testBridgeProtocolVersionAndMessageOrder() {
        XCTAssertEqual(PreviewBridge.protocolVersion, 2)
        XCTAssertEqual(
            BridgeMessageName.allCases.map(\.rawValue),
            [
                "ready",
                "render",
                "renderComplete",
                "scrollToLine",
                "previewScrolled",
                "linkClicked",
                "checkboxToggled",
                "setTheme",
            ]
        )
    }

    func testBridgeMessageRoundTrip() throws {
        let message = BridgeMessage.checkboxToggled(
            CheckboxToggledPayload(line: 12, checked: true)
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(BridgeMessage.self, from: data)

        XCTAssertEqual(decoded, message)
    }

    @MainActor
    func testPreviewControllerUsesTransparentWebViewBackground() {
        let controller = PreviewController()

        XCTAssertEqual(controller.webView.layer?.backgroundColor, NSColor.clear.cgColor)
    }

    func testAssetResolverAllowsContainedPaths() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resolver = AssetURLResolver(allowedRoot: root)

        let resolved = try resolver.resolve(XCTUnwrap(URL(string: "asset://images/photo.png")))

        XCTAssertEqual(
            resolved,
            root.appendingPathComponent("images/photo.png").standardizedFileURL
        )
    }

    func testAssetResolverRejectsParentDirectoryEscapes() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resolver = AssetURLResolver(allowedRoot: root)

        XCTAssertThrowsError(
            try resolver.resolve(XCTUnwrap(URL(string: "asset://../secret.png")))
        ) { error in
            XCTAssertEqual(error as? AssetURLResolverError, .pathEscapesRoot)
        }
    }
}
