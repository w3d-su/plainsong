import AppKit
@testable import EditorKit
import STTextView
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
        let outsideFolds = NSRange(location: 8, length: 0)
        EditorReplaceBatchSpikeSupport.applyPresentation(
            source,
            selection: outsideFolds,
            revision: 1,
            to: fixture.textView
        )
        assertFoldedDelimiters(in: fixture.textView, source: source, span: "**one**")

        let ranges = EditorReplaceBatchSpikeSupport.matchRanges(in: source, query: "one")
        XCTAssertEqual(ranges.count, 2)
        let result = fixture.coordinator.performReplaceBatchSpike(
            EditorReplaceBatchRequest(ranges: ranges, replacement: "ONE"),
            using: .minimalEnclosingRange,
            in: fixture.textView
        )
        XCTAssertTrue(result.applied)
        XCTAssertEqual(fixture.model.publications.count, 1)

        let replaced = EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView)
        XCTAssertEqual(replaced, "**ONE** two **ONE**")

        fixture.textView.undoManager?.undo()
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView), source)
        XCTAssertEqual(fixture.model.source, source)

        EditorReplaceBatchSpikeSupport.applyPresentation(
            source,
            selection: outsideFolds,
            revision: 2,
            to: fixture.textView
        )
        assertFoldedDelimiters(in: fixture.textView, source: source, span: "**one**")
    }

    private func assertFoldedDelimiters(
        in textView: STTextView,
        source: String,
        span: String
    ) {
        guard let textStorage = MarkdownTextView.textStorage(of: textView) else {
            XCTFail("Expected text storage")
            return
        }

        for delimiter in emphasisDelimiters(in: source, span: span) {
            let attributes = textStorage.attributes(at: delimiter.location, effectiveRange: nil)
            XCTAssertTrue(
                WYSIWYGInlineFoldPresentation.containsFoldedDelimiterAttributes(attributes),
                "Expected folded delimiter at \(delimiter)"
            )
        }
    }

    private func emphasisDelimiters(in source: String, span: String) -> [NSRange] {
        let nsSource = source as NSString
        let markerLength = 2
        var search = NSRange(location: 0, length: nsSource.length)
        var delimiters: [NSRange] = []
        while search.length > 0 {
            let found = nsSource.range(of: span, options: [], range: search)
            guard found.location != NSNotFound else { break }
            delimiters.append(NSRange(location: found.location, length: markerLength))
            delimiters.append(NSRange(
                location: NSMaxRange(found) - markerLength,
                length: markerLength
            ))
            let next = NSMaxRange(found)
            search = NSRange(location: next, length: nsSource.length - next)
        }
        return delimiters
    }
}
