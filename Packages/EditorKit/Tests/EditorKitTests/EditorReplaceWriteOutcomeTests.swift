import AppKit
@testable import EditorKit
import MarkdownCore
import STTextView
import XCTest

/// PR D review: the outcome is derived from the observed post-write snapshot,
/// and a Replace stays its own undo step when typing follows it.
@MainActor
final class EditorReplaceWriteOutcomeTests: XCTestCase {
    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testRefusedNativeInsertionIsNotReportedAsReplaced() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "one two", pattern: "one")
        let refusing = RefusingTextDelegate()
        ready.fixture.textView.textDelegate = refusing
        let outcome = EditorReplaceSingleSupport.perform(ready, replacement: "ONE")

        XCTAssertEqual(outcome, .refused(.writeNotApplied))
        XCTAssertEqual(refusing.refusals, 1)
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: ready.fixture.textView), "one two")
        XCTAssertEqual(ready.fixture.model.revision, 0)
        XCTAssertEqual(ready.fixture.model.publications, [])
        XCTAssertFalse(ready.fixture.textView.undoManager?.canUndo == true)
        assertFindUntouched(ready)
    }

    func testRejectedPublicationIsNotReportedAsReplaced() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "one two", pattern: "one")
        EditorReplaceSingleSupport.routePublicationsToFind(ready)
        ready.fixture.model.rejectsPublications = true
        let outcome = EditorReplaceSingleSupport.perform(ready, replacement: "ONE")

        XCTAssertEqual(outcome, .refused(.writeNotApplied))
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: ready.fixture.textView), "one two")
        XCTAssertEqual(ready.fixture.model.source, "one two")
        XCTAssertEqual(ready.fixture.model.revision, 0)
        assertFindUntouched(ready)
    }

    /// App advances one revision per accepted publication, but success is the
    /// exact planned source at a newer revision, not a particular delta.
    func testNonUnitRevisionAdvanceStillAdmitsOneReplacementRescan() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "a a", pattern: "a")
        EditorReplaceSingleSupport.routePublicationsToFind(ready)
        ready.fixture.model.revisionStep = 2
        let outcome = EditorReplaceSingleSupport.perform(ready, replacement: "aa")

        guard case .replaced = outcome else {
            return XCTFail("Expected a source change, got \(outcome)")
        }
        XCTAssertEqual(ready.fixture.model.revision, 2)
        XCTAssertEqual(ready.controller.documentBinding.revision, 2)
        XCTAssertEqual(ready.controller.recordedReplacementPublicationCount, 1)
        XCTAssertEqual(ready.controller.replacementScheduleCount, 1)
        XCTAssertEqual(ready.controller.editScheduleCount, 0)
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            ready.controller.session?.currentOrdinal == 3
        }
        XCTAssertEqual(ready.controller.replacementEngineInvocationCount, 1)
        XCTAssertEqual(ready.controller.editScheduleCount, 0)
    }

    /// A reconciled publication changed the source, but not into the planned
    /// text: no continuation, and Find recomputes it once as an ordinary edit.
    func testReconciledPublicationIsAnUnverifiedWriteAndAnOrdinaryEdit() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "one two", pattern: "one")
        EditorReplaceSingleSupport.routePublicationsToFind(ready)
        ready.fixture.model.reconcilesPublication = { $0 + " three" }
        let outcome = EditorReplaceSingleSupport.perform(ready, replacement: "ONE")

        XCTAssertEqual(outcome, .unverifiedWrite)
        XCTAssertEqual(ready.fixture.model.source, "ONE two three")
        XCTAssertEqual(ready.controller.documentBinding.text, "ONE two three")
        XCTAssertEqual(ready.controller.recordedReplacementPublicationCount, 1)
        XCTAssertEqual(ready.controller.replacementScheduleCount, 0)
        XCTAssertEqual(ready.controller.replacementEngineInvocationCount, 0)
        XCTAssertEqual(ready.controller.editScheduleCount, 1)
        XCTAssertNil(ready.controller.pendingNavigationCommand)
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            ready.controller.session != nil
        }
        XCTAssertEqual(ready.controller.editScheduleCount, 1)
        XCTAssertNil(ready.controller.pendingNavigationCommand)
    }

    /// Typing after Replace starts its own undo group: one Undo removes only the
    /// typed character. STTextView ends coalescing for a non-key-event insert.
    func testTypingAfterReplaceIsASeparateUndoStep() async throws {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: "one two", pattern: "one")
        let textView = ready.fixture.textView
        let outcome = EditorReplaceSingleSupport.perform(ready, replacement: "ONE")
        guard case .replaced = outcome else {
            return XCTFail("Expected a source change, got \(outcome)")
        }
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 0))

        try typeKey("x", in: textView)
        try typeKey("y", in: textView)
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: textView), "ONExy two")

        textView.undoManager?.undo()
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: textView), "ONE two")
        XCTAssertEqual(ready.fixture.model.source, "ONE two")

        textView.undoManager?.undo()
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: textView), "one two")
        XCTAssertEqual(ready.fixture.model.source, "one two")
    }

    // MARK: - Helpers

    private func assertFindUntouched(
        _ ready: EditorReplaceSingleSupport.Ready,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(ready.controller.session, ready.session, file: file, line: line)
        XCTAssertEqual(ready.controller.documentBinding.revision, 0, file: file, line: line)
        XCTAssertEqual(ready.controller.replacementScheduleCount, 0, file: file, line: line)
        XCTAssertEqual(ready.controller.replacementEngineInvocationCount, 0, file: file, line: line)
        XCTAssertEqual(ready.controller.editScheduleCount, 0, file: file, line: line)
    }

    /// A real key event, so STTextView treats the insert as typing and coalesces it.
    private func typeKey(_ character: String, in textView: STTextView) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: textView.window?.windowNumber ?? 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 7
        ))
        textView.keyDown(with: event)
    }
}

private final class RefusingTextDelegate: STTextViewDelegate {
    var refusals = 0

    func textView(
        _: STTextView,
        shouldChangeTextIn _: NSTextRange,
        replacementString _: String?
    ) -> Bool {
        refusals += 1
        return false
    }
}
