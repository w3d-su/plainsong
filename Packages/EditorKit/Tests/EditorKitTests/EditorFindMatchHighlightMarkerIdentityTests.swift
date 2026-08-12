import AppKit
@testable import EditorKit
import XCTest

@MainActor
final class FindHighlightMarkerIdentityTests: XCTestCase {
    func testAdjacentOtherMatchesRestoreEachDistinctCoveredBackgroundAfterClear() throws {
        let source = "a `aa`"
        let text = source as NSString
        let first = text.range(of: "a")
        let inlinePair = text.range(of: "aa")
        let firstInline = NSRange(location: inlinePair.location, length: 1)
        let secondInline = NSRange(location: inlinePair.location + 1, length: 1)
        let storage = NSTextStorage(string: source)
        let firstBackground = NSColor.systemTeal
        let secondBackground = NSColor.systemOrange
        storage.addAttribute(.backgroundColor, value: firstBackground, range: firstInline)
        storage.addAttribute(.backgroundColor, value: secondBackground, range: secondInline)

        _ = EditorFindMatchHighlight.apply(
            EditorFindMatchHighlightRequest(
                generation: 1,
                matches: [first, firstInline, secondInline],
                currentIndex: 0
            ),
            visibleRange: NSRange(location: 0, length: storage.length),
            previouslyDecorated: nil,
            to: storage
        )

        let firstMarker = try XCTUnwrap(marker(in: storage, at: firstInline.location))
        let secondMarker = try XCTUnwrap(marker(in: storage, at: secondInline.location))
        XCTAssertFalse(
            firstMarker === secondMarker,
            "adjacent matches need distinct marker identity so NSTextStorage cannot merge their restoration metadata"
        )

        EditorFindMatchHighlight.clear(in: storage)

        XCTAssertEqual(
            storage.attribute(.backgroundColor, at: firstInline.location, effectiveRange: nil) as? NSColor,
            firstBackground
        )
        XCTAssertEqual(
            storage.attribute(.backgroundColor, at: secondInline.location, effectiveRange: nil) as? NSColor,
            secondBackground
        )
    }

    private func marker(
        in storage: NSTextStorage,
        at location: Int
    ) -> EditorFindMatchHighlightMarker? {
        storage.attribute(
            EditorFindMatchHighlightMarker.attribute,
            at: location,
            effectiveRange: nil
        ) as? EditorFindMatchHighlightMarker
    }
}
