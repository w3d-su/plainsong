@testable import MarkdownCore
import XCTest

func assertTextSearchMatchesAreValid(
    _ matches: [TextSearchMatch],
    in source: String,
    expected: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    for match in matches {
        XCTAssertLessThanOrEqual(NSMaxRange(match.range), (source as NSString).length, file: file, line: line)
        XCTAssertLessThanOrEqual(
            NSMaxRange(match.previewMatchRange),
            (match.preview as NSString).length,
            file: file,
            line: line
        )
        XCTAssertEqual((source as NSString).substring(with: match.range), expected, file: file, line: line)
        XCTAssertEqual(
            (match.preview as NSString).substring(with: match.previewMatchRange),
            expected,
            file: file,
            line: line
        )
        assertTextSearchHasNoTornSurrogates(match.preview, file: file, line: line)
    }
}

func assertTextSearchHasNoTornSurrogates(
    _ string: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let units = Array(string.utf16)
    var index = 0
    while index < units.count {
        if UTF16.isLeadSurrogate(units[index]) {
            let hasTrail = index + 1 < units.count && UTF16.isTrailSurrogate(units[index + 1])
            XCTAssertTrue(hasTrail, "torn lead surrogate at UTF-16 offset \(index)", file: file, line: line)
            index += 2
        } else if UTF16.isTrailSurrogate(units[index]) {
            XCTFail("orphan trail surrogate at UTF-16 offset \(index)", file: file, line: line)
            index += 1
        } else {
            index += 1
        }
    }
}

func assertTextSearchDurationUnderLocally(
    _ duration: Duration,
    _ budget: Duration,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if duration <= budget { return }
    let environment = ProcessInfo.processInfo.environment
    if environment["CI"] != nil || environment["GITHUB_ACTIONS"] != nil {
        print("\(message) took \(duration) on CI; informational per risk R15")
        return
    }
    XCTFail("\(message) took \(duration) (budget \(budget))", file: file, line: line)
}
