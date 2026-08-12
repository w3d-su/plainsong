import AppKit
@testable import EditorKit
import XCTest

@MainActor
final class EditorReplaceBatchSpikeWYSIWYGTests: XCTestCase {
    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testMinimalEnclosingRangeUndoRestoresFoldPresentation() throws {
        let source = "**one** two **one**"
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(
            source: source,
            enableWYSIWYG: true
        )
        var presentationApplies = 0
        presentationApplies += EditorReplaceBatchSpikeSupport.applyPresentation(
            source,
            selection: NSRange(location: 0, length: 0),
            revision: 1,
            to: fixture.textView
        )

        let ranges = EditorReplaceBatchSpikeSupport.matchRanges(in: source, query: "one")
        XCTAssertEqual(ranges.count, 2)
        let result = fixture.coordinator.performReplaceBatchSpike(
            EditorReplaceBatchRequest(ranges: ranges, replacement: "ONE"),
            using: .minimalEnclosingRange,
            in: fixture.textView
        )
        XCTAssertTrue(result.applied)
        XCTAssertEqual(fixture.model.publications.count, 1)
        XCTAssertEqual(presentationApplies, 1)

        let replaced = EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView)
        XCTAssertEqual(replaced, "**ONE** two **ONE**")

        fixture.textView.undoManager?.undo()
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), source)
        XCTAssertEqual(fixture.model.source, source)

        presentationApplies += EditorReplaceBatchSpikeSupport.applyPresentation(
            source,
            selection: NSRange(location: 0, length: 0),
            revision: 2,
            to: fixture.textView
        )
        XCTAssertEqual(presentationApplies, 2)
    }
}
