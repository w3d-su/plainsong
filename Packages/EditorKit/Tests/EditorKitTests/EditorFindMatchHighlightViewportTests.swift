import AppKit
@testable import EditorKit
import XCTest

@MainActor
final class EditorFindMatchHighlightViewportTests: XCTestCase {
    private let document = EditorDocumentIdentity(rawValue: "find-highlight-viewport-doc")

    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testOnlyMatchesNearTheViewportAreDecorated() throws {
        let filler = String(repeating: "x", count: 40000)
        let source = "needle " + filler + " needle"
        let text = source as NSString
        let near = text.range(of: "needle")
        let far = text.range(of: "needle", options: .backwards)
        let fixture = try makeFixture(source: source)
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))

        let decorated = EditorFindMatchHighlight.apply(
            EditorFindMatchHighlightRequest(generation: 1, matches: [near, far], currentIndex: 0),
            visibleRange: NSRange(location: 0, length: 200),
            previouslyDecorated: nil,
            to: storage
        )

        XCTAssertNotNil(marker(in: storage, at: near.location), "a match in the viewport is decorated")
        XCTAssertNil(
            marker(in: storage, at: far.location),
            "a match 40k characters away must not be materialised — that cost is the whole point"
        )
        XCTAssertEqual(decorated, near)
    }

    func testScrollingDecoratesTheNewRegionAndClearsTheOldOne() throws {
        let filler = String(repeating: "x", count: 40000)
        let source = "needle " + filler + " needle"
        let text = source as NSString
        let near = text.range(of: "needle")
        let far = text.range(of: "needle", options: .backwards)
        let fixture = try makeFixture(source: source)
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))
        let request = EditorFindMatchHighlightRequest(
            generation: 1,
            matches: [near, far],
            currentIndex: 0
        )

        let first = EditorFindMatchHighlight.apply(
            request,
            visibleRange: NSRange(location: 0, length: 200),
            previouslyDecorated: nil,
            to: storage
        )
        _ = EditorFindMatchHighlight.apply(
            request,
            visibleRange: NSRange(location: far.location - 100, length: 200),
            previouslyDecorated: first,
            to: storage
        )

        XCTAssertNotNil(marker(in: storage, at: far.location), "the match now on screen is decorated")
        XCTAssertNil(
            marker(in: storage, at: near.location),
            "the previously decorated region must be cleared, or decoration accumulates as the user scrolls"
        )
    }

    func testMaterialisationRangeRejectsOverflowingVisibleRanges() {
        XCTAssertEqual(
            EditorFindMatchHighlight.materialisationRange(
                for: NSRange(location: Int.max - 4, length: Int.max),
                storageLength: 100
            ),
            NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(
            EditorFindMatchHighlight.materialisationRange(
                for: NSRange(location: 50, length: Int.max),
                storageLength: 100
            ),
            NSRange(location: 0, length: 100)
        )
    }

    func testTrackedDecorationRangeFollowsLargeInsertionWithoutScanningTheGap() throws {
        let tracked = NSRange(location: 20, length: 6)
        let prefixLength = 1_000_000
        let shifted = try XCTUnwrap(EditorFindMatchHighlight.range(
            tracked,
            afterEditing: NSRange(location: 0, length: prefixLength),
            changeInLength: prefixLength,
            storageLength: prefixLength + 100
        ))
        XCTAssertEqual(shifted, NSRange(location: prefixLength + 20, length: 6))

        let storage = NSTextStorage(string: String(repeating: "x", count: prefixLength + 100))
        let scannedLength = EditorFindMatchHighlight.clear(
            in: storage,
            searching: [shifted, NSRange(location: 0, length: 2000)]
        )
        XCTAssertEqual(scannedLength, 2006)
    }

    private func makeFixture(source: String) throws -> EditorFindControllerTestSupport.WindowedFixture {
        let model = EditorFindControllerTestSupport.FindNavModel(
            text: source,
            selection: NSRange(location: 0, length: 0)
        )
        return try EditorFindControllerTestSupport.makeWindowedFixture(
            model: model,
            source: source,
            documentIdentity: document
        )
    }

    private func marker(
        in storage: NSTextStorage,
        at location: Int
    ) -> EditorFindMatchHighlightMarker? {
        guard location >= 0, location < storage.length else { return nil }
        return storage.attribute(
            EditorFindMatchHighlightMarker.attribute,
            at: location,
            effectiveRange: nil
        ) as? EditorFindMatchHighlightMarker
    }
}
