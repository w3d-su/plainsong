import Foundation
import MarkdownCore
@testable import PlainsongIOS
import XCTest

final class IOSFindGenerationTests: XCTestCase {
    @MainActor
    func testHandlerReturnsBeforeSearchStarts() {
        let harness = AuthoringHarness(text: "hello")
        harness.controller.find.queryText = "hello"
        harness.controller.perform(.find, using: harness.editor)
        XCTAssertEqual(harness.scheduler.startedCount, 0)
        XCTAssertEqual(harness.scheduler.pendingCount, 1)
        XCTAssertEqual(harness.controller.find.status, .searching)
        harness.scheduler.finishLatest()
        XCTAssertEqual(harness.scheduler.startedCount, 1)
        XCTAssertEqual(harness.controller.find.status, .matches)
        XCTAssertEqual(harness.editor.revealCalls.count, 0)
    }

    @MainActor
    func testStaleQueryGenerationDropped() {
        let harness = AuthoringHarness(text: "one two")
        harness.controller.setFindQuery("one", using: harness.editor)
        harness.controller.setFindQuery("two", using: harness.editor)
        harness.controller.setFindQuery("three", using: harness.editor)
        XCTAssertEqual(harness.scheduler.pendingCount, 1)
        harness.scheduler.finishLatest()
        XCTAssertEqual(harness.controller.find.session?.query.pattern, "three")
        harness.scheduler.finishDiscarded()
        XCTAssertEqual(harness.controller.find.session?.query.pattern, "three")
        XCTAssertEqual(harness.controller.find.status, .noResults)
    }

    @MainActor
    func testStaleSourceRevisionDropped() {
        let harness = AuthoringHarness(text: "hello", version: 5)
        harness.controller.setFindQuery("hello", using: harness.editor)
        harness.editor.version = 6
        harness.scheduler.finishLatest()
        XCTAssertNil(harness.controller.find.session)
        XCTAssertNotEqual(harness.controller.find.status, .matches)
        XCTAssertEqual(harness.controller.find.counterText, "")
        XCTAssertEqual(harness.controller.find.pendingSteps, 0)
    }

    @MainActor
    func testSameVersionOtherDocumentDropped() {
        let harness = AuthoringHarness(text: "hello", version: 5)
        harness.controller.setFindQuery("hello", using: harness.editor)
        harness.editor.identity = IOSDocumentIdentity(rawValue: UUID())
        harness.editor.version = 5
        let counter = harness.controller.find.counterText
        harness.scheduler.finishLatest()
        XCTAssertNil(harness.controller.find.session)
        XCTAssertEqual(harness.controller.find.counterText, counter)
        XCTAssertNotEqual(harness.controller.find.status, .matches)
        XCTAssertEqual(harness.editor.text, "hello")
    }

    @MainActor
    func testOnlyLatestPendingSearchIsRetained() {
        let harness = AuthoringHarness(text: "alpha beta gamma")
        harness.controller.setFindQuery("alpha", using: harness.editor)
        harness.controller.setFindQuery("beta", using: harness.editor)
        harness.controller.setFindQuery("gamma", using: harness.editor)
        XCTAssertEqual(harness.scheduler.pendingCount, 1)
        harness.scheduler.finishDiscarded()
        XCTAssertNil(harness.controller.find.session)
        XCTAssertEqual(harness.controller.find.status, .searching)
        harness.scheduler.finishLatest()
        XCTAssertEqual(harness.controller.find.session?.query.pattern, "gamma")
    }

    @MainActor
    func testRapidNextUsesSteppedByThree() throws {
        let text = "one one one one"
        let harness = AuthoringHarness(text: text)
        harness.controller.setFindQuery("one", using: harness.editor)
        XCTAssertEqual(harness.controller.find.status, .searching)
        harness.controller.perform(.nextMatch, using: harness.editor)
        harness.controller.perform(.nextMatch, using: harness.editor)
        harness.controller.perform(.nextMatch, using: harness.editor)
        XCTAssertEqual(harness.controller.find.pendingSteps, 3)
        harness.scheduler.finishLatest()
        let base = EditorFindSession.search(
            in: text,
            query: TextSearchQuery(pattern: "one"),
            caretAnchorUTF16: 0
        )
        XCTAssertEqual(harness.controller.find.session?.currentOrdinal, base.stepped(by: 3).currentOrdinal)
        let reveal = try XCTUnwrap(harness.editor.revealCalls.last)
        XCTAssertEqual(reveal.range, harness.controller.find.session?.currentMatch?.range)
    }

