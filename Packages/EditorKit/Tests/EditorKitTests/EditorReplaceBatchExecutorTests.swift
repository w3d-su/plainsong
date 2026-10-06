import AppKit
@testable import EditorKit
import MarkdownCore
import STTextView
import XCTest

@MainActor
final class EditorReplaceBatchExecutorTests: XCTestCase {
    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testProductB1OneEditPublicationUndoRedoAndPriorTypingSeparation() async throws {
        let original = "before one and one after"
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: original)
        fixture.textView.insertText("!", replacementRange: NSRange(location: original.utf16.count, length: 0))
        let source = original + "!"
        let priorSelection = NSRange(location: 2, length: 4)
        let controller = try await EditorReplaceSingleSupport.installController(
            on: fixture, source: source, pattern: "one", selection: priorSelection
        )
        let ready = try EditorReplaceSingleSupport.Ready(
            fixture: fixture, controller: controller, session: XCTUnwrap(controller.session)
        )
        EditorReplaceSingleSupport.routePublicationsToFind(ready)
        let prepared = try EditorReplaceBatchProductSupport.prepare(ready, replacement: "ONE")
        let initialWriters = fixture.model.writerActivations
        let initialPublications = fixture.model.publications.count
        let nativeChanges = NativeChanges()
        let observer = NotificationCenter.default.addObserver(
            forName: STTextView.textDidChangeNotification, object: fixture.textView, queue: nil
        ) { _ in nativeChanges.count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let outcome = EditorReplaceBatchProductSupport.perform(ready, replacement: "ONE", prepared: prepared)

        XCTAssertEqual(outcome, .replaced(prepared.plan))
        XCTAssertEqual(fixture.model.source, "before ONE and ONE after!")
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), prepared.expectedSource)
        XCTAssertEqual(fixture.model.writerActivations - initialWriters, 1)
        XCTAssertEqual(fixture.model.publications.count - initialPublications, 1)
        XCTAssertEqual(nativeChanges.count, 1)
        XCTAssertEqual(fixture.textView.selectedRange(), prepared.postSelection)
        XCTAssertEqual(controller.replacementScheduleCount, 1)
        XCTAssertEqual(controller.editScheduleCount, 0)

        fixture.textView.undoManager?.undo()
        XCTAssertEqual(fixture.model.source, source)
        XCTAssertEqual(fixture.textView.selectedRange(), priorSelection)
        XCTAssertTrue(fixture.model.isDirty)
        fixture.textView.undoManager?.redo()
        XCTAssertEqual(fixture.model.source, prepared.expectedSource)
        XCTAssertEqual(fixture.textView.selectedRange(), prepared.postSelection)
        fixture.textView.undoManager?.undo()
        fixture.textView.undoManager?.undo()
        XCTAssertEqual(fixture.model.source, original)
        XCTAssertFalse(fixture.model.isDirty)
    }

    func testNoChangesPreservesSourceSelectionOrdinalRevisionUndoAndRescan() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "one one", pattern: "one")
        let selection = ready.fixture.textView.selectedRange()
        let prepared = try EditorReplaceBatchProductSupport.prepare(ready, replacement: "one")
        let outcome = EditorReplaceBatchProductSupport.perform(ready, replacement: "one", prepared: prepared)

        XCTAssertEqual(outcome, .noChanges(prepared.plan))
        XCTAssertEqual(ready.controller.session, ready.session)
        XCTAssertEqual(ready.fixture.model.source, "one one")
        EditorReplaceBatchProductSupport.assertUnchanged(ready, selection: selection)
        XCTAssertEqual(ready.controller.replacementEngineInvocationCount, 0)
        XCTAssertEqual(ready.controller.editScheduleCount, 0)
    }

    func testCanonicalUnequalRangesAreChangedOnceAndInsertedQueryIsNotRecursive() async throws {
        let source = "é e\u{0301} é"
        let ready = try await EditorReplaceSingleSupport.makeReady(source: source, pattern: "é")
        EditorReplaceSingleSupport.routePublicationsToFind(ready)
        let replacement = "éé"
        let prepared = try EditorReplaceBatchProductSupport.prepare(ready, replacement: replacement)
        XCTAssertEqual(Set(prepared.plan.allRanges.map(\.length)), [1, 2])
        let outcome = EditorReplaceBatchProductSupport.perform(ready, replacement: replacement, prepared: prepared)

        XCTAssertEqual(outcome, .replaced(prepared.plan))
        XCTAssertTrue(ExactSourceText.matches(ready.fixture.model.source, "éé éé éé"))
        XCTAssertEqual(ready.fixture.model.publications.count, 1)
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { ready.controller.session?.total == 6 }
        XCTAssertNil(ready.controller.session?.currentOrdinal)
        XCTAssertEqual(ready.controller.session?.caretAnchorUTF16, prepared.postSelection.location)
        XCTAssertEqual(ready.controller.replacementEngineInvocationCount, 1)
        ready.fixture.textView.undoManager?.undo()
        XCTAssertTrue(ExactSourceText.matches(ready.fixture.model.source, source))
    }

    func testMixedIdenticalCountsAnd256UnitReplacement() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "é e\u{0301}", pattern: "é")
        let prepared = try EditorReplaceBatchProductSupport.prepare(ready, replacement: "é")
        XCTAssertEqual(prepared.plan.changedCount, 1)
        XCTAssertEqual(prepared.plan.totalCount, 2)
        XCTAssertEqual(
            EditorReplaceBatchProductSupport.perform(ready, replacement: "é", prepared: prepared),
            .replaced(prepared.plan)
        )
        let long = try await EditorReplaceSingleSupport.makeReady(source: "one one", pattern: "one")
        let replacement = String(repeating: "x", count: 256)
        let longPrepared = try EditorReplaceBatchProductSupport.prepare(long, replacement: replacement)
        XCTAssertEqual(
            EditorReplaceBatchProductSupport.perform(long, replacement: replacement, prepared: longPrepared),
            .replaced(longPrepared.plan)
        )
        XCTAssertEqual(long.fixture.model.source, replacement + " " + replacement)
        XCTAssertEqual(long.fixture.model.publications.count, 1)
    }

    func testFinalFenceRefusesBeforeWriterUndoOrPresentationSuspension() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(
            source: "**one** one", pattern: "one", enableWYSIWYG: true
        )
        let selection = ready.fixture.textView.selectedRange()
        let prepared = try EditorReplaceBatchProductSupport.prepare(ready, replacement: "ONE")
        let outcome = EditorReplaceBatchProductSupport.perform(
            ready, replacement: "ONE", prepared: prepared, recheck: { .superseded }
        )
        XCTAssertEqual(outcome, .refused(.superseded))
        EditorReplaceBatchProductSupport.assertUnchanged(ready, selection: selection)
    }

    func testMarkedTextAppearingAfterPreparationRefusesBeforeAuthorizationOrUndo() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "one one", pattern: "one")
        let prepared = try EditorReplaceBatchProductSupport.prepare(ready, replacement: "ONE")
        ready.fixture.textView.setMarkedText(
            "ㄓ", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let authorizations = AuthorizationCalls()
        let outcome = EditorReplaceBatchProductSupport.perform(
            ready, replacement: "ONE", prepared: prepared,
            authorization: EditorReplaceAuthorization { authorizations.count += 1; return true }
        )
        XCTAssertEqual(outcome, .refused(.markedText))
        XCTAssertEqual(authorizations.count, 0)
        XCTAssertEqual(ready.fixture.model.writerActivations, 0)
        XCTAssertEqual(ready.fixture.model.publications, [])
        XCTAssertFalse(ready.fixture.textView.undoManager?.canUndo == true)
    }

    func testAuthorizationRefusesBeforeWriterPreflight() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "one one", pattern: "one")
        let selection = ready.fixture.textView.selectedRange()
        let prepared = try EditorReplaceBatchProductSupport.prepare(ready, replacement: "ONE")
        XCTAssertEqual(
            EditorReplaceBatchProductSupport.perform(
                ready, replacement: "ONE", prepared: prepared, authorization: .refused()
            ),
            .refused(.unauthorized)
        )
        EditorReplaceBatchProductSupport.assertUnchanged(ready, selection: selection)
    }

    func testCommitDoesNotRecheckCancellationAfterWriterStarts() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "one one", pattern: "one")
        let prepared = try EditorReplaceBatchProductSupport.prepare(ready, replacement: "ONE")
        var acceptsPlan = true
        var finalChecks = 0
        ready.fixture.model.onAcceptedPublication = { _ in acceptsPlan = false }
        let outcome = EditorReplaceBatchProductSupport.perform(
            ready, replacement: "ONE", prepared: prepared,
            recheck: { finalChecks += 1; return acceptsPlan ? nil : .superseded }
        )
        XCTAssertEqual(outcome, .replaced(prepared.plan))
        XCTAssertEqual(finalChecks, 2)
        XCTAssertFalse(acceptsPlan)
        XCTAssertEqual(ready.fixture.model.source, "ONE ONE")
        XCTAssertEqual(ready.fixture.model.publications.count, 1)
    }

    func testRejectedWriteLeavesNoSelectionUndoAndPreservesPriorTyping() async throws {
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: "one one")
        fixture.textView.insertText("!", replacementRange: NSRange(location: 7, length: 0))
        let controller = try await EditorReplaceSingleSupport.installController(
            on: fixture, source: "one one!", pattern: "one"
        )
        let ready = try EditorReplaceSingleSupport.Ready(
            fixture: fixture, controller: controller, session: XCTUnwrap(controller.session)
        )
        let selection = fixture.textView.selectedRange()
        let prepared = try EditorReplaceBatchProductSupport.prepare(ready, replacement: "ONE")
        fixture.model.rejectsPublications = true
        XCTAssertEqual(
            EditorReplaceBatchProductSupport.perform(ready, replacement: "ONE", prepared: prepared),
            .refused(.writeNotApplied)
        )
        XCTAssertEqual(fixture.model.source, "one one!")
        XCTAssertEqual(fixture.textView.selectedRange(), selection)
        fixture.model.rejectsPublications = false
        fixture.textView.undoManager?.undo()
        XCTAssertEqual(fixture.model.source, "one one")
        XCTAssertFalse(fixture.model.isDirty)
    }
}

private final class NativeChanges: @unchecked Sendable { var count = 0 }
private final class AuthorizationCalls: @unchecked Sendable { var count = 0 }
