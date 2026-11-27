import Foundation
import MarkdownCore
@testable import SyntaxKit
import XCTest

final class MDXRangeSetTests: XCTestCase {
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
