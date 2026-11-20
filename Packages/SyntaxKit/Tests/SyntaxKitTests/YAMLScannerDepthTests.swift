import MarkdownCore
@testable import SyntaxKit
import XCTest

/// The YAML external scanner serializes two `int16_t` per indent level after a
/// 10-byte header into tree-sitter's 1024-byte buffer; level 254 used to write past it.
final class YAMLScannerDepthTests: XCTestCase {
    func testDeeplyNestedFrontmatterSequencesParse() throws {
        for depth in [253, 254, 255, 400, 2000] {
            let source = "---\n" + String(repeating: "- ", count: depth) + "x\n---\n\nbody\n"
            let tokens = try MarkdownSyntaxParser().tokens(in: source, fileKind: .markdown)
            XCTAssertFalse(tokens.isEmpty, "depth \(depth)")
        }
    }
}
