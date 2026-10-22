import Foundation
import MarkdownCore
@testable import PlainsongIOS
import XCTest

final class IOSSingleReplaceTests: XCTestCase {
    @MainActor
    func testFirstActionRevealsWhenSelectionIsNotMatch() throws {
        let harness = AuthoringHarness(text: "one two one")
        prepareSearch(harness, query: "one", replacement: "ONE")
        let snapshot = try XCTUnwrap(harness.editor.captureSnapshot())
        harness.editor.selection = NSRange(location: 4, length: 3)
        harness.controller.perform(.singleReplace, using: harness.editor)
        XCTAssertEqual(harness.editor.applyCount, 0)
        XCTAssertEqual(harness.editor.undoCount, 0)
        let reveal = try XCTUnwrap(harness.editor.revealCalls.last)
        XCTAssertEqual(reveal.range, NSRange(location: 0, length: 3))
        XCTAssertEqual(reveal.revision, snapshot.revision)
        XCTAssertTrue(reveal.accepted)
        XCTAssertEqual(harness.editor.text, "one two one")
    }

    @MainActor
    func testSecondActionReplacesActualRange() throws {
        let harness = AuthoringHarness(text: "one two one")
        prepareSearch(harness, query: "one", replacement: "ONE")
        harness.editor.selection = NSRange(location: 4, length: 3)
        harness.controller.perform(.singleReplace, using: harness.editor)
        XCTAssertEqual(harness.editor.selection, NSRange(location: 0, length: 3))
        harness.controller.perform(.singleReplace, using: harness.editor)
        let edit = try XCTUnwrap(harness.editor.submitted.last)
        XCTAssertEqual(harness.editor.applyCount, 1)
        XCTAssertEqual(edit.result.replacementRange, NSRange(location: 0, length: 3))
        XCTAssertEqual(edit.result.replacementString, "ONE")
        XCTAssertEqual(edit.undoActionName, "Replace")
        XCTAssertEqual(harness.editor.text, "ONE two one")
    }

    @MainActor
    func testGuardRejectionLeavesSource() throws {
        let harness = AuthoringHarness(text: "one two", selection: NSRange(location: 0, length: 3))
        prepareSearch(harness, query: "one", replacement: "ONE")
        let session = try XCTUnwrap(harness.controller.find.session)
        harness.editor.beforeApply = { harness.editor.selectionGeneration += 2 }
        harness.controller.perform(.singleReplace, using: harness.editor)
        XCTAssertEqual(harness.editor.applyCount, 1)
        XCTAssertEqual(harness.editor.outcomes.last, .refused(.selectionChanged))
        XCTAssertEqual(harness.editor.text, "one two")
        XCTAssertEqual(harness.editor.undoCount, 0)
        XCTAssertEqual(harness.controller.find.session, session)
    }

    @MainActor
    func testEmptyReplacementDeletesMatch() throws {
        let harness = AuthoringHarness(text: "one two", selection: NSRange(location: 0, length: 3))
        prepareSearch(harness, query: "one", replacement: "")
        XCTAssertEqual(EditorReplacePlanning.validateReplacement(""), .valid)
        harness.controller.perform(.singleReplace, using: harness.editor)
        let edit = try XCTUnwrap(harness.editor.submitted.last)
        XCTAssertEqual(harness.editor.applyCount, 1)
        XCTAssertEqual(edit.result.replacementRange, NSRange(location: 0, length: 3))
        XCTAssertEqual(edit.result.replacementString, "")
        XCTAssertEqual(harness.editor.text, " two")
    }

    @MainActor
    func testLiteralIdenticalDoesNotEdit() throws {
        let text = "one one"
        let harness = AuthoringHarness(text: text, selection: NSRange(location: 0, length: 3))
        prepareSearch(harness, query: "one", replacement: "one")
        let session = try XCTUnwrap(harness.controller.find.session)
        let plan = try EditorReplacePlanner.planOneMatch(
            session: session,
            source: text,
            replacement: "one"
        ).get()
        XCTAssertTrue(plan.isLiteralIdentical)
        let expected = EditorReplaceContinuationPlanning.afterLiteralIdentical(plan: plan, session: session)
        harness.controller.perform(.singleReplace, using: harness.editor)
        XCTAssertEqual(harness.editor.applyCount, 0)
        XCTAssertEqual(harness.editor.undoCount, 0)
        XCTAssertEqual(harness.controller.find.session, expected.session)
        XCTAssertEqual(harness.editor.revealCalls.last?.range, expected.session.currentMatch?.range)
        XCTAssertEqual(harness.editor.text, text)
    }

    @MainActor
    func testOneRealEditRescansWithoutWrapping() {
        let harness = AuthoringHarness(text: "one", selection: NSRange(location: 0, length: 3))
        prepareSearch(harness, query: "one", replacement: "two")
        harness.controller.perform(.singleReplace, using: harness.editor)
        XCTAssertEqual(harness.editor.applyCount, 1)
        XCTAssertEqual(harness.editor.text, "two")
        XCTAssertNil(harness.controller.find.session?.currentOrdinal)
        XCTAssertEqual(harness.editor.revealCalls.count, 0)
    }

    @MainActor
    func testFollowingMatchBecomesCurrent() throws {
        let harness = AuthoringHarness(text: "one one", selection: NSRange(location: 0, length: 3))
        prepareSearch(harness, query: "one", replacement: "two")
        harness.controller.perform(.singleReplace, using: harness.editor)
        XCTAssertEqual(harness.editor.text, "two one")
        let current = try XCTUnwrap(harness.controller.find.session?.currentMatch)
        XCTAssertEqual(current.range, NSRange(location: 4, length: 3))
        XCTAssertNotNil(harness.controller.find.session?.currentOrdinal)
    }

