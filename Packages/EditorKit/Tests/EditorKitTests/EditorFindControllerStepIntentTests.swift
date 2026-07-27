@testable import EditorKit
import MarkdownCore
import XCTest

/// Pending ⌘G / ⇧⌘G recorded while a generation is still computing must belong to *that*
/// generation only, and repeated presses must not collapse into a single step.
@MainActor
final class EditorFindControllerStepIntentTests: XCTestCase {
    private let documentA = EditorDocumentIdentity(rawValue: "document-a")

    /// Every literal occurrence, in source order — avoids off-by-one `range(of:range:)` seeds.
    private func occurrences(of pattern: String, in text: String) -> [NSRange] {
        TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: pattern),
            limit: EditorFindLimits.engineMatchLimit
        ).map(\.range)
    }

    private func makeController(text: String) -> EditorFindController {
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: text,
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        return controller
    }

    func testNewerQueryDoesNotConsumeStepRecordedAgainstSupersededGeneration() async throws {
        // "alpha" resolves to one match; "beta" to two. A ⌘G recorded while the "alpha"
        // generation is in flight must not step the "beta" results.
        let text = "alpha beta gamma beta"
        let firstBeta = occurrences(of: "beta", in: text)[0]
        let controller = makeController(text: text)

        let alphaHold = EditorFindMatchHold()
        controller.testMatchHold = alphaHold
        controller.setQuery(TextSearchQuery(pattern: "alpha"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            alphaHold.waiterCount >= 1
        }
        controller.findNext()

        // Superseding query: the in-flight "alpha" worker is fence-dropped along with the step.
        let betaHold = EditorFindMatchHold()
        controller.testMatchHold = betaHold
        controller.setQuery(TextSearchQuery(pattern: "beta"))
        alphaHold.release()
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            betaHold.waiterCount >= 1
        }
        betaHold.release()

        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 2 && controller.pendingNavigationCommand != nil
        }
        guard case let .navigate(nav)? = controller.pendingNavigationCommand else {
            return XCTFail("expected navigation for the newer query")
        }
        XCTAssertEqual(
            nav.selection,
            firstBeta,
            "A step recorded for the superseded query must not advance the newer results"
        )
        XCTAssertEqual(controller.session?.currentOrdinal, 1)
    }

    func testRepeatedPendingStepsAreNotCompressedIntoOneStep() async throws {
        let text = "x hit a hit b hit c hit"
        let hits = occurrences(of: "hit", in: text)
        XCTAssertEqual(hits.count, 4)
        let third = hits[2]
        let controller = makeController(text: text)
        let hold = EditorFindMatchHold()
        controller.testMatchHold = hold
        controller.setQuery(TextSearchQuery(pattern: "hit"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { hold.waiterCount >= 1 }

        let generationBefore = controller.queryGeneration
        controller.findNext()
        controller.findNext()
        XCTAssertEqual(
            controller.queryGeneration,
            generationBefore,
            "Pending steps must not restart the debounce"
        )

        hold.release()
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 4 && controller.pendingNavigationCommand != nil
        }
        guard case let .navigate(nav)? = controller.pendingNavigationCommand else {
            return XCTFail("expected navigation after two pending steps")
        }
        // Query resolves ordinal 1; two next presses land on ordinal 3.
        XCTAssertEqual(controller.session?.currentOrdinal, 3)
        XCTAssertEqual(nav.selection, third)
    }

    func testOpposingPendingStepsCancelToTheQueryResolvedMatch() async throws {
        let text = "one two three two"
        let firstTwo = occurrences(of: "two", in: text)[0]
        let controller = makeController(text: text)
        let hold = EditorFindMatchHold()
        controller.testMatchHold = hold
        controller.setQuery(TextSearchQuery(pattern: "two"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { hold.waiterCount >= 1 }

        controller.findNext()
        controller.findPrevious()
        hold.release()

        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 2 && controller.pendingNavigationCommand != nil
        }
        guard case let .navigate(nav)? = controller.pendingNavigationCommand else {
            return XCTFail("expected navigation")
        }
        XCTAssertEqual(nav.selection, firstTwo)
        XCTAssertEqual(controller.session?.currentOrdinal, 1)
    }

    func testRepeatedStepsAfterCounterOnlyRecomputeActivateThenStep() async throws {
        let text = "one two three two"
        let secondTwo = occurrences(of: "two", in: text)[1]
        let controller = makeController(text: text)
        let hold = EditorFindMatchHold()
        controller.testMatchHold = hold
        // ⌘E-style pattern-only: no auto-navigate, so the first press activates current.
        controller.setQuery(TextSearchQuery(pattern: "two"), emitsNavigation: false)
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { hold.waiterCount >= 1 }

        controller.findNext()
        controller.findNext()
        hold.release()

        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 2 && controller.pendingNavigationCommand != nil
        }
        guard case let .navigate(nav)? = controller.pendingNavigationCommand else {
            return XCTFail("expected navigation")
        }
        XCTAssertEqual(nav.selection, secondTwo, "First press activates current, second steps")
        XCTAssertEqual(controller.session?.currentOrdinal, 2)
    }

    func testEditGenerationDoesNotConsumeStepRecordedForTheQueryGeneration() async throws {
        let text = "aa target bb target cc"
        let controller = makeController(text: text)
        let queryHold = EditorFindMatchHold()
        controller.testMatchHold = queryHold
        controller.setQuery(TextSearchQuery(pattern: "target"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { queryHold.waiterCount >= 1 }
        controller.findNext()

        let editedText = "aa target bb target cc dd"
        let editHold = EditorFindMatchHold()
        controller.testMatchHold = editHold
        controller.documentTextDidChange(text: editedText, revision: 2)
        queryHold.release()
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { editHold.waiterCount >= 1 }
        editHold.release()

        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 2
        }
        XCTAssertNil(
            controller.pendingNavigationCommand,
            "An edit recompute must not navigate using a step recorded for the query generation"
        )
        XCTAssertEqual(controller.session?.currentOrdinal, 1)
    }
}
