import Foundation
@testable import PreviewKit
import XCTest

final class SVGAssetContainmentTests: XCTestCase {
    func testNavigationPolicyCancelsAssetSVG() {
        let indexURL = URL(fileURLWithPath: "/tmp/Plainsong.app/Contents/Resources/preview/index.html")
        XCTAssertEqual(
            PreviewController.navigationPolicy(
                for: URL(string: "asset://images/diagram.svg"),
                previewIndexURL: indexURL
            ),
            .cancel
        )
        XCTAssertEqual(
            PreviewController.navigationPolicy(
                for: URL(string: "asset://images/diagram.svg?plainsong-root=token"),
                previewIndexURL: indexURL
            ),
            .cancel
        )
    }

    func testAssetResolverRejectsSVGTraversalAndSymlinkEscapes() throws {
        let root = try temporaryDirectory()
        let outsideRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideRoot)
        }
        let escapedTarget = outsideRoot.appendingPathComponent("secret.svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8).write(to: escapedTarget)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.svg"),
            withDestinationURL: escapedTarget
        )
        let resolver = AssetURLResolver(allowedRoot: root)
        for url in ["asset://../secret.svg", "asset://images/../../secret.svg", "asset://linked.svg"] {
            XCTAssertThrowsError(try resolver.resolve(XCTUnwrap(URL(string: url))), url) { error in
                XCTAssertEqual(error as? AssetURLResolverError, .pathEscapesRoot)
            }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
