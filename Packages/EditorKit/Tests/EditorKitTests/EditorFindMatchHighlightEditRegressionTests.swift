import AppKit
@testable import EditorKit
import XCTest

@MainActor
final class FindHighlightEditRegressionTests: XCTestCase {
    func testClearingMarkerAfterInsertionInsideItRestoresInheritedSyntaxBackground() {
        let source = "needle"
        let target = NSRange(location: 0, length: (source as NSString).length)
        let storage = NSTextStorage(string: source)
        let syntaxBackground = NSColor.systemTeal
        storage.addAttribute(.backgroundColor, value: syntaxBackground, range: target)
        _ = EditorFindMatchHighlight.apply(
            EditorFindMatchHighlightRequest(generation: 1, matches: [target], currentIndex: 0),
            visibleRange: target,
            previouslyDecorated: nil,
            to: storage
        )

        storage.replaceCharacters(in: NSRange(location: 3, length: 0), with: "X")
        EditorFindMatchHighlight.clear(in: storage)

        XCTAssertEqual(storage.string, "neeXdle")
        for location in 0 ..< storage.length {
            XCTAssertEqual(
                storage.attribute(.backgroundColor, at: location, effectiveRange: nil) as? NSColor,
                syntaxBackground,
                "clearing must restore the inherited syntax background at offset \(location)"
            )
            XCTAssertNil(
                storage.attribute(
                    EditorFindMatchHighlightMarker.coveredBackgroundAttribute,
                    at: location,
                    effectiveRange: nil
                ),
                "private restoration provenance must not survive after find decoration clears"
            )
        }
    }

    func testClearingMarkerAfterDeletionInsideItKeepsDistinctBackgroundRunsAligned() {
        let source = "abcdef"
        let target = NSRange(location: 0, length: (source as NSString).length)
        let storage = NSTextStorage(string: source)
        let firstBackground = NSColor.systemTeal
        let secondBackground = NSColor.systemOrange
        storage.addAttribute(
            .backgroundColor,
            value: firstBackground,
            range: NSRange(location: 0, length: 3)
        )
        storage.addAttribute(
            .backgroundColor,
            value: secondBackground,
            range: NSRange(location: 3, length: 3)
        )
        _ = EditorFindMatchHighlight.apply(
            EditorFindMatchHighlightRequest(generation: 1, matches: [target], currentIndex: 0),
            visibleRange: target,
            previouslyDecorated: nil,
            to: storage
        )

        storage.replaceCharacters(in: NSRange(location: 1, length: 1), with: "")
        EditorFindMatchHighlight.clear(in: storage)

        XCTAssertEqual(storage.string, "acdef")
        let expectedBackgrounds = [
            firstBackground,
            firstBackground,
            secondBackground,
            secondBackground,
            secondBackground,
        ]
        for (location, expected) in expectedBackgrounds.enumerated() {
            XCTAssertEqual(
                storage.attribute(.backgroundColor, at: location, effectiveRange: nil) as? NSColor,
                expected,
                "background provenance must stay aligned at offset \(location)"
            )
            XCTAssertNil(
                storage.attribute(
                    EditorFindMatchHighlightMarker.coveredBackgroundAttribute,
                    at: location,
                    effectiveRange: nil
                )
            )
        }
    }
}