    @MainActor
    func testStepsResetWhenQueryChanges() {
        let harness = AuthoringHarness(text: "one two")
        harness.controller.setFindQuery("one", using: harness.editor)
        harness.controller.perform(.nextMatch, using: harness.editor)
        harness.controller.perform(.nextMatch, using: harness.editor)
        harness.controller.perform(.nextMatch, using: harness.editor)
        XCTAssertEqual(harness.controller.find.pendingSteps, 3)
        let generation = harness.controller.find.queryGeneration
        harness.controller.setFindQuery("two", using: harness.editor)
        XCTAssertEqual(harness.controller.find.pendingSteps, 0)
        XCTAssertGreaterThan(harness.controller.find.queryGeneration, generation)
    }

    @MainActor
    func testEmptyQueryIsDistinctFromNoResults() {
        let harness = AuthoringHarness(text: "hello")
        harness.controller.setFindQuery("", using: harness.editor)
        XCTAssertEqual(harness.controller.find.status, .empty)
        XCTAssertEqual(harness.controller.find.counterText, "")
        XCTAssertNil(harness.controller.find.session)
        XCTAssertNotEqual(harness.controller.find.status, .noResults)
        XCTAssertNotEqual(harness.controller.find.status, .invalid)
        XCTAssertEqual(harness.scheduler.pendingCount, 0)
    }

    @MainActor
    func testNewlineIsInvalid() {
        let harness = AuthoringHarness(text: "hello")
        harness.controller.setFindQuery("a\nb", using: harness.editor)
        XCTAssertEqual(harness.controller.find.status, .invalid)
        XCTAssertNil(harness.controller.find.session)
        XCTAssertEqual(harness.controller.find.message, IOSFindQuery.invalidMessage)
        XCTAssertNotEqual(harness.controller.find.status, .noResults)
        XCTAssertEqual(harness.scheduler.pendingCount, 0)
    }

    @MainActor
    func testPattern257IsInvalidAnd256IsSearchable() {
        let harness = AuthoringHarness(text: String(repeating: "a", count: 256))
        harness.controller.setFindQuery(String(repeating: "a", count: 257), using: harness.editor)
        XCTAssertEqual(harness.controller.find.status, .invalid)
        XCTAssertEqual(harness.scheduler.pendingCount, 0)
        harness.controller.setFindQuery(String(repeating: "a", count: 256), using: harness.editor)
        XCTAssertEqual(harness.controller.find.status, .searching)
        XCTAssertEqual(harness.scheduler.pendingCount, 1)
    }

    @MainActor
    func testNoResultsUsesValidQuery() {
        let harness = AuthoringHarness(text: "hello")
        harness.controller.setFindQuery("zzz", using: harness.editor)
        harness.scheduler.finishLatest()
        XCTAssertEqual(harness.controller.find.status, .noResults)
        XCTAssertEqual(harness.controller.find.message, IOSFindQuery.noResultsMessage)
        XCTAssertNotEqual(harness.controller.find.status, .invalid)
        XCTAssertEqual(harness.controller.find.session?.total, 0)
        XCTAssertEqual(harness.controller.find.session?.isTruncated, false)
    }

