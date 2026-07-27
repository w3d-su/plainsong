@testable import EditorKit
import MarkdownCore
import XCTest

/// `suspendNavigation()` fences navigation for a closing find UI **without** discarding the
/// ordinal the user was actually on.
@MainActor
final class EditorFindControllerSuspendTests: XCTestCase {
    private let documentA = EditorDocumentIdentity(rawValue: "document-a")

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

    func testSuspendKeepsTheResolvedOrdinalSoTheNextStepContinuesForward() async throws {
        let text = "a hit b hit c hit d"
        let hits = occurrences(of: "hit", in: text)
        XCTAssertEqual(hits.count, 3)
        let controller = makeController(text: text)
        controller.setQuery(TextSearchQuery(pattern: "hit"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 3
        }
        // Walk to hit 2, the way a user would with ⌘G.
        controller.findNext()
        XCTAssertEqual(controller.session?.currentOrdinal, 2)

        controller.suspendNavigation()

        XCTAssertNil(controller.pendingNavigationCommand, "Suspend drops unpublished navigation")
        XCTAssertEqual(
            controller.session?.currentOrdinal,
            2,
            "Suspend must not discard the resolved ordinal"
        )

        controller.findNext()
        guard case let .navigate(nav)? = controller.pendingNavigationCommand else {
            return XCTFail("expected navigation after suspend")
        }
        XCTAssertEqual(
            nav.selection,
            hits[2],
            "⌘G after the bar closes must advance to hit 3, not restart at hit 1"
        )
        XCTAssertEqual(controller.session?.currentOrdinal, 3)
    }

    func testSuspendDuringDebounceStillLeavesTheQueryUsable() async throws {
        let text = "a hit b hit c hit d"
        let hits = occurrences(of: "hit", in: text)
        let controller = makeController(text: text)
        let hold = EditorFindMatchHold()
        controller.testMatchHold = hold
        controller.setQuery(TextSearchQuery(pattern: "hit"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { hold.waiterCount >= 1 }
        XCTAssertNil(controller.session, "precondition: still computing")

        controller.testMatchHold = nil
        controller.suspendNavigation()
        hold.release()

        // No ordinal existed to preserve, so the query is re-run counter-only rather than
        // fenced into a generation that would never land.
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 3
        }
        XCTAssertNil(controller.pendingNavigationCommand, "counter-only recompute must not navigate")

        controller.findNext()
        guard case let .navigate(nav)? = controller.pendingNavigationCommand else {
            return XCTFail("⌘G after suspend-during-debounce must still work")
        }
        XCTAssertEqual(nav.selection, hits[0])
    }

    func testSuspendFencesAnInFlightGenerationSoItCannotNavigateLater() async throws {
        let text = "a hit b hit c hit d"
        let controller = makeController(text: text)
        controller.setQuery(TextSearchQuery(pattern: "hit"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 3
        }
        // A later edit starts a fresh generation that is still in flight when we suspend.
        let hold = EditorFindMatchHold()
        controller.testMatchHold = hold
        controller.documentTextDidChange(text: text + " hit e", revision: 2)
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { hold.waiterCount >= 1 }

        controller.suspendNavigation()
        hold.release()
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertNil(
            controller.pendingNavigationCommand,
            "A fenced generation must not publish navigation after suspend"
        )
        XCTAssertGreaterThan(controller.droppedStaleMatchCount, 0)
    }
}
