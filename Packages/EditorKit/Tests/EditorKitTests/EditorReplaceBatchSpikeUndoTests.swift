import AppKit
@testable import EditorKit
import XCTest

@MainActor
final class EditorReplaceBatchSpikeUndoTests: XCTestCase {
    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testMinimalEnclosingRangeIsOneUndoAndRedo() throws {
        try assertSingleUndoGroup(using: .minimalEnclosingRange)
    }

    func testFullDocumentIsOneUndoAndRedo() throws {
        try assertSingleUndoGroup(using: .fullDocument)
    }

    func testReverseOrderedEditsShareOneOuterUndoGroup() throws {
        try assertSingleUndoGroup(using: .reverseOrderedNativeEdits)
    }

    func testReplaceAllDoesNotMergeWithPriorTyping() throws {
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: "one two")
        fixture.textView.insertText("!", replacementRange: NSRange(location: 7, length: 0))
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), "one two!")
        XCTAssertTrue(fixture.textView.undoManager?.canUndo == true)

        let ranges = EditorReplaceBatchSpikeSupport.matchRanges(
            in: EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView),
            query: "one"
        )
        let result = fixture.coordinator.performReplaceBatchSpike(
            EditorReplaceBatchRequest(ranges: ranges, replacement: "ONE"),
            using: .minimalEnclosingRange,
            in: fixture.textView
        )
        XCTAssertTrue(result.applied)
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), "ONE two!")

        fixture.textView.undoManager?.undo()
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), "one two!")
        XCTAssertEqual(fixture.model.source, "one two!")

        fixture.textView.undoManager?.undo()
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), "one two")
        XCTAssertEqual(fixture.model.source, "one two")
        XCTAssertFalse(fixture.model.isDirty)
    }

    func testStaleWriterPreflightDoesNotOpenAReplacementUndoGroup() throws {
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: "one two one")
        fixture.model.source = "current two current"
        fixture.model.revision += 1

        let ranges = EditorReplaceBatchSpikeSupport.matchRanges(in: "one two one", query: "one")
        let result = fixture.coordinator.performReplaceBatchSpike(
            EditorReplaceBatchRequest(ranges: ranges, replacement: "ONE"),
            using: .minimalEnclosingRange,
            in: fixture.textView
        )

        XCTAssertFalse(result.applied)
        XCTAssertEqual(
            EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView),
            "current two current"
        )
        XCTAssertTrue(fixture.model.publications.isEmpty)
        XCTAssertFalse(fixture.textView.undoManager?.canUndo == true)
    }

    private func assertSingleUndoGroup(
        using mechanism: EditorReplaceBatchMechanism
    ) throws {
        let source = "one two one"
        let selection = NSRange(location: 4, length: 3)
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(
            source: source,
            selection: selection
        )
        let ranges = EditorReplaceBatchSpikeSupport.matchRanges(in: source, query: "one")
        let result = fixture.coordinator.performReplaceBatchSpike(
            EditorReplaceBatchRequest(
                ranges: ranges,
                replacement: "ONE",
                postSelection: NSRange(location: 3, length: 0)
            ),
            using: mechanism,
            in: fixture.textView
        )
        XCTAssertTrue(result.applied)
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), "ONE two ONE")
        XCTAssertTrue(fixture.model.isDirty)
        XCTAssertTrue(fixture.textView.undoManager?.canUndo == true)

        fixture.textView.undoManager?.undo()
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), source)
        XCTAssertEqual(fixture.model.source, source)
        XCTAssertEqual(fixture.textView.selectedRange(), selection)
        XCTAssertFalse(fixture.model.isDirty)
        XCTAssertFalse(fixture.textView.undoManager?.canUndo == true)
        XCTAssertTrue(fixture.textView.undoManager?.canRedo == true)

        fixture.textView.undoManager?.redo()
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), "ONE two ONE")
        XCTAssertEqual(fixture.model.source, "ONE two ONE")
        XCTAssertTrue(fixture.model.isDirty)
        XCTAssertFalse(fixture.textView.undoManager?.canRedo == true)
    }
}
