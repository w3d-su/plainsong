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

        XCTAssertNotNil(controller.pendingNavigationCommand, "Query completion should navigate")

        controller.documentTextDidChange(text: "one needle only", revision: 2)
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 1
                && controller.documentBinding.revision == 2
        }
        XCTAssertEqual(controller.session?.total, 1)
        let only = ("one needle only" as NSString).range(of: "needle")
        XCTAssertEqual(controller.session?.currentMatch?.range, only)
        // Edit recomputes the session but must not emit navigation; prior pending is
        // cleared at schedule so next/previous cannot jump to pre-edit ranges mid-flight.
        XCTAssertNil(
            controller.pendingNavigationCommand,
            "Document edit must not leave or emit a navigation command"
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
        XCTAssertNil(controller.query, "query must clear so a later document does not re-run find")
        XCTAssertNil(controller.pendingNavigationCommand)
        XCTAssertEqual(controller.documentBinding, .empty)
    }

    // MARK: - Debounce invalidation / first-next after rebind / shared ID domain

    func testScheduleMatchInvalidatesSessionSoNextDoesNotUseStaleRanges() async throws {
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: "alpha beta gamma",
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.setQuery(TextSearchQuery(pattern: "alpha"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { controller.session?.total == 1 }
        let staleRange = try XCTUnwrap(controller.session?.currentMatch?.range)

        let hold = EditorFindMatchHold()
        controller.testMatchHold = hold
        controller.setQuery(TextSearchQuery(pattern: "beta"))
        XCTAssertNil(
            controller.session,
            "session must drop immediately so next cannot navigate a superseded query"
        )
        XCTAssertNil(controller.pendingNavigationCommand)
        controller.findNext()
        XCTAssertNil(controller.pendingNavigationCommand)

        hold.release()
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 1
        }
        let freshRange = try XCTUnwrap(controller.session?.currentMatch?.range)
        XCTAssertNotEqual(freshRange, staleRange)
        XCTAssertEqual(freshRange, ("alpha beta gamma" as NSString).range(of: "beta"))
    }

    func testFirstFindNextAfterRebindActivatesCurrentMatchNotNext() async throws {
        // Text with two matches; caret at 0 → currentOrdinal resolves to first match.
        let text = "apple one apple two"
        let first = (text as NSString).range(of: "apple")
        let second = (text as NSString).range(
            of: "apple",
            options: [],
            range: NSRange(location: 1, length: text.utf16.count - 1)
        )
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: text,
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.setQuery(TextSearchQuery(pattern: "apple"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { controller.session?.total == 2 }
        // Drain query navigation.
        XCTAssertNotNil(controller.pendingNavigationCommand)

        controller.rebindDocument(
            EditorFindDocumentBinding(identity: documentB, text: text, revision: 1)
        )
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 2
                && controller.documentBinding.identity == self.documentB
        }
        XCTAssertNil(controller.pendingNavigationCommand, "rebind must not auto-navigate")
        XCTAssertEqual(controller.session?.currentOrdinal, 1)
        XCTAssertEqual(controller.session?.currentMatch?.range, first)

        // First ⌘G after rebind activates the current (first) match, does not skip to second.
        controller.findNext()
        guard case let .navigate(firstStep)? = controller.pendingNavigationCommand else {
            return XCTFail("expected navigation for current match")
        }
        XCTAssertEqual(firstStep.selection, first)

        // Second ⌘G advances to the next match.
        controller.findNext()
        guard case let .navigate(secondStep)? = controller.pendingNavigationCommand else {
            return XCTFail("expected navigation for next match")
        }
        XCTAssertEqual(secondStep.selection, second)
    }

    func testNavigationIDProviderUsesSharedDomain() async throws {
        var sharedHighWater: UInt64 = 500
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: "shared needle domain",
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.navigationIDProvider = {
            sharedHighWater &+= 1
            return sharedHighWater
        }
        controller.setQuery(TextSearchQuery(pattern: "needle"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { controller.session?.total == 1 }
        guard case let .navigate(request)? = controller.pendingNavigationCommand else {
            return XCTFail("expected navigation")
        }
        XCTAssertEqual(request.id, 501, "provider must supply shared-domain IDs")
        controller.findNext()
        guard case let .navigate(next)? = controller.pendingNavigationCommand else {
            return XCTFail("expected second navigation")
        }
        XCTAssertEqual(next.id, 502)
    }

    func testCancelInFlightWorkAdvancesFenceSoDetachedWorkerCannotApply() async throws {
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: "fence me",
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        let hold = EditorFindMatchHold()
        controller.testMatchHold = hold
        controller.setQuery(TextSearchQuery(pattern: "fence"))
        // Wait until the worker is held (match admitted after 0 debounce).
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            hold.waiterCount >= 1
        }
        let generationBeforeCancel = controller.queryGeneration
        controller.cancelInFlightWork()
        XCTAssertGreaterThan(
            controller.queryGeneration,
            generationBeforeCancel,
            "cancel must advance fence generation"
        )
        hold.release()
        // Give the detached worker a chance to finish and attempt apply.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(controller.session, "stale worker must not apply after cancel fence advance")
        XCTAssertGreaterThanOrEqual(controller.droppedStaleMatchCount, 1)
    }
}
