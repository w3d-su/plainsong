import Foundation
import MarkdownCore
@testable import SyntaxKit
import XCTest

final class MDXTokenDeduplicationTests: XCTestCase {
    private let source = """
    import A from 'a'

    <Card title="x">
      <b>hi</b>
    </Card>

    text <Badge kind="n" /> more

    <Foo />
    export const z = 1

    ```js
    <Foo />
    ```

    """

    func testHTMLBlockLinesAreTokenizedOnce() throws {
        let tokens = try MarkdownSyntaxParser().tokens(in: source, fileKind: .mdx)
        let keys = tokens.map { "\($0.kind) \($0.range.location) \($0.range.length)" }

        XCTAssertEqual(keys.count, Set(keys).count, "duplicate tokens: \(keys.sorted())")
    }

    func testEveryMDXRegionStillGetsTSXTokens() throws {
        let tokens = try MarkdownSyntaxParser().tokens(in: source, fileKind: .mdx)
        let storage = source as NSString
        let tags = tokens.filter { $0.kind == .tsxTag }.map { storage.substring(with: $0.range) }
        let keywords = tokens.filter { $0.kind == .tsxKeyword }.map { storage.substring(with: $0.range) }

        XCTAssertEqual(tags, ["Card", "b", "b", "Card", "Badge", "Foo"])
        XCTAssertTrue(keywords.contains("import"))
        XCTAssertTrue(keywords.contains("export"))
        // A closing tag parsed alone used to add a stray one-unit `<` beside `</`.
        let closing = storage.range(of: "</Card>").location
        XCTAssertEqual(
            tokens.filter { $0.kind == .tsxPunctuation && $0.range.location == closing }.map(\.range.length),
            [2]
        )
    }

    func testRangeSetMatchesALinearIntersectionScan() {
        let ranges = [
            NSRange(location: 40, length: 10),
            NSRange(location: 5, length: 5),
            NSRange(location: 8, length: 12),
            NSRange(location: 30, length: 0),
            NSRange(location: 60, length: 1),
        ]
        let set = MDXRangeSet(ranges)
        for location in 0 ..< 70 {
            for length in 0 ..< 12 {
                let probe = NSRange(location: location, length: length)
                let expected = ranges.contains { NSIntersectionRange(probe, $0).length > 0 }
                XCTAssertEqual(set.intersects(probe), expected, "\(probe)")
            }
        }
        XCTAssertFalse(MDXRangeSet([]).intersects(NSRange(location: 0, length: 4)))
    }
}
