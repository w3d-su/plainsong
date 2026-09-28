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
