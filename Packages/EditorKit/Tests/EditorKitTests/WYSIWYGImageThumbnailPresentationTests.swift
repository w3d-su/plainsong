import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// The I0 invariant matrix migrated onto parsed image regions and the production-shaped
/// EditorKit loader seam. The hook remains internal and is never selected by App code.
@MainActor
final class WYSIWYGImageThumbnailPresentationTests: XCTestCase {
    static let imageSource = "![alt](fixture.png)"
    static let source = "Top sibling line\n\(imageSource)\nBottom sibling line\n"

    func testProjectedRegionUsesOneAttachmentAndEqualLengthZeroWidthPadding() async throws {
        let fixture = try makeWindowedEditor()
        let marker = try await waitForMarker(
            in: fixture.textView,
            range: Self.imageRange,
            matching: { if case .ready = $0.visualState { true } else { false } }
        )
        let (paragraph, paragraphRange) = try projectedImageParagraph(
            in: fixture.textView,
            imageRange: Self.imageRange
        )
        let localImageRange = NSRange(
            location: Self.imageRange.location - paragraphRange.location,
            length: Self.imageRange.length
        )
        let projected = paragraph.attributedString

        XCTAssertEqual(projected.length, paragraphRange.length)
        XCTAssertEqual(
            (projected.string as NSString).substring(
                with: NSRange(location: localImageRange.location, length: 1)
            ),
            "\u{FFFC}"
        )
        XCTAssertEqual(
            (projected.string as NSString).substring(with: NSRange(
                location: localImageRange.location + 1,
                length: localImageRange.length - 1
            )),
            String(repeating: "\u{200B}", count: localImageRange.length - 1)
        )
        XCTAssertEqual(projected.string.unicodeScalars.filter { $0.value == 0xFFFC }.count, 1)

        let attachment = try XCTUnwrap(
            projected.attribute(.attachment, at: localImageRange.location, effectiveRange: nil)
                as? NSTextAttachment
        )
        XCTAssertEqual(attachment.bounds.size, marker.canvasSize)
        XCTAssertEqual(attachment.image?.size, marker.canvasSize)
        XCTAssertEqual(attachment.image?.accessibilityDescription, "alt")
        XCTAssertNil(projected.attribute(
            .attachment,
            at: localImageRange.location + 1,
            effectiveRange: nil
        ))
    }

