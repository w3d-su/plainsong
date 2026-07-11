import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// Native caret & selection gates for image thumbnails (I3). Copy/AX/undo live in the
/// `+CopyAXUndo` extension (I4/I7/I9). Mirrors `WYSIWYGLinkNativeGateTests`.
/// All coverage stays behind the internal `_developmentImageThumbnails` loader hook.
@MainActor
final class WYSIWYGImageThumbnailNativeGateTests: XCTestCase {
    // MARK: - I3 Caret & selection

    func testI3ArrowTraversalSnapsAcrossReadyThumbnailInBothDirections() async throws {
        let fixture = try Support.makeWindowedEditor()
        let imageRange = Support.imageRange
        _ = try await Support.waitForMarker(
            in: fixture.textView,
            range: imageRange,
            matching: { if case .ready = $0.visualState { true } else { false } }
        )
        _ = try Support.assertLiveAttachment(in: fixture.textView, imageRange: imageRange)

        fixture.textView.textSelection = NSRange(location: imageRange.location, length: 0)
        fixture.textView.moveRight(nil)
        XCTAssertEqual(
            fixture.textView.selectedRange(),
            NSRange(location: NSMaxRange(imageRange), length: 0)
        )
        XCTAssertNotNil(Support.imageMarker(in: fixture.textView, range: imageRange))

        fixture.textView.moveLeft(nil)
        XCTAssertEqual(
            fixture.textView.selectedRange(),
            NSRange(location: imageRange.location, length: 0)
        )
        XCTAssertEqual(Support.text(in: fixture.textView), Support.source)
    }

    func testI3ArrowTraversalSnapsAcrossPlaceholderInBothDirections() async throws {
        let fixture = try Support.makeWindowedEditor(
            outcomes: ["fixture.png": .failed(.missingFile)]
        )
        let imageRange = Support.imageRange
        _ = try await Support.waitForMarker(
            in: fixture.textView,
            range: imageRange,
            matching: { $0.visualState == .failed }
        )
        _ = try Support.assertLiveAttachment(in: fixture.textView, imageRange: imageRange)

        fixture.textView.textSelection = NSRange(location: imageRange.location, length: 0)
        fixture.textView.moveRight(nil)
        XCTAssertEqual(
            fixture.textView.selectedRange(),
            NSRange(location: NSMaxRange(imageRange), length: 0)
        )

        fixture.textView.moveLeft(nil)
        XCTAssertEqual(
            fixture.textView.selectedRange(),
            NSRange(location: imageRange.location, length: 0)
        )
    }

    func testI3InteriorCaretSnapsByTravelDirectionAndNearestOnClick() async throws {
        let imageRange = Support.imageRange
        let interior = imageRange.location + imageRange.length / 2

        XCTAssertEqual(
            WYSIWYGCaretSnap.snap(
                offset: interior,
                foldedDelimiterRanges: [imageRange],
                preferring: .forward
            ),
            NSMaxRange(imageRange)
        )
        XCTAssertEqual(
            WYSIWYGCaretSnap.snap(
                offset: interior,
                foldedDelimiterRanges: [imageRange],
                preferring: .backward
            ),
            imageRange.location
        )
        XCTAssertEqual(
            WYSIWYGCaretSnap.snap(
                offset: imageRange.location + 1,
                foldedDelimiterRanges: [imageRange],
                preferring: .nearest
            ),
            imageRange.location
        )
        XCTAssertEqual(
            WYSIWYGCaretSnap.snap(
                offset: NSMaxRange(imageRange) - 1,
                foldedDelimiterRanges: [imageRange],
                preferring: .nearest
            ),
            NSMaxRange(imageRange)
        )

        let fixture = try Support.makeWindowedEditor()
        _ = try await Support.waitForMarker(in: fixture.textView, range: imageRange)
        fixture.textView.textSelection = NSRange(location: interior, length: 0)
        let snapped = fixture.textView.wysiwygSnappedCaretOffset(interior, preferring: .nearest)
        XCTAssertTrue(
            snapped == imageRange.location || snapped == NSMaxRange(imageRange),
            "Interior image caret must snap to a span edge, got \(snapped)"
        )
    }

