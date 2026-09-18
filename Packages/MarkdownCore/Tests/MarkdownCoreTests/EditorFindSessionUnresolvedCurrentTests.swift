import Foundation
@testable import MarkdownCore
import XCTest

final class EditorFindSessionUnresolvedCurrentTests: XCTestCase {
    func testUnresolvedCurrentKeepsMatchesAndLetsExplicitNextWrap() {
        let session = EditorFindSession.search(
            in: "one two one",
            query: TextSearchQuery(pattern: "one")
        ).withUnresolvedCurrent(caretAnchorUTF16: 11)
        XCTAssertEqual(session.total, 2)
        XCTAssertNil(session.currentOrdinal)
        XCTAssertNil(session.currentMatch)
        XCTAssertEqual(session.next().currentOrdinal, 1)
        XCTAssertEqual(session.previous().currentOrdinal, 2)
    }

    func testOrdinarySearchStillResolvesACurrentOrdinal() {
        let session = EditorFindSession.search(
            in: "one two one",
            query: TextSearchQuery(pattern: "one"),
            caretAnchorUTF16: 11
        )
        XCTAssertEqual(session.currentOrdinal, 1)
    }
}
