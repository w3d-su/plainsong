@testable import MarkdownCore
import XCTest

final class ExactSourceReconciliationTests: XCTestCase {
    func testNonOverlappingPrefixAndMarkedTextEditsAreBothPreservedExactlyOnce() {
        let base = "body: "
        let current = "remote body: "
        let proposed = "body: 臺e\u{0301}🧪"

        let reconciled = ExactSourceText.reconciling(
            base: base,
            current: current,
            proposed: proposed
        )

        XCTAssertEqual(Array(reconciled?.utf16 ?? "".utf16), Array("remote body: 臺e\u{0301}🧪".utf16))
    }

    func testSeveralAcceptedCurrentEditsReconcileWithADistantProposal() {
        let reconciled = ExactSourceText.reconciling(
            base: "alpha beta gamma",
            current: "ALPHA beta gamma!",
            proposed: "alpha BETA gamma"
        )

        XCTAssertEqual(reconciled, "ALPHA BETA gamma!")
    }

    func testPrefixInsertionDoesNotDriftIntoRepeatedCharactersWhenProposalAppends() {
        let base = "A composition: "
        XCTAssertEqual(
            ExactSourceText.reconciling(
                base: base,
                current: "remote " + base,
                proposed: base + "臺e\u{0301}🧪"
            ),
            "remote " + base + "臺e\u{0301}🧪"
        )
    }

    func testOverlappingStaleReplacementIsRejectedInsteadOfOverwritingCurrentSource() {
        XCTAssertNil(ExactSourceText.reconciling(
            base: "alpha beta",
            current: "alpha current",
            proposed: "alpha proposed"
        ))
    }

    func testOverlappingWordReplacementIsNotMistakenForBoundaryInsertion() {
        XCTAssertNil(ExactSourceText.reconciling(
            base: "prefix target suffix",
            current: "prefix current suffix",
            proposed: "prefix proposed suffix"
        ))
    }

    func testDuplicateAcceptedEditAppearsOnlyOnce() {
        XCTAssertEqual(
            ExactSourceText.reconciling(
                base: "source",
                current: "source!",
                proposed: "source!"
            ),
            "source!"
        )
    }

    func testInsertionAtReplacementLowerBoundaryMergesBeforeReplacement() {
        let reconciled = ExactSourceText.reconciling(
            base: "A\u{1F9EA}B",
            current: "AoldB",
            proposed: "Ae\u{0301}\u{1F9EA}B"
        )

        XCTAssertEqual(
            Array(reconciled?.utf16 ?? "".utf16),
            Array("Ae\u{0301}oldB".utf16)
        )
    }

    func testInsertionAtReplacementUpperBoundaryMergesAfterReplacement() {
        let reconciled = ExactSourceText.reconciling(
            base: "Ae\u{0301}B",
            current: "A\u{1F9EA}B",
            proposed: "Ae\u{0301}\u{81FA}B"
        )

        XCTAssertEqual(
            Array(reconciled?.utf16 ?? "".utf16),
            Array("A\u{1F9EA}\u{81FA}B".utf16)
        )
    }

    func testInsertionStrictlyInsideReplacementStillConflicts() {
        XCTAssertNil(ExactSourceText.reconciling(
            base: "AoldB",
            current: "A\u{1F9EA}B",
            proposed: "Ao\u{4E2D}ldB"
        ))
    }

    func testRepeatedSourceInsertionWithAmbiguousOffsetIsRejected() {
        XCTAssertNil(ExactSourceText.reconciling(
            base: "aaaa",
            current: "aaaaa",
            proposed: "baaa"
        ))
    }

    func testAmbiguousProposalAlignmentIsAlsoRejected() {
        XCTAssertNil(ExactSourceText.reconciling(
            base: "aaaa",
            current: "baaa",
            proposed: "aaaaa"
        ))
    }

    func testDifferentMinimalAlignmentsAreRejected() {
        XCTAssertNil(ExactSourceText.reconciling(
            base: "ab",
            current: "ba",
            proposed: "aB"
        ))
    }

    func testMultiUnitRepeatedInsertionAlignmentIsRejected() {
        XCTAssertNil(ExactSourceText.reconciling(
            base: "abx",
            current: "ababx",
            proposed: "zbx"
        ))
    }

    func testSplitRepeatedInsertionAlignmentIsRejected() {
        XCTAssertNil(ExactSourceText.reconciling(
            base: "a",
            current: "baa",
            proposed: "A"
        ))
    }

    func testIndependentInsertionsIntoEmptyBaseConflictWithoutCrashing() {
        XCTAssertNil(ExactSourceText.reconciling(
            base: "",
            current: "current",
            proposed: "proposed"
        ))
    }

    func testUniquePrefixInsertionStillMergesWithDistantReplacement() {
        XCTAssertEqual(ExactSourceText.reconciling(
            base: "abcd",
            current: "xabcd",
            proposed: "abYd"
        ), "xabYd")
    }
}
