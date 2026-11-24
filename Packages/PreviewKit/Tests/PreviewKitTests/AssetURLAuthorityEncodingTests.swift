import Foundation
@testable import PreviewKit
import XCTest

/// The preview percent-encodes a first path segment that would not survive as a URL
/// authority (`[slug]`, `shot@2x.png`); the resolver decodes it back to the same path.
final class AssetURLAuthorityEncodingTests: XCTestCase {
    func testResolverDecodesAuthorityUnsafeFirstSegments() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resolver = AssetURLResolver(allowedRoot: root)

        for (encoded, path) in [
            ("asset://%5Bslug%5D/cover.png", "[slug]/cover.png"),
            ("asset://screenshot%402x.png", "screenshot@2x.png"),
            ("asset://foo%3A80/a.png", "foo:80/a.png"),
        ] {
            XCTAssertEqual(
                try resolver.resolve(XCTUnwrap(URL(string: encoded))),
                root.appendingPathComponent(path).standardizedFileURL,
                encoded
            )
        }
    }
}
