@testable import MarkdownCore
import XCTest

/// Codebase review, Medium: a unit diff must not rebuild a surrogate pair from two edits.
final class ExactSourceReconciliationSurrogateTests: XCTestCase {
    func testReconciliationRefusesEditsToTheTwoHalvesOfOneSurrogatePair() {
        // U+1F600 is D83D DE00. One side changes only the high unit (U+1F200), the other
        // only the low unit (U+1F601). Merged per unit they spell U+1F201, which nobody typed.
        let reconciled = ExactSourceText.reconciling(
            base: "a\u{1F600}b",
            current: "a\u{1F200}b",
            proposed: "a\u{1F601}b"
        )

        XCTAssertNil(reconciled)
    }

    func testReconciliationRefusesAnInsertionInsideAPairTheOtherSideReplaced() {
        // The proposal's shortest diff inserts DE01 D83D between the two halves of U+1F600.
        let reconciled = ExactSourceText.reconciling(
            base: "\u{1F600}",
            current: "\u{1F200}",
            proposed: "\u{1F601}\u{1F600}"
        )

        XCTAssertNil(reconciled)
    }

    func testReconciliationStillMergesAHalfPairEditWithADistantEdit() {
        let reconciled = ExactSourceText.reconciling(
            base: "a\u{1F600}b tail",
            current: "a\u{1F601}b tail",
            proposed: "a\u{1F600}b tail!"
        )

        XCTAssertEqual(reconciled, "a\u{1F601}b tail!")
    }
}
