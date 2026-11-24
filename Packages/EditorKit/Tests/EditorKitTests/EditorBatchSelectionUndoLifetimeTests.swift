import AppKit
@testable import EditorKit
import MarkdownCore
import XCTest

/// `UndoManager.registerUndo(withTarget:handler:)` keeps only an unowned reference to its
/// target. Nothing else retains `EditorReplaceBatchSelectionUndo`, so its handlers must
/// capture it; reading the handler's target parameter instead dereferences freed memory
/// (CI crashed casting an `_NSUndoEndMark` to the selection-undo type).
@MainActor
final class EditorBatchSelectionUndoLifetimeTests: XCTestCase {
    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testRegisteredSelectionUndoOutlivesItsCreatorUntilUndone() throws {
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: "cedar pine cedar")
        let manager = try XCTUnwrap(fixture.textView.undoManager)
        weak var registered: EditorReplaceBatchSelectionUndo?
        manager.beginUndoGrouping()
        autoreleasepool {
            let selectionUndo = EditorReplaceBatchSelectionUndo(textView: fixture.textView)
            registered = selectionUndo
            selectionUndo.register(
                priorSelection: NSRange(location: 6, length: 4),
                postSelection: NSRange(location: 0, length: 0)
            )
        }
        manager.endUndoGrouping()

        XCTAssertNotNil(registered, "the undo stack must keep the selection undo alive")
        manager.undo()
        XCTAssertNotNil(registered, "undo registers the redo action on the same object")
    }

    func testWYSIWYGReplaceAllFromNonMatchSelectionUndoesAndRedoesSelection() async throws {
        let source = "cedar pine cedar"
        let pine = NSRange(location: 6, length: 4)
        let ready = try await EditorReplaceSingleSupport.makeReady(
            source: source, pattern: "cedar", selection: pine, enableWYSIWYG: true
        )
        EditorReplaceSingleSupport.routePublicationsToFind(ready)
        let prepared = try EditorReplaceBatchProductSupport.prepare(ready, replacement: "spruce")
        let outcome = EditorReplaceBatchProductSupport.perform(
            ready, replacement: "spruce", prepared: prepared
        )

        XCTAssertEqual(outcome, .replaced(prepared.plan))
        XCTAssertEqual(ready.fixture.model.source, "spruce pine spruce")
        let manager = try XCTUnwrap(ready.fixture.textView.undoManager)
        manager.undo()
        XCTAssertEqual(ready.fixture.model.source, source)
        XCTAssertEqual(ready.fixture.textView.selectedRange(), pine)
        manager.redo()
        XCTAssertEqual(ready.fixture.model.source, "spruce pine spruce")
        XCTAssertEqual(ready.fixture.textView.selectedRange(), prepared.postSelection)
        manager.undo()
        XCTAssertEqual(ready.fixture.model.source, source)
        XCTAssertEqual(ready.fixture.textView.selectedRange(), pine)
    }
}