    func testBackingTextStorageBytesRemainExactRawSource() async throws {
        let fixture = try makeWindowedEditor()
        _ = try await waitForMarker(in: fixture.textView, range: Self.imageRange)
        let textStorage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))
        _ = try assertLiveAttachment(in: fixture.textView, imageRange: Self.imageRange)

        XCTAssertEqual(Data(textStorage.string.utf8), Data(Self.source.utf8))
        XCTAssertFalse(textStorage.string.contains("\u{FFFC}"))
        textStorage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: textStorage.length)
        ) { attachment, _, _ in
            XCTAssertNil(attachment, "The backing NSTextStorage must never receive an attachment")
        }
    }

    func testWholePartialAndBoundaryCopiesStayRawForPlainAndRTF() async throws {
        let fixture = try makeWindowedEditor()
        let textView = fixture.textView
        _ = try await waitForMarker(in: textView, range: Self.imageRange)
        _ = try assertLiveAttachment(in: textView, imageRange: Self.imageRange)
        let imageRange = Self.imageRange
        let selections: [(name: String, range: NSRange)] = [
            ("whole", imageRange),
            ("partial", NSRange(location: imageRange.location + 2, length: imageRange.length - 5)),
            ("leading boundary", NSRange(location: imageRange.location - 1, length: 6)),
            ("trailing boundary", NSRange(location: NSMaxRange(imageRange) - 5, length: 6)),
        ]

        for selection in selections {
            textView.textSelection = selection.range
            let pasteboard = uniquePasteboard()
            XCTAssertTrue(
                textView.writeSelection(to: pasteboard, types: [.rtf, .string]),
                "Expected copy for \(selection.name) selection"
            )
            let copied = pasteboard.string(forType: .string)
            let expected = (Self.source as NSString).substring(with: selection.range)
            XCTAssertEqual(copied.map { Data($0.utf8) }, Data(expected.utf8))
            XCTAssertFalse(copied?.contains("\u{FFFC}") ?? true)

            let rtfData = try XCTUnwrap(pasteboard.data(forType: .rtf))
            var documentAttributes: NSDictionary?
            let copiedRTF = try NSAttributedString(
                data: rtfData,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: &documentAttributes
            )
            XCTAssertEqual(Data(copiedRTF.string.utf8), Data(expected.utf8))
            XCTAssertFalse(copiedRTF.string.contains("\u{FFFC}"))
            copiedRTF.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: copiedRTF.length)
            ) { attachment, _, _ in
                XCTAssertNil(attachment, "Rich copy must contain raw Markdown")
            }
        }
    }

    func testRawPasteMutatesOnlyBackingSource() async throws {
        let fixture = try makeWindowedEditor()
        let textView = fixture.textView
        _ = try await waitForMarker(in: textView, range: Self.imageRange)
        _ = try assertLiveAttachment(in: textView, imageRange: Self.imageRange)
        let altRange = (Self.source as NSString).range(of: "alt")
        textView.textSelection = altRange
        let pasteboard = uniquePasteboard()
        pasteboard.setString("caption", forType: .string)

        XCTAssertTrue(textView.readSelection(from: pasteboard, type: .string))
        let expected = (Self.source as NSString).replacingCharacters(in: altRange, with: "caption")
        let textStorage = try XCTUnwrap(MarkdownTextView.textStorage(of: textView))
        XCTAssertEqual(Data(textStorage.string.utf8), Data(expected.utf8))
        XCTAssertFalse(textStorage.string.contains("\u{FFFC}"))
    }

    func testAccessibilityKeepsRawValueAndSelectedTextAndExposesAltDescription() async throws {
        let fixture = try makeWindowedEditor()
        let textView = fixture.textView
        _ = try await waitForMarker(in: textView, range: Self.imageRange)
        let projected = try projectedImageParagraph(in: textView, imageRange: Self.imageRange).0
        let attachment = try XCTUnwrap(
            projected.attributedString.attribute(
                .attachment,
                at: (projected.attributedString.string as NSString).range(of: "\u{FFFC}").location,
                effectiveRange: nil
            ) as? NSTextAttachment
        )
        XCTAssertEqual(attachment.image?.accessibilityDescription, "alt")

        let accessibilityValue = try XCTUnwrap(textView.accessibilityValue() as? String)
        XCTAssertEqual(Data(accessibilityValue.utf8), Data(Self.source.utf8))
        XCTAssertFalse(accessibilityValue.contains("\u{FFFC}"))

        let imageRange = Self.imageRange
        let selections = [
            imageRange,
            NSRange(location: imageRange.location + 2, length: imageRange.length - 5),
            NSRange(location: imageRange.location - 1, length: 6),
            NSRange(location: NSMaxRange(imageRange) - 5, length: 6),
        ]
        for selection in selections {
            textView.textSelection = selection
            let selectedText = try XCTUnwrap(textView.accessibilitySelectedText())
            let expected = (Self.source as NSString).substring(with: selection)
            XCTAssertEqual(Data(selectedText.utf8), Data(expected.utf8))
            XCTAssertFalse(selectedText.contains("\u{FFFC}"))
        }

        XCTAssertEqual(textView.accessibilityString(for: imageRange), Self.imageSource)
        let attributedValue = try XCTUnwrap(textView.accessibilityAttributedString(for: imageRange))
        XCTAssertEqual(attributedValue.string, Self.imageSource)
        XCTAssertFalse(attributedValue.string.contains("\u{FFFC}"))
        attributedValue.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedValue.length)
        ) { attachment, _, _ in
            XCTAssertNil(attachment, "AX attributed output must use raw backing source")
        }
    }

    func testPresentationKeepsNestedUndoIsolationAndRestoresAfterPlainTextUndo() async throws {
        let fixture = try makeWindowedEditor()
        let textView = fixture.textView
        let undoManager = try XCTUnwrap(textView.undoManager)
        _ = try await waitForMarker(in: textView, range: Self.imageRange)
        undoManager.removeAllActions()

        undoManager.disableUndoRegistration()
        XCTAssertFalse(undoManager.isUndoRegistrationEnabled)
        applyPresentation(
            source: Self.source,
            selection: NSRange(location: 0, length: 0),
            coordinator: fixture.coordinator,
            textView: textView
        )
        XCTAssertFalse(undoManager.isUndoRegistrationEnabled)
        undoManager.enableUndoRegistration()
        XCTAssertFalse(undoManager.canUndo)

        _ = try clickAttachment(in: fixture, imageRange: Self.imageRange)
        XCTAssertFalse(undoManager.canUndo, "Reveal presentation must not register undo")
        applyPresentation(
            source: Self.source,
            selection: NSRange(location: 0, length: 0),
            coordinator: fixture.coordinator,
            textView: textView
        )
        _ = try await waitForMarker(in: textView, range: Self.imageRange)
        XCTAssertFalse(undoManager.canUndo)

        let insertionLocation = NSMaxRange((Self.source as NSString).range(of: "Top sibling line"))
        textView.textSelection = NSRange(location: insertionLocation, length: 0)
        textView.insertText("!", replacementRange: textView.selectedRange())
        XCTAssertTrue(undoManager.canUndo)

        undoManager.undo()
        let restored = try XCTUnwrap(MarkdownTextView.textStorage(of: textView)?.string)
        XCTAssertEqual(Data(restored.utf8), Data(Self.source.utf8))
        XCTAssertFalse(restored.contains("\u{FFFC}"))
        XCTAssertTrue(undoManager.canRedo)
        applyPresentation(
            source: restored,
            selection: NSRange(location: 0, length: 0),
            coordinator: fixture.coordinator,
            textView: textView
        )
        _ = try await waitForMarker(in: textView, range: Self.imageRange)
        _ = try assertLiveAttachment(in: textView, imageRange: Self.imageRange)
    }

    func testStandaloneGeometryReservesOnlyImageLineAndPreservesViewport() async throws {
        let prefix = (0 ..< 12).map { "Prelude line \($0)" }.joined(separator: "\n")
        let suffix = (0 ..< 12).map { "Following line \($0)" }.joined(separator: "\n")
        let source = """
        \(prefix)
        Top sibling line
        \(Self.imageSource)
        Bottom sibling line
        \(suffix)
        """
        let imageRange = (source as NSString).range(of: Self.imageSource)
        let topRange = (source as NSString).range(of: "Top sibling line")
        let bottomRange = (source as NSString).range(of: "Bottom sibling line")
        let frame = NSRect(x: 0, y: 0, width: 760, height: 420)
        let fixture = try makeWindowedEditor(
            source: source,
            selection: imageRange,
            frame: frame
        )
        let clipView = try XCTUnwrap(fixture.textView.enclosingScrollView?.contentView)

        let normalTopFrame = try lineFragmentFrame(containing: topRange, in: fixture.textView)
        let normalImageFrame = try lineFragmentFrame(containing: imageRange, in: fixture.textView)
        let normalBottomFrame = try lineFragmentFrame(containing: bottomRange, in: fixture.textView)
        clipView.scroll(to: CGPoint(x: 0, y: normalTopFrame.minY - 20))
        fixture.textView.enclosingScrollView?.reflectScrolledClipView(clipView)
        let originBeforeProjection = clipView.bounds.origin
        XCTAssertGreaterThan(originBeforeProjection.y, 0)

        applyPresentation(
            source: source,
            selection: NSRange(location: 0, length: 0),
            coordinator: fixture.coordinator,
            textView: fixture.textView
        )
        let marker = try await waitForMarker(in: fixture.textView, range: imageRange)
        _ = try assertLiveAttachment(
            in: fixture.textView,
            imageRange: imageRange,
            expectedSize: marker.canvasSize
        )

        let projectedTopFrame = try lineFragmentFrame(containing: topRange, in: fixture.textView)
        let projectedImageFrame = try lineFragmentFrame(containing: imageRange, in: fixture.textView)
        let projectedBottomFrame = try lineFragmentFrame(containing: bottomRange, in: fixture.textView)
        XCTAssertGreaterThanOrEqual(projectedImageFrame.height, marker.canvasSize.height - 2)
        XCTAssertLessThanOrEqual(projectedImageFrame.height, marker.canvasSize.height + 8)
        XCTAssertEqual(projectedTopFrame.height, normalTopFrame.height, accuracy: 1)
        XCTAssertEqual(projectedBottomFrame.height, normalBottomFrame.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(projectedBottomFrame.minY, projectedImageFrame.maxY - 1)

        let intentionalHeightDelta = projectedImageFrame.height - normalImageFrame.height
        XCTAssertEqual(
            projectedBottomFrame.minY - normalBottomFrame.minY,
            intentionalHeightDelta,
            accuracy: 3
        )
        XCTAssertEqual(clipView.bounds.origin.x, originBeforeProjection.x, accuracy: 0.5)
        XCTAssertEqual(clipView.bounds.origin.y, originBeforeProjection.y, accuracy: 0.5)
    }

    func testInlineImageDoesNotInflateOtherWrappedVisualLines() async throws {
        let source = """
        Top paragraph
        \(Self
            .imageSource) alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau
        Bottom paragraph
        """
        let imageRange = (source as NSString).range(of: Self.imageSource)
        let fixture = try makeWindowedEditor(
            source: source,
            frame: NSRect(x: 0, y: 0, width: 230, height: 360)
        )
        let marker = try await waitForMarker(in: fixture.textView, range: imageRange)
        _ = try assertLiveAttachment(in: fixture.textView, imageRange: imageRange)

        let paragraphFragment = try layoutFragment(containing: imageRange, in: fixture.textView)
        let wrappedLines = paragraphFragment.textLineFragments.filter { !$0.isExtraLineFragment }
        XCTAssertGreaterThanOrEqual(wrappedLines.count, 3)

        var attachmentLineCount = 0
        for line in wrappedLines {
            let lineString = line.attributedString
                .attributedSubstring(from: line.characterRange)
                .string
            if lineString.contains("\u{FFFC}") {
                attachmentLineCount += 1
                XCTAssertGreaterThanOrEqual(line.typographicBounds.height, marker.canvasSize.height - 2)
            } else {
                XCTAssertLessThanOrEqual(
                    line.typographicBounds.height,
                    20,
                    "Only the wrapped visual line containing the attachment may grow"
                )
            }
        }
        XCTAssertEqual(attachmentLineCount, 1)
    }

    func testArrowMovementSnapsAcrossImageSpanToRawEdges() async throws {
        let fixture = try makeWindowedEditor()
        let textView = fixture.textView
        _ = try await waitForMarker(in: textView, range: Self.imageRange)
        _ = try assertLiveAttachment(in: textView, imageRange: Self.imageRange)

        textView.textSelection = NSRange(location: Self.imageRange.location, length: 0)
        textView.moveRight(nil)
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: NSMaxRange(Self.imageRange), length: 0)
        )

        textView.moveLeft(nil)
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: Self.imageRange.location, length: 0)
        )
        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.string, Self.source)
    }

    func testRealNSEventClickPlacesEdgeCaretAndRevealsRawImage() async throws {
        let fixture = try makeWindowedEditor()
        _ = try await waitForMarker(in: fixture.textView, range: Self.imageRange)
        let caret = try clickAttachment(in: fixture, imageRange: Self.imageRange)
        XCTAssertTrue(
            caret == Self.imageRange.location || caret == NSMaxRange(Self.imageRange),
            "Attachment click must land on a raw image-span edge, got \(caret)"
        )
        XCTAssertEqual(MarkdownTextView.textStorage(of: fixture.textView)?.string, Self.source)
        XCTAssertNil(imageMarker(in: fixture.textView, range: Self.imageRange))

        ensureLayout(in: fixture.textView)
        let revealedLine = try lineFragment(containing: Self.imageRange, in: fixture.textView)
        XCTAssertTrue(revealedLine.attributedString.string.contains(Self.imageSource))
        XCTAssertFalse(revealedLine.attributedString.string.contains("\u{FFFC}"))
    }
}
