import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// Real-`NSEvent` pointer gates for image thumbnails (I6). Mirrors
/// `WYSIWYGLinkNativePointerGateTests`. No drag-resize and no open-in-Preview in v1.
@MainActor
final class WYSIWYGImageThumbnailNativePointerGateTests: XCTestCase {
    func testI6RealPointerClickOnThumbnailBodyPlacesCaretRevealsAndDoesNotOpenPreview() async throws {
        let fixture = try Support.makeWindowedEditor()
        let imageRange = Support.imageRange
        _ = try await Support.waitForMarker(
            in: fixture.textView,
            range: imageRange,
            matching: { if case .ready = $0.visualState { true } else { false } }
        )
        _ = try Support.assertLiveAttachment(in: fixture.textView, imageRange: imageRange)

        let caret = try Support.clickAttachment(in: fixture, imageRange: imageRange)
        XCTAssertTrue(
            caret == imageRange.location || caret == NSMaxRange(imageRange),
            "Thumbnail body click must place the caret on a raw image-span edge, got \(caret)"
        )
        XCTAssertNil(Support.imageMarker(in: fixture.textView, range: imageRange))
        XCTAssertEqual(Support.text(in: fixture.textView), Support.source)

        // No open-in-Preview / external open: source is unchanged and selection is a caret.
        XCTAssertEqual(fixture.textView.selectedRange().length, 0)
        // No drag-resize: canvas geometry is presentation-only; bounds stay fixed and source raw.
        Support.ensureLayout(in: fixture.textView)
        let revealedLine = try Support.lineFragment(containing: imageRange, in: fixture.textView)
        XCTAssertTrue(revealedLine.attributedString.string.contains(Support.imageSource))
        XCTAssertFalse(revealedLine.attributedString.string.contains("\u{FFFC}"))
    }

    func testI6RealPointerClicksAtBothVisualBoundariesDoNotTrapCaret() async throws {
        let fixture = try Support.makeWindowedEditor()
        let imageRange = Support.imageRange
        _ = try await Support.waitForMarker(in: fixture.textView, range: imageRange)
        _ = try Support.assertLiveAttachment(in: fixture.textView, imageRange: imageRange)

        let leadingProbe = NSRange(location: imageRange.location, length: 1)
        let trailingProbe = NSRange(location: NSMaxRange(imageRange) - 1, length: 1)

        for (probe, fraction, label) in [
            (leadingProbe, CGFloat(0.05), "leading"),
            (trailingProbe, CGFloat(0.95), "trailing"),
        ] {
            // Re-apply presentation so each boundary click starts from a folded thumbnail.
            Support.applyPresentation(
                source: Support.source,
                selection: NSRange(location: 0, length: 0),
                coordinator: fixture.coordinator,
                textView: fixture.textView
            )
            _ = try await Support.waitForMarker(in: fixture.textView, range: imageRange)

            let caret = try Support.pointerClick(on: probe, in: fixture, fraction: fraction)
            XCTAssertTrue(
                caret == imageRange.location || caret == NSMaxRange(imageRange),
                "\(label) boundary click must land on a span edge, got \(caret)"
            )
            XCTAssertNil(
                Support.imageMarker(in: fixture.textView, range: imageRange),
                "\(label) boundary click must reveal the image span"
            )
            // Not trapped: a subsequent arrow can leave the former span.
            if caret == imageRange.location {
                fixture.textView.moveLeft(nil)
                XCTAssertLessThan(fixture.textView.selectedRange().location, imageRange.location)
            } else {
                fixture.textView.moveRight(nil)
                XCTAssertGreaterThan(
                    fixture.textView.selectedRange().location,
                    NSMaxRange(imageRange) - 1
                )
            }
        }
    }

    func testI6RealPointerDragSelectionAcrossImageCopiesExactRawMarkdown() async throws {
        let fixture = try Support.makeWindowedEditor()
        let source = Support.source
        let imageRange = Support.imageRange
        _ = try await Support.waitForMarker(in: fixture.textView, range: imageRange)

        let before = (source as NSString).range(of: "Top sibling line")
        let after = (source as NSString).range(of: "Bottom sibling line")

        _ = try Support.pointerClick(on: before, in: fixture, fraction: 0.15)
        _ = try Support.pointerClick(on: after, in: fixture, shift: true, fraction: 0.85)

        let selection = fixture.textView.selectedRange()
        XCTAssertLessThan(selection.location, imageRange.location)
        XCTAssertGreaterThan(NSMaxRange(selection), NSMaxRange(imageRange))
        let rawSelection = (source as NSString).substring(with: selection)
        XCTAssertTrue(rawSelection.contains(Support.imageSource))

        let pasteboard = Support.uniquePasteboard(prefix: "PlainsongImagePointerDrag")
        XCTAssertTrue(fixture.textView.writeSelection(to: pasteboard, types: [.string, .rtf]))
        XCTAssertEqual(pasteboard.string(forType: .string), rawSelection)
        Support.assertNoObjectReplacementOrZeroWidth(pasteboard.string(forType: .string))

        let rtfData = try XCTUnwrap(pasteboard.data(forType: .rtf))
        var documentAttributes: NSDictionary?
        let copiedRTF = try NSAttributedString(
            data: rtfData,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: &documentAttributes
        )
        XCTAssertEqual(Data(copiedRTF.string.utf8), Data(rawSelection.utf8))
        Support.assertNoObjectReplacementOrZeroWidth(copiedRTF.string)
    }

    func testI6ShiftClickExtensionAcrossImageKeepsRawOffsets() async throws {
        let fixture = try Support.makeWindowedEditor()
        let source = Support.source
        let imageRange = Support.imageRange
        _ = try await Support.waitForMarker(in: fixture.textView, range: imageRange)

        // Anchor before the image, then shift-click well after it on the following line so the
        // extend target is ordinary text geometry (not the projected attachment).
        let before = (source as NSString).range(of: "Top sibling line")
        let after = (source as NSString).range(of: "Bottom sibling line")
        _ = try Support.pointerClick(on: before, in: fixture, fraction: 0.9)
        Support.applyPresentation(
            source: source,
            selection: fixture.textView.selectedRange(),
            coordinator: fixture.coordinator,
            textView: fixture.textView
        )
        _ = try await Support.waitForMarker(in: fixture.textView, range: imageRange)
        // Keep the pre-image caret so the image stays folded while shift-extending.
        fixture.textView.textSelection = NSRange(location: imageRange.location - 1, length: 0)
        _ = try Support.pointerClick(on: after, in: fixture, shift: true, fraction: 0.2)

        let selection = fixture.textView.selectedRange()
        XCTAssertEqual(selection.location, imageRange.location - 1)
        XCTAssertGreaterThan(NSMaxRange(selection), NSMaxRange(imageRange))
        let expected = (source as NSString).substring(with: selection)
        XCTAssertTrue(expected.contains(Support.imageSource))
        try Support.assertRawCopy(
            from: fixture.textView,
            source: source,
            range: selection,
            expected: expected
        )
    }
}

private typealias Support = WYSIWYGImageThumbnailGateSupport
