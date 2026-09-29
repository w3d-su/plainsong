import AppKit
@testable import EditorKit
import MarkdownCore
import XCTest

@MainActor
final class EditorReplacePublicationTests: XCTestCase {
    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testReplacementRescansOnceAndSkipsTheInsertedSpan() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "a a", pattern: "a")
        let editsBefore = ready.controller.editScheduleCount
        let outcome = EditorReplaceSingleSupport.perform(ready, replacement: "aa")
        guard case let .replaced(plan) = outcome else {
            return XCTFail("Expected a source change, got \(outcome)")
        }
        XCTAssertEqual(plan.resumeUTF16, 2)
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: ready.fixture.textView), "aa a")
        XCTAssertEqual(ready.fixture.model.publications.count, 1)
        XCTAssertEqual(ready.controller.replacementScheduleCount, 1)
        XCTAssertEqual(ready.controller.editScheduleCount, editsBefore)
        XCTAssertEqual(ready.controller.lastScheduleReason, .replacement(resumeUTF16: 2))

        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            ready.controller.replacementEngineInvocationCount == 1
                && ready.controller.session?.currentMatch != nil
        }
        XCTAssertEqual(ready.controller.replacementEngineInvocationCount, 1)
        XCTAssertEqual(ready.controller.editScheduleCount, editsBefore)
        XCTAssertTrue(ready.controller.lastMatchRanOffMain)
        let continued = ("aa a" as NSString).range(of: "a", options: .backwards)
        XCTAssertEqual(continued.location, 3)
        XCTAssertEqual(ready.controller.session?.currentMatch?.range, continued)
        XCTAssertEqual(ready.controller.session?.currentOrdinal, 3)
        guard case let .navigate(request)? = ready.controller.pendingNavigationCommand else {
            return XCTFail("Expected continuation navigation")
        }
        XCTAssertEqual(request.selection, continued)
        XCTAssertFalse(request.shouldFocusEditor)
        ready.fixture.coordinator.observeNavigationCommand(ready.controller.pendingNavigationCommand)
        _ = ready.fixture.coordinator.applyPendingNavigationIfPossible(in: ready.fixture.textView)
        XCTAssertEqual(ready.fixture.textView.selectedRange(), continued)
    }

    func testSameRevisionOrdinaryEditCannotWin() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "a a", pattern: "a")
        let hold = EditorFindMatchHold()
        ready.controller.testMatchHold = hold
        let outcome = EditorReplaceSingleSupport.perform(ready, replacement: "aa")
        guard case .replaced = outcome else {
            return XCTFail("Expected a source change, got \(outcome)")
        }
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            hold.waiterCount == 1
        }
        let published = ready.controller.documentBinding
        ready.controller.documentTextDidChange(text: published.text, revision: published.revision)
        XCTAssertEqual(ready.controller.editScheduleCount, 0)
        XCTAssertEqual(ready.controller.replacementScheduleCount, 1)
        hold.release()
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            ready.controller.replacementEngineInvocationCount == 1
                && ready.controller.session?.currentOrdinal == 3
        }
        XCTAssertEqual(ready.controller.editScheduleCount, 0)
        XCTAssertEqual(ready.controller.replacementEngineInvocationCount, 1)
        XCTAssertEqual(ready.controller.lastScheduleReason, .replacement(resumeUTF16: 2))
    }

    /// ⌘G pressed while the replacement rescan is in flight is applied to the
    /// continuation (one step past it), exactly like a navigating query.
    func testStepPressedDuringReplacementRescanIsApplied() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "a a a", pattern: "a")
        let hold = EditorFindMatchHold()
        ready.controller.testMatchHold = hold
        let outcome = EditorReplaceSingleSupport.perform(ready, replacement: "b")
        guard case .replaced = outcome else {
            return XCTFail("Expected a source change, got \(outcome)")
        }
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            hold.waiterCount == 1
        }
        XCTAssertNil(ready.controller.session)
        ready.controller.findNext()
        hold.release()
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            ready.controller.session != nil
        }

        // "b a a": the continuation is the match at 2 (ordinal 1); the press moves to 4.
        XCTAssertEqual(ready.controller.session?.currentOrdinal, 2)
        XCTAssertEqual(ready.controller.session?.currentMatch?.range, NSRange(location: 4, length: 1))
        guard case let .navigate(request)? = ready.controller.pendingNavigationCommand else {
            return XCTFail("Expected navigation to the stepped match")
        }
        XCTAssertEqual(request.selection, NSRange(location: 4, length: 1))
        XCTAssertFalse(request.shouldFocusEditor)
    }

    /// Replace is one explicit command, not typing: its rescan is admitted
    /// without the 150 ms typing debounce.
    func testReplacementRescanDoesNotWaitForTypingDebounce() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "a a", pattern: "a")
        ready.controller.debounceNanoseconds = 60_000_000_000
        let outcome = EditorReplaceSingleSupport.perform(ready, replacement: "aa")
        guard case .replaced = outcome else {
            return XCTFail("Expected a source change, got \(outcome)")
        }
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            ready.controller.session?.currentOrdinal == 3
        }
        XCTAssertEqual(ready.controller.replacementEngineInvocationCount, 1)
    }

    /// A later edit supersedes the continuation: the caret stays where the user
    /// is typing and Find recomputes counter-only.
    func testEditDuringReplacementRescanSupersedesContinuation() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "a a", pattern: "a")
        let hold = EditorFindMatchHold()
        ready.controller.testMatchHold = hold
        let outcome = EditorReplaceSingleSupport.perform(ready, replacement: "aa")
        guard case .replaced = outcome else {
            return XCTFail("Expected a source change, got \(outcome)")
        }
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            hold.waiterCount == 1
        }
        let dropped = ready.controller.droppedStaleMatchCount
        let published = ready.controller.documentBinding
        ready.controller.documentTextDidChange(
            text: published.text + "a",
            revision: published.revision + 1
        )
        hold.release()
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            ready.controller.session != nil
        }
        XCTAssertEqual(ready.controller.droppedStaleMatchCount, dropped + 1)
        XCTAssertEqual(ready.controller.editScheduleCount, 1)
        XCTAssertEqual(ready.controller.lastScheduleReason, .edit)
        XCTAssertNil(ready.controller.pendingNavigationCommand)
    }

    /// Find hears the replacement only after the writer-authorized closure
    /// returns, even when the publication reaches it inside the native write.
    func testRoutedPublicationNotifiesFindAfterTheWriterClosure() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "a a", pattern: "a")
        EditorReplaceSingleSupport.routePublicationsToFind(ready)
        let depths = DepthLog()
        let coordinator = ready.fixture.coordinator
        ready.controller.onSessionDidChange = {
            depths.values.append(coordinator.writerAuthorizedTextMutationDepth)
        }
        let outcome = EditorReplaceSingleSupport.perform(ready, replacement: "aa")
        guard case .replaced = outcome else {
            return XCTFail("Expected a source change, got \(outcome)")
        }
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            ready.controller.session?.currentOrdinal == 3
        }
        XCTAssertFalse(depths.values.isEmpty)
        XCTAssertEqual(Set(depths.values), [0])
        XCTAssertEqual(ready.controller.recordedReplacementPublicationCount, 1)
        XCTAssertEqual(ready.controller.replacementScheduleCount, 1)
        XCTAssertEqual(ready.controller.replacementEngineInvocationCount, 1)
        XCTAssertEqual(ready.controller.editScheduleCount, 0)
    }

    func testNoLaterMatchCollapsesAtResumeWithoutWrap() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "one", pattern: "one")
        let outcome = EditorReplaceSingleSupport.perform(ready, replacement: "two")
        guard case let .replaced(plan) = outcome else {
            return XCTFail("Expected a source change, got \(outcome)")
        }
        XCTAssertEqual(plan.resumeUTF16, 3)
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            ready.controller.replacementEngineInvocationCount == 1
                && ready.controller.session != nil
        }
        XCTAssertEqual(ready.controller.replacementEngineInvocationCount, 1)
        XCTAssertNil(ready.controller.session?.currentOrdinal)
        XCTAssertEqual(ready.controller.session?.total, 0)
        XCTAssertEqual(ready.controller.caretAnchorUTF16, 3)
        XCTAssertEqual(ready.controller.session?.caretAnchorUTF16, 3)
        guard case let .navigate(request)? = ready.controller.pendingNavigationCommand else {
            return XCTFail("Expected a collapsed caret navigation")
        }
        XCTAssertEqual(request.selection, NSRange(location: 3, length: 0))
        XCTAssertFalse(request.shouldFocusEditor)
        ready.fixture.coordinator.observeNavigationCommand(ready.controller.pendingNavigationCommand)
        _ = ready.fixture.coordinator.applyPendingNavigationIfPossible(in: ready.fixture.textView)
        XCTAssertEqual(ready.fixture.textView.selectedRange(), NSRange(location: 3, length: 0))
    }
}

private final class DepthLog {
    var values: [Int] = []
}