    @MainActor
    func testCanonicalEquivalenceRevealUsesActualRange() throws {
        let source = "e\u{0301}"
        let query = "\u{00e9}"
        let harness = AuthoringHarness(text: source)
        harness.controller.setFindCase(.sensitive, using: harness.editor)
        harness.controller.setFindQuery(query, using: harness.editor)
        harness.scheduler.finishLatest()
        harness.controller.perform(.nextMatch, using: harness.editor)
        let match = try XCTUnwrap(harness.controller.find.session?.currentMatch)
        let reveal = try XCTUnwrap(harness.editor.revealCalls.last)
        XCTAssertEqual(match.range.length, 2)
        XCTAssertEqual(reveal.range.length, match.range.length)
        XCTAssertNotEqual(reveal.range.length, (query as NSString).length)
    }

    @MainActor
    func testCaseFoldLengthUsesActualRange() throws {
        let harness = AuthoringHarness(text: "SS")
        harness.controller.setFindCase(.insensitive, using: harness.editor)
        harness.controller.setFindQuery("ß", using: harness.editor)
        harness.scheduler.finishLatest()
        harness.controller.perform(.nextMatch, using: harness.editor)
        let match = try XCTUnwrap(harness.controller.find.session?.currentMatch)
        let reveal = try XCTUnwrap(harness.editor.revealCalls.last)
        XCTAssertEqual(reveal.range.length, match.range.length)
    }

    @MainActor
    func testFindFieldFocusKeepsEditorSelection() {
        let selection = NSRange(location: 1, length: 2)
        let harness = AuthoringHarness(text: "hello", selection: selection)
        harness.controller.noteFindFieldFocused(using: harness.editor)
        harness.controller.setFindQuery("zzz", using: harness.editor)
        XCTAssertEqual(harness.controller.find.editorSelection, selection)
        XCTAssertEqual(harness.editor.selection, selection)
        XCTAssertTrue(harness.controller.find.hasEditorSelection)
        XCTAssertEqual(harness.controller.find.queryText, "zzz")
    }

    @MainActor
    func testUseSelectionAdoptsBoundedEditorText() {
        let harness = AuthoringHarness(text: "xxhitxx", selection: NSRange(location: 2, length: 3))
        harness.controller.perform(.useSelectionForFind, using: harness.editor)
        XCTAssertEqual(harness.controller.find.queryText, "hit")
        XCTAssertEqual(harness.controller.find.pendingSteps, 0)
        harness.scheduler.finishLatest()
        XCTAssertEqual(harness.editor.revealCalls.count, 0)
        XCTAssertEqual(harness.controller.find.pendingSteps, 0)
        XCTAssertEqual(harness.scheduler.startedCount, 1)
    }

    @MainActor
    func testUseSelectionIgnoresNewlineAndOverlongSelection() {
        let newline = AuthoringHarness(text: "a\nb", selection: NSRange(location: 0, length: 3))
        newline.controller.find.queryText = "keep"
        newline.controller.perform(.useSelectionForFind, using: newline.editor)
        XCTAssertEqual(newline.controller.find.queryText, "keep")
        XCTAssertEqual(newline.scheduler.pendingCount, 0)

        let overlong = String(repeating: "a", count: 257)
        let harness = AuthoringHarness(text: overlong, selection: NSRange(location: 0, length: 257))
        harness.controller.find.queryText = "keep"
        harness.controller.perform(.useSelectionForFind, using: harness.editor)
        XCTAssertEqual(harness.controller.find.queryText, "keep")
        XCTAssertEqual(harness.scheduler.pendingCount, 0)
    }

    @MainActor
    func testTruncatedCountRendersTenThousandPlus() throws {
        let text = String(repeating: "x", count: 10001)
        let harness = AuthoringHarness(text: text)
        harness.controller.setFindQuery("x", using: harness.editor)
        XCTAssertEqual(harness.scheduler.pendingCount, 1)
        harness.scheduler.finishLatest()
        let session = try XCTUnwrap(harness.controller.find.session)
        XCTAssertEqual(session.total, 10000)
        XCTAssertTrue(session.isTruncated)
        XCTAssertEqual(session.matches.count, EditorFindLimits.retainedMatchCeiling)
        XCTAssertTrue(harness.controller.find.counterText.contains("10,000+"))
        XCTAssertEqual(harness.scheduler.startedCount, 1)
    }
}