    func testI3ShiftSelectionEnteringLeavingAndSpanningImageKeepsRawOffsets() async throws {
        let fixture = try Support.makeWindowedEditor()
        let source = Support.source
        let imageRange = Support.imageRange
        _ = try await Support.waitForMarker(in: fixture.textView, range: imageRange)

        // Enter from the left through the image into the trailing path chrome.
        let enterStart = imageRange.location - 1
        let enterEnd = imageRange.location + 4
        fixture.textView.textSelection = NSRange(location: enterStart, length: 0)
        for _ in 0 ..< (enterEnd - enterStart) {
            fixture.textView.moveRightAndModifySelection(nil)
        }
        let entered = fixture.textView.selectedRange()
        XCTAssertEqual(entered.location, enterStart)
        XCTAssertEqual(NSMaxRange(entered), enterEnd)
        try Support.assertRawCopy(
            from: fixture.textView,
            source: source,
            range: entered,
            expected: (source as NSString).substring(with: entered)
        )

        // Leave from inside the image toward the right boundary and past it.
        let leaveStart = NSMaxRange(imageRange) - 3
        let leaveEnd = NSMaxRange(imageRange) + 1
        fixture.textView.textSelection = NSRange(location: leaveStart, length: 0)
        for _ in 0 ..< (leaveEnd - leaveStart) {
            fixture.textView.moveRightAndModifySelection(nil)
        }
        let left = fixture.textView.selectedRange()
        XCTAssertEqual(left, NSRange(location: leaveStart, length: leaveEnd - leaveStart))

        // Span the entire image plus both neighbors.
        let spanStart = imageRange.location - 1
        let spanEnd = NSMaxRange(imageRange) + 1
        fixture.textView.textSelection = NSRange(location: spanStart, length: 0)
        for _ in 0 ..< (spanEnd - spanStart) {
            fixture.textView.moveRightAndModifySelection(nil)
        }
        let span = fixture.textView.selectedRange()
        XCTAssertEqual(span.location, spanStart)
        XCTAssertEqual(NSMaxRange(span), spanEnd)
        XCTAssertTrue((source as NSString).substring(with: span).contains(Support.imageSource))
    }

    func testI3EmojiAndCJKInAltAndPathAtEdgesDoNotTrapCaret() async throws {
        let imageSource = "![圖emoji🎨](路徑/照片📷.png)"
        let source = "前 \(imageSource) 後\n"
        let imageRange = (source as NSString).range(of: imageSource)
        let fixture = try Support.makeWindowedEditor(
            source: source,
            outcomes: [
                "路徑/照片📷.png": Support.readyOutcome(
                    source: "路徑/照片📷.png",
                    resolvedPath: "posts/路徑/照片📷.png"
                ),
            ]
        )
        _ = try await Support.waitForMarker(in: fixture.textView, range: imageRange)
        _ = try Support.assertLiveAttachment(in: fixture.textView, imageRange: imageRange)

        fixture.textView.textSelection = NSRange(location: imageRange.location, length: 0)
        fixture.textView.moveRight(nil)
        XCTAssertEqual(
            fixture.textView.selectedRange(),
            NSRange(location: NSMaxRange(imageRange), length: 0)
        )
        fixture.textView.moveLeft(nil)
        XCTAssertEqual(
            fixture.textView.selectedRange(),
            NSRange(location: imageRange.location, length: 0)
        )
        XCTAssertEqual(Support.text(in: fixture.textView), source)
    }

    func testI3ImageAdjacentToFoldedLinkOnSameLineKeepsIndependentSnapping() async throws {
        let imageSource = "![alt](fixture.png)"
        let source = "Lead \(imageSource) [linked text](https://example.com/path) tail\n"
        let storage = source as NSString
        let imageRange = storage.range(of: imageSource)
        let linkText = storage.range(of: "linked text")
        let fixture = try Support.makeWindowedEditor(source: source, frame: NSRect(
            x: 0,
            y: 0,
            width: 900,
            height: 420
        ))
        _ = try await Support.waitForMarker(in: fixture.textView, range: imageRange)
        _ = try Support.assertLiveAttachment(in: fixture.textView, imageRange: imageRange)

        fixture.textView.textSelection = NSRange(location: imageRange.location, length: 0)
        fixture.textView.moveRight(nil)
        XCTAssertEqual(
            fixture.textView.selectedRange(),
            NSRange(location: NSMaxRange(imageRange), length: 0)
        )

        // From just before the folded link destination chrome, right-arrow should land past the URL.
        let afterLinkText = NSMaxRange(linkText)
        fixture.textView.textSelection = NSRange(location: afterLinkText, length: 0)
        fixture.textView.moveRight(nil)
        let afterDestination = fixture.textView.selectedRange().location
        XCTAssertGreaterThanOrEqual(afterDestination, storage.range(of: ") tail").location)
        XCTAssertNil(fixture.textView.wysiwygFoldedDelimiterRange(containingInterior: afterDestination))
        XCTAssertEqual(Support.text(in: fixture.textView), source)
    }

    func testI3RevealOnTouchClearsImagePresentationMarker() async throws {
        let fixture = try Support.makeWindowedEditor()
        let imageRange = Support.imageRange
        _ = try await Support.waitForMarker(in: fixture.textView, range: imageRange)
        XCTAssertNotNil(Support.imageMarker(in: fixture.textView, range: imageRange))

        let caret = try Support.clickAttachment(in: fixture, imageRange: imageRange)
        XCTAssertTrue(
            caret == imageRange.location || caret == NSMaxRange(imageRange),
            "Reveal-on-touch must place the caret on an image edge, got \(caret)"
        )
        XCTAssertNil(Support.imageMarker(in: fixture.textView, range: imageRange))
        let revealedLine = try Support.lineFragment(containing: imageRange, in: fixture.textView)
        XCTAssertTrue(revealedLine.attributedString.string.contains(Support.imageSource))
        XCTAssertFalse(revealedLine.attributedString.string.contains("\u{FFFC}"))
    }
}

private typealias Support = WYSIWYGImageThumbnailGateSupport
