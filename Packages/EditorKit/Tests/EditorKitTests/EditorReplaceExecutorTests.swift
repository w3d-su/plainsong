import AppKit
@testable import EditorKit
import MarkdownCore
import XCTest

@MainActor
final class EditorReplaceExecutorTests: XCTestCase {
    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testSourceChangeIsOneUndoAndPreservesPriorTyping() async throws {
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: "one two")
        fixture.textView.insertText("!", replacementRange: NSRange(location: 7, length: 0))
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), "one two!")
        let typedRevision = try XCTUnwrap(
            fixture.coordinator.currentInstalledSourceSnapshot
        ).revision

        let controller = try await EditorReplaceSingleSupport.installController(
            on: fixture,
            source: "one two!",
            pattern: "one"
        )
        let session = try XCTUnwrap(controller.session)
        let outcome = fixture.coordinator.performSingleReplace(
            EditorReplaceSingleSupport.request(
                controller: controller,
                session: session,
                replacement: "ONE"
            ),
            authorization: .allowed(),
            controller: controller,
            in: fixture.textView
        )
        guard case .replaced = outcome else {
            return XCTFail("Expected a source change, got \(outcome)")
        }
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), "ONE two!")
        XCTAssertGreaterThan(
            fixture.coordinator.currentInstalledSourceSnapshot?.revision ?? 0,
            typedRevision
        )

        fixture.textView.undoManager?.undo()
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), "one two!")
        XCTAssertEqual(fixture.model.source, "one two!")

        fixture.textView.undoManager?.undo()
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), "one two")
        XCTAssertEqual(fixture.model.source, "one two")
        XCTAssertFalse(fixture.model.isDirty)
    }

    func testNotAppliedMatchNavigatesWithoutMutationOrQueue() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(
            source: "xx one two",
            pattern: "one",
            selection: NSRange(location: 0, length: 0)
        )
        let writers = ready.fixture.model.writerActivations
        let outcome = EditorReplaceSingleSupport.perform(ready, replacement: "ONE")

        let match = try XCTUnwrap(ready.session.currentMatch?.range)
        XCTAssertEqual(outcome, .navigatedToCurrentMatch(match))
        XCTAssertEqual(
            EditorReplaceBatchSpikeSupport.viewText(in: ready.fixture.textView),
            "xx one two"
        )
        XCTAssertEqual(ready.fixture.textView.selectedRange(), match)
        XCTAssertEqual(ready.fixture.model.writerActivations, writers)
        XCTAssertEqual(ready.fixture.model.revision, 0)
        XCTAssertFalse(ready.fixture.textView.undoManager?.canUndo == true)
        XCTAssertEqual(ready.controller.replacementScheduleCount, 0)
        guard case let .navigate(request)? = ready.controller.pendingNavigationCommand else {
            return XCTFail("Expected exact navigation")
        }
        XCTAssertEqual(request.selection, match)
        XCTAssertFalse(request.shouldFocusEditor)
    }

    func testMarkedTextRefusesBeforeAuthorization() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "one two", pattern: "one")
        ready.fixture.textView.setMarkedText(
            "ㄓ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(ready.fixture.textView.hasMarkedText())
        let calls = AuthCalls()
        let outcome = EditorReplaceSingleSupport.perform(
            ready,
            replacement: "ONE",
            authorization: EditorReplaceAuthorization { calls.bump() }
        )

        XCTAssertEqual(outcome, .refused(.markedText))
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(ready.fixture.model.writerActivations, 0)
        XCTAssertEqual(ready.fixture.model.publications, [])
        XCTAssertFalse(ready.fixture.textView.undoManager?.canUndo == true)
        XCTAssertEqual(ready.controller.replacementScheduleCount, 0)
        XCTAssertTrue(ready.fixture.textView.hasMarkedText())
    }

    func testAuthorizationRefusalHasZeroEffectBeforeWriterPreflight() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "one two", pattern: "one")
        let selection = ready.fixture.textView.selectedRange()
        let calls = AuthCalls()
        let outcome = EditorReplaceSingleSupport.perform(
            ready,
            replacement: "ONE",
            authorization: EditorReplaceAuthorization {
                calls.bump()
                return false
            }
        )

        XCTAssertEqual(outcome, .refused(.unauthorized))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(ready.fixture.model.writerActivations, 0)
        XCTAssertEqual(ready.fixture.model.publications, [])
        XCTAssertEqual(ready.fixture.model.revision, 0)
        XCTAssertEqual(ready.fixture.textView.selectedRange(), selection)
        XCTAssertEqual(ready.controller.session, ready.session)
        XCTAssertFalse(ready.fixture.textView.undoManager?.canUndo == true)
        XCTAssertEqual(ready.controller.replacementScheduleCount, 0)
        XCTAssertEqual(ready.controller.editScheduleCount, 0)
    }

    func testWYSIWYGWithoutAppliedModelRefusesWithZeroEffect() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(
            source: "**one** two",
            pattern: "one",
            enableWYSIWYG: true
        )
        XCTAssertNotNil(ready.fixture.textView.wysiwygZeroWidthContentStorageDelegate)
        let outcome = EditorReplaceSingleSupport.perform(ready, replacement: "ONE")

        XCTAssertEqual(outcome, .refused(.wysiwygRangeNotRevealed))
        XCTAssertEqual(
            EditorReplaceBatchSpikeSupport.viewText(in: ready.fixture.textView),
            "**one** two"
        )
        XCTAssertEqual(ready.fixture.model.writerActivations, 0)
        XCTAssertEqual(ready.fixture.model.publications, [])
        XCTAssertFalse(ready.fixture.textView.undoManager?.canUndo == true)
        XCTAssertEqual(ready.controller.replacementScheduleCount, 0)
    }

    func testLiteralIdenticalAdvancesWithoutWriterRevisionUndoOrRescan() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "one one", pattern: "one")
        let revision = ready.fixture.model.revision
        let outcome = EditorReplaceSingleSupport.perform(ready, replacement: "one")

        guard case let .advancedIdentical(continuation) = outcome else {
            return XCTFail("Expected an identical advance, got \(outcome)")
        }
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: ready.fixture.textView), "one one")
        XCTAssertEqual(ready.fixture.model.revision, revision)
        XCTAssertEqual(ready.fixture.model.writerActivations, 0)
        XCTAssertEqual(ready.fixture.model.publications, [])
        XCTAssertFalse(ready.fixture.textView.undoManager?.canUndo == true)
        XCTAssertEqual(ready.controller.replacementEngineInvocationCount, 0)
        XCTAssertEqual(ready.controller.replacementScheduleCount, 0)
        XCTAssertEqual(ready.controller.editScheduleCount, 0)
        let second = ("one one" as NSString).range(of: "one", options: [], range: NSRange(location: 1, length: 6))
        XCTAssertEqual(continuation.session.currentMatch?.range, second)
        XCTAssertEqual(ready.controller.session?.currentMatch?.range, second)
        XCTAssertEqual(ready.fixture.textView.selectedRange(), second)
        XCTAssertFalse(
            ready.controller.pendingNavigationCommand?.shouldFocusEditor ?? true
        )
    }

    func testLiteralIdenticalAtLastMatchCollapsesWithoutWrap() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "one", pattern: "one")
        let outcome = EditorReplaceSingleSupport.perform(ready, replacement: "one")

        guard case let .advancedIdentical(continuation) = outcome else {
            return XCTFail("Expected an identical advance, got \(outcome)")
        }
        XCTAssertNil(continuation.session.currentOrdinal)
        XCTAssertEqual(continuation.session.caretAnchorUTF16, 3)
        XCTAssertEqual(continuation.collapsedSelection, NSRange(location: 3, length: 0))
        XCTAssertEqual(ready.controller.caretAnchorUTF16, 3)
        XCTAssertEqual(ready.fixture.textView.selectedRange(), NSRange(location: 3, length: 0))
        XCTAssertEqual(ready.controller.replacementEngineInvocationCount, 0)
        XCTAssertEqual(ready.fixture.model.writerActivations, 0)
    }

    func testCanonicalDifferenceIsARealEdit() async throws {
        let nfd = "e\u{0301}"
        let nfc = "\u{00e9}"
        XCTAssertEqual(nfd, nfc)
        XCTAssertFalse(ExactSourceText.matches(nfd, nfc))
        let ready = try await EditorReplaceSingleSupport.makeReady(source: nfd + " tail", pattern: nfd)
        let outcome = EditorReplaceSingleSupport.perform(ready, replacement: nfc)
        guard case .replaced = outcome else {
            return XCTFail("Expected a source change, got \(outcome)")
        }
        XCTAssertEqual(
            EditorReplaceBatchSpikeSupport.viewText(in: ready.fixture.textView),
            nfc + " tail"
        )
        XCTAssertEqual(ready.fixture.model.writerActivations, 1)
        XCTAssertFalse(ExactSourceText.matches(ready.fixture.model.source, nfd + " tail"))
    }

    func testStaleWriterPreflightOpensNoReplacementUndo() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "one two", pattern: "one")
        ready.fixture.model.source = "current two"
        ready.fixture.model.revision += 1
        let outcome = EditorReplaceSingleSupport.perform(ready, replacement: "ONE")

        XCTAssertEqual(outcome, .refused(.writerPreflightFailed))
        XCTAssertEqual(
            EditorReplaceBatchSpikeSupport.viewText(in: ready.fixture.textView),
            "current two"
        )
        XCTAssertFalse(
            EditorReplaceBatchSpikeSupport.viewText(in: ready.fixture.textView).contains("ONE")
        )
        XCTAssertTrue(ready.fixture.model.publications.isEmpty)
        XCTAssertFalse(ready.fixture.textView.undoManager?.canUndo == true)
        XCTAssertEqual(ready.controller.replacementScheduleCount, 0)
        XCTAssertEqual(ready.controller.replacementEngineInvocationCount, 0)
    }

    func testStaleIdentityAndInvalidReplacementDoNotMutate() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "one two", pattern: "one")
        var stale = EditorReplaceSingleSupport.request(
            controller: ready.controller,
            session: ready.session,
            replacement: "ONE"
        )
        stale = EditorReplaceRequest(
            documentIdentity: EditorDocumentIdentity(rawValue: "other"),
            sourceRevision: stale.sourceRevision,
            queryGeneration: stale.queryGeneration,
            session: stale.session,
            replacement: stale.replacement
        )
        let identity = ready.fixture.coordinator.performSingleReplace(
            stale,
            authorization: .allowed(),
            controller: ready.controller,
            in: ready.fixture.textView
        )
        XCTAssertEqual(identity, .refused(.staleIdentity))

        let invalid = EditorReplaceSingleSupport.perform(ready, replacement: "a\nb")
        XCTAssertEqual(invalid, .refused(.invalidPlan(.invalidReplacement(.containsNewline))))
        XCTAssertEqual(ready.fixture.model.writerActivations, 0)
        XCTAssertEqual(ready.fixture.model.publications, [])
    }
}

private extension EditorNavigationCommand {
    var shouldFocusEditor: Bool? {
        guard case let .navigate(request) = self else { return nil }
        return request.shouldFocusEditor
    }
}

private final class AuthCalls: @unchecked Sendable {
    var count = 0
    @discardableResult
    func bump() -> Bool {
        count += 1
        return true
    }
}