    @MainActor
    func testNextStillWrapsAfterUnresolvedCurrent() throws {
        let text = "one one"
        let harness = AuthoringHarness(text: text)
        prepareSearch(harness, query: "one", replacement: "two")
        let session = try XCTUnwrap(harness.controller.find.session)
        let second = try XCTUnwrap(session.matches.last)
        harness.controller.find.session = session.withCurrentOrdinal(2, caretAnchorUTF16: second.range.location)
        harness.editor.selection = second.range
        harness.controller.perform(.singleReplace, using: harness.editor)
        XCTAssertEqual(harness.editor.text, "one two")
        XCTAssertNil(harness.controller.find.session?.currentOrdinal)
        XCTAssertFalse(harness.controller.find.session?.matches.isEmpty ?? true)
        harness.controller.perform(.nextMatch, using: harness.editor)
        XCTAssertEqual(harness.controller.find.session?.currentOrdinal, 1)
    }

    @MainActor
    func testReplacement256Accepted() {
        let accepted = String(repeating: "z", count: 256)
        let rejected = String(repeating: "z", count: 257)
        let harness = AuthoringHarness(text: "one", selection: NSRange(location: 0, length: 3))
        prepareSearch(harness, query: "one", replacement: accepted)
        harness.controller.perform(.singleReplace, using: harness.editor)
        XCTAssertEqual(harness.editor.applyCount, 1)
        XCTAssertEqual(harness.editor.text, accepted)

        let refusal = AuthoringHarness(text: "one", selection: NSRange(location: 0, length: 3))
        prepareSearch(refusal, query: "one", replacement: rejected)
        XCTAssertEqual(
            EditorReplacePlanning.validateReplacement(rejected),
            .exceedsMaximumUTF16Length
        )
        refusal.controller.perform(.singleReplace, using: refusal.editor)
        XCTAssertEqual(refusal.editor.applyCount, 0)
        XCTAssertEqual(refusal.editor.text, "one")
        XCTAssertFalse(refusal.controller.statusMessage.isEmpty)
    }

    @MainActor
    func testReplacementNewlineRefuses() {
        let harness = AuthoringHarness(text: "one", selection: NSRange(location: 0, length: 3))
        prepareSearch(harness, query: "one", replacement: "a\nb")
        XCTAssertEqual(EditorReplacePlanning.validateReplacement("a\nb"), .containsNewline)
        harness.controller.perform(.singleReplace, using: harness.editor)
        XCTAssertEqual(harness.editor.applyCount, 0)
        XCTAssertEqual(harness.editor.undoCount, 0)
        XCTAssertEqual(harness.editor.text, "one")
        XCTAssertFalse(harness.controller.statusMessage.isEmpty)
    }

    @MainActor
    func testTruncatedSessionReplacesRetainedCurrentMatch() throws {
        let text = String(repeating: "x", count: 10001)
        let harness = AuthoringHarness(text: text, selection: NSRange(location: 0, length: 1))
        prepareSearch(harness, query: "x", replacement: "y")
        let session = try XCTUnwrap(harness.controller.find.session)
        XCTAssertTrue(harness.controller.find.counterText.contains("10,000+"))
        XCTAssertEqual(
            EditorReplacePlanner.planBatch(session: session, source: text, replacement: "y"),
            .failure(.truncatedSession)
        )
        let planned = EditorReplacePlanner.planOneMatch(session: session, source: text, replacement: "y")
        guard case .success = planned else {
            XCTFail("planOneMatch should accept the retained current match")
            return
        }
        harness.controller.perform(.singleReplace, using: harness.editor)
        XCTAssertEqual(harness.editor.applyCount, 1)
        XCTAssertEqual(harness.editor.submitted.last?.result.replacementRange, session.currentMatch?.range)
    }

    @MainActor
    func testQueryLengthIsNotMatchLength() throws {
        let source = "e\u{0301}"
        let query = "\u{00e9}"
        let harness = AuthoringHarness(text: source)
        harness.controller.setFindCase(.sensitive, using: harness.editor)
        harness.controller.setFindQuery(query, using: harness.editor)
        harness.scheduler.finishLatest()
        let match = try XCTUnwrap(harness.controller.find.session?.currentMatch)
        harness.editor.selection = match.range
        harness.controller.setReplacement("Q")
        harness.controller.perform(.singleReplace, using: harness.editor)
        let edit = try XCTUnwrap(harness.editor.submitted.last)
        XCTAssertEqual(edit.result.replacementRange.length, match.range.length)
        XCTAssertNotEqual(edit.result.replacementRange.length, (query as NSString).length)
        XCTAssertEqual(harness.editor.applyCount, 1)
    }

    @MainActor
    func testMarkedTextSkipsRevealOnSelectOnlyReplace() {
        let harness = AuthoringHarness(text: "one two", selection: NSRange(location: 4, length: 3))
        prepareSearch(harness, query: "one", replacement: "ONE")
        harness.editor.hasMarkedText = true
        harness.controller.perform(.singleReplace, using: harness.editor)
        XCTAssertEqual(harness.editor.revealCalls.count, 0)
        XCTAssertEqual(harness.editor.applyCount, 0)
        XCTAssertEqual(harness.editor.text, "one two")
    }

    @MainActor
    private func prepareSearch(_ harness: AuthoringHarness, query: String, replacement: String) {
        harness.controller.setFindQuery(query, using: harness.editor)
        harness.scheduler.finishLatest()
        harness.controller.setReplacement(replacement)
    }
}
