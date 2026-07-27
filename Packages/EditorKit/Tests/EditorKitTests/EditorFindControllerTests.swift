import AppKit
@testable import EditorKit
import MarkdownCore
import STTextView
import SwiftUI
import XCTest

@MainActor
final class EditorFindControllerTests: XCTestCase {
    private let documentA = EditorDocumentIdentity(rawValue: "find-doc-a")
    private let documentB = EditorDocumentIdentity(rawValue: "find-doc-b")

    // MARK: - F2 structural (off-main, cancel admission, fence)

    func testMatchWorkRunsOffMainAndReportsTrueFlag() async throws {
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: "alpha needle beta needle gamma",
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.forceMainActorMatchForTesting = false
        controller.setQuery(TextSearchQuery(pattern: "needle"))

        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 2
        }
        XCTAssertTrue(
            controller.lastMatchRanOffMain,
            "Production path must observe !Thread.isMainThread inside the worker"
        )
        XCTAssertEqual(controller.session?.currentOrdinal, 1)
        XCTAssertEqual(controller.completedMatchCount, 1)
    }

    func testMainActorMatchPathReportsOffMainFalse() async throws {
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: "alpha needle beta",
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.forceMainActorMatchForTesting = true
        controller.setQuery(TextSearchQuery(pattern: "needle"))

        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 1
        }
        XCTAssertFalse(
            controller.lastMatchRanOffMain,
            "Negative control: same search on the main actor must report ranOffMain == false"
        )
    }

    func testRapidQueryReplaceCancelsPriorAdmissionAndAppliesLatest() async throws {
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: "alpha needle beta needle gamma",
                revision: 1
            )
        )
        controller.debounceNanoseconds = 80_000_000
        controller.setQuery(TextSearchQuery(pattern: "alpha"))
        controller.setQuery(TextSearchQuery(pattern: "gamma"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 1
                && controller.session?.currentMatch?.range
                == ("alpha needle beta needle gamma" as NSString).range(of: "gamma")
        }
        XCTAssertGreaterThanOrEqual(
            controller.cancelledMatchCount,
            1,
            "Second setQuery must cancel the first in-flight admission task"
        )
        XCTAssertEqual(controller.session?.total, 1)
    }

    func testStaleMatchCompletionIsDropped() async throws {
        let text = "needle and zzz together"
        let hold = EditorFindMatchHold()
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: text,
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.testMatchHold = hold
        controller.setQuery(TextSearchQuery(pattern: "needle"))

        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            hold.waiterCount >= 1
        }
        XCTAssertNil(controller.session, "Held first match must not have applied yet")

        // Newer generation: no hold, completes while first is still blocked.
        controller.testMatchHold = nil
        controller.setQuery(TextSearchQuery(pattern: "zzz"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 1
                && controller.session?.currentMatch?.range
                == (text as NSString).range(of: "zzz")
        }
        XCTAssertEqual(controller.session?.total, 1)

        let dropsBeforeRelease = controller.droppedStaleMatchCount
        hold.release()
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.droppedStaleMatchCount > dropsBeforeRelease
        }
        XCTAssertGreaterThan(controller.droppedStaleMatchCount, dropsBeforeRelease)
        // Stale first generation must not overwrite the second result.
        XCTAssertEqual(controller.session?.total, 1)
        XCTAssertEqual(
            controller.session?.currentMatch?.range,
            (text as NSString).range(of: "zzz")
        )
    }

    // MARK: - F3 exact navigation

    func testActivateEmitsExactUTF16NavigationWithMonotonicIDs() async throws {
        let text = "prefix 🧪 target suffix"
        let target = (text as NSString).range(of: "target")
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: text,
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.setQuery(TextSearchQuery(pattern: "target"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { controller.session?.total == 1 }

        guard case let .navigate(first)? = controller.pendingNavigationCommand else {
            return XCTFail("Expected navigation command after query match")
        }
        XCTAssertEqual(first.documentIdentity, documentA)
        XCTAssertEqual(first.selection, target)

        controller.activateCurrentMatch()
        guard case let .navigate(second)? = controller.pendingNavigationCommand else {
            return XCTFail("Expected second navigation")
        }
        XCTAssertEqual(second.selection, target)
        XCTAssertGreaterThan(second.id, first.id, "re-activation needs a fresh monotonic ID")

        controller.findNext()
        guard case let .navigate(third)? = controller.pendingNavigationCommand else {
            return XCTFail("Expected third navigation")
        }
        XCTAssertGreaterThan(third.id, second.id)
        XCTAssertEqual(third.selection, target)
    }

    func testNavigationAppliesThroughExistingEditorNavigationPath() async throws {
        let text = (0 ... 200)
            .map { $0 == 150 ? "line \($0) exact find-hit" : "line \($0) filler" }
            .joined(separator: "\n")
        let target = (text as NSString).range(of: "exact find-hit")
        let model = EditorFindControllerTestSupport.FindNavModel(
            text: text,
            selection: NSRange(location: 0, length: 0)
        )
        let fixture = try EditorFindControllerTestSupport.makeWindowedFixture(
            model: model,
            source: text,
            documentIdentity: documentA,
            height: 100
        )
        fixture.textView.textSelection = NSRange(location: 0, length: 0)
        let sourceBytes = Data(text.utf8)

        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: text,
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.setQuery(TextSearchQuery(pattern: "exact find-hit"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { controller.session?.total == 1 }

        let command = try XCTUnwrap(controller.pendingNavigationCommand)
        fixture.coordinator.observeNavigationCommand(command)
        fixture.coordinator.applyPendingNavigationIfPossible(in: fixture.textView)

        XCTAssertEqual(fixture.textView.selectedRange(), target)
        XCTAssertEqual(Data(EditorFindControllerTestSupport.viewText(in: fixture.textView).utf8), sourceBytes)
        XCTAssertFalse(fixture.textView.undoManager?.canUndo == true)
    }

    // MARK: - F4 edit: recompute without navigation

    func testEditRecomputesMatchesWithoutMovingSelectionOrEmittingNavigation() async throws {
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: "one needle two needle",
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.setQuery(TextSearchQuery(pattern: "needle"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { controller.session?.total == 2 }

        guard case let .navigate(queryNav)? = controller.pendingNavigationCommand else {
            return XCTFail("Query completion should navigate")
        }
        let navigationIDBeforeEdit = queryNav.id

        controller.documentTextDidChange(text: "one needle only", revision: 2)
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 1
                && controller.documentBinding.revision == 2
        }
        XCTAssertEqual(controller.session?.total, 1)
        let only = ("one needle only" as NSString).range(of: "needle")
        XCTAssertEqual(controller.session?.currentMatch?.range, only)
        // Edit must not emit a new navigation command.
        guard case let .navigate(afterEdit)? = controller.pendingNavigationCommand else {
            return XCTFail("Expected prior query navigation to remain")
        }
        XCTAssertEqual(
            afterEdit.id,
            navigationIDBeforeEdit,
            "Document edit must not emit navigation; prior command id must be unchanged"
        )
    }

    // MARK: - F4b controller half: rebind without auto-jump

    func testRebindRerunsQueryWithoutEmittingNavigation() async throws {
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: "document A has apple",
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.setQuery(TextSearchQuery(pattern: "apple"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { controller.session?.total == 1 }
        XCTAssertNotNil(controller.pendingNavigationCommand)

        controller.rebindDocument(
            EditorFindDocumentBinding(
                identity: documentB,
                text: "document B has apple and apple",
                revision: 1
            )
        )
        // clearSessionKeepingQuery nils pending navigation; rebind must not re-emit.
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 2
                && controller.documentBinding.identity == self.documentB
        }
        XCTAssertEqual(controller.session?.total, 2)
        XCTAssertNil(
            controller.pendingNavigationCommand,
            "File switch re-runs the query for the counter but must not auto-jump; user uses ⌘G"
        )
    }

    func testClearForNoDocumentCancelsAndClearsSession() async throws {
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: "needle",
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.setQuery(TextSearchQuery(pattern: "needle"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { controller.session?.total == 1 }

        controller.clearForNoDocument()
        XCTAssertNil(controller.session)
        XCTAssertNil(controller.pendingNavigationCommand)
        XCTAssertEqual(controller.documentBinding, .empty)
    }
}
