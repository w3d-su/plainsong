import MarkdownCore
@testable import SyntaxKit
import TreeSitterYAMLFixed
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

    /// Does not depend on tree-sitter's `ts_assert`, which `NDEBUG` compiles out.
    func testSerializeStaysInsideTheSerializationBuffer() throws {
        let limit = 1024
        let header = 5 * MemoryLayout<Int16>.size
        let entry = 2 * MemoryLayout<Int16>.size
        for depth in [253, 254, 255, 400, 2000] {
            let scanner = try XCTUnwrap(tree_sitter_yaml_external_scanner_create())
            defer { tree_sitter_yaml_external_scanner_destroy(scanner) }
            let state = [CChar](repeating: 1, count: header + depth * entry)
            tree_sitter_yaml_external_scanner_deserialize(scanner, state, UInt32(state.count))

            let sentinel: CChar = 0x5A
            var buffer = [CChar](repeating: sentinel, count: limit + 64)
            let length = Int(tree_sitter_yaml_external_scanner_serialize(scanner, &buffer))
            XCTAssertEqual(length, header + min(depth, (limit - header) / entry) * entry, "depth \(depth)")
            XCTAssertTrue(buffer[limit...].allSatisfy { $0 == sentinel }, "depth \(depth) wrote past the buffer")
        }
    }

    func testDeserializeIgnoresAShortStateAndATrailingHalfEntry() throws {
        let scanner = try XCTUnwrap(tree_sitter_yaml_external_scanner_create())
        defer { tree_sitter_yaml_external_scanner_destroy(scanner) }
        var buffer = [CChar](repeating: 0, count: 1024)
        // row 0, col 0, blk_imp_row -1, blk_imp_col -1, blk_imp_tab 0
        let resetHeader: [CChar] = [0, 0, 0, 0, -1, -1, -1, -1, 0, 0]
        let loadedHeader = [CChar](repeating: 1, count: 10)
        for (length, expected) in [(0, 10), (9, 10), (10, 10), (12, 10), (14, 14), (17, 14)] {
            // Start from a loaded state, so a short state must reset it.
            let full = [CChar](repeating: 2, count: 14)
            tree_sitter_yaml_external_scanner_deserialize(scanner, full, UInt32(full.count))
            let state = [CChar](repeating: 1, count: length)
            tree_sitter_yaml_external_scanner_deserialize(scanner, state, UInt32(length))
            let written = Int(tree_sitter_yaml_external_scanner_serialize(scanner, &buffer))
            XCTAssertEqual(written, expected, "length \(length)")
            XCTAssertEqual(Array(buffer[..<10]), length < 10 ? resetHeader : loadedHeader, "length \(length)")
            XCTAssertTrue(buffer[10 ..< written].allSatisfy { $0 == 1 }, "length \(length)")
        }
    }
}
