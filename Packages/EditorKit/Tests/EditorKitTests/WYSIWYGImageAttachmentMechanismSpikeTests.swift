import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// Throwaway I0 tests for choosing the image-thumbnail rendering mechanism.
///
/// These tests intentionally exercise one hardcoded image literal and do not authorize
/// production image parsing, loading, caching, or user-facing presentation.
@MainActor
final class WYSIWYGImageAttachmentMechanismSpikeTests: XCTestCase {
    static let source = "Top sibling line\n![alt](fixture.png)\nBottom sibling line\n"

    func testI0OptionAProjectedParagraphUsesOneAttachmentAndZeroWidthPadding() throws {
        let textView = makeSpikeTextView()
        let (paragraph, paragraphRange) = try projectedImageParagraph(in: textView)
        let imageRange = Self.imageRange
        let localImageRange = NSRange(
            location: imageRange.location - paragraphRange.location,
            length: imageRange.length
        )
        let projected = paragraph.attributedString

        XCTAssertEqual(projected.length, paragraphRange.length)
        XCTAssertEqual(
            (projected.string as NSString).substring(with: NSRange(location: localImageRange.location, length: 1)),
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
        XCTAssertEqual(attachment.bounds.size.width, WYSIWYGImageAttachmentI0Spike.attachmentSize.width)
        XCTAssertEqual(attachment.bounds.size.height, WYSIWYGImageAttachmentI0Spike.attachmentSize.height)
        XCTAssertEqual(attachment.image?.size, WYSIWYGImageAttachmentI0Spike.attachmentSize)
        XCTAssertNil(projected.attribute(
            .attachment,
            at: localImageRange.location + 1,
            effectiveRange: nil
        ))
    }

    func testI0OptionABackingTextStorageBytesRemainExactRawSource() throws {
        let fixture = try makeWindowedEditor(spikeEnabled: true)
        let textView = fixture.textView
        let textStorage = try XCTUnwrap(MarkdownTextView.textStorage(of: textView))
        _ = try assertLiveAttachment(in: textView, imageRange: Self.imageRange)

        XCTAssertEqual(Data(textStorage.string.utf8), Data(Self.source.utf8))
        XCTAssertFalse(textStorage.string.contains("\u{FFFC}"))
        textStorage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: textStorage.length)
        ) { attachment, _, _ in
            XCTAssertNil(attachment, "The backing NSTextStorage must never receive an attachment")
        }
    }

    func testI0OptionAWholePartialAndBoundaryCopiesAreExactRawBytesWithoutObjectReplacementCharacters() throws {
        let fixture = try makeWindowedEditor(spikeEnabled: true)
        let textView = fixture.textView
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
            XCTAssertEqual(
                copied.map { Data($0.utf8) },
                Data(expected.utf8),
                "Expected byte-identical copy for \(selection.name) selection"
            )
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
                XCTAssertNil(attachment, "Rich copy must contain raw Markdown, not an attachment")
            }
        }
    }

    func testI0OptionAPasteMutatesOnlyRawBackingSourceWithoutObjectReplacementCharacters() throws {
        let fixture = try makeWindowedEditor(spikeEnabled: true)
        let textView = fixture.textView
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

    func testI0OptionAAccessibilityOutputsAreExactRawSourceWithoutObjectReplacementCharacters() throws {
        let fixture = try makeWindowedEditor(spikeEnabled: true)
        let textView = fixture.textView
        _ = try assertLiveAttachment(in: textView, imageRange: Self.imageRange)

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

        XCTAssertEqual(
            textView.accessibilityString(for: imageRange),
            WYSIWYGImageAttachmentI0Spike.source
        )
        let accessibilityAttributedString = try XCTUnwrap(
            textView.accessibilityAttributedString(for: imageRange)
        )
        XCTAssertEqual(accessibilityAttributedString.string, WYSIWYGImageAttachmentI0Spike.source)
        XCTAssertFalse(accessibilityAttributedString.string.contains("\u{FFFC}"))
        accessibilityAttributedString.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: accessibilityAttributedString.length)
        ) { attachment, _, _ in
            XCTAssertNil(attachment, "AX attributed output must use the raw backing source")
        }
    }

    func testI0OptionAPresentationDoesNotRegisterUndoAndNearbyEditUndoRestoresRawSource() throws {
        let fixture = try makeWindowedEditor(spikeEnabled: true)
        let textView = fixture.textView
        let undoManager = try XCTUnwrap(textView.undoManager)
        undoManager.removeAllActions()
        _ = try assertLiveAttachment(in: textView, imageRange: Self.imageRange)

        undoManager.disableUndoRegistration()
        XCTAssertFalse(undoManager.isUndoRegistrationEnabled)
        XCTAssertTrue(textView.setWYSIWYGImageAttachmentI0SpikeEnabled(true))
        XCTAssertFalse(undoManager.isUndoRegistrationEnabled)
        undoManager.enableUndoRegistration()
        XCTAssertTrue(undoManager.isUndoRegistrationEnabled)
        XCTAssertFalse(undoManager.canUndo, "Presentation must preserve nested undo-disable state")

        _ = try clickAttachment(in: fixture, imageRange: Self.imageRange)
        XCTAssertFalse(undoManager.canUndo, "Reveal presentation must not register undo")
        XCTAssertTrue(textView.setWYSIWYGImageAttachmentI0SpikeEnabled(true))
        _ = try assertLiveAttachment(in: textView, imageRange: Self.imageRange)
        XCTAssertFalse(undoManager.canUndo, "Projection-only presentation must not register undo")

        let insertionLocation = NSMaxRange((Self.source as NSString).range(of: "Top sibling line"))
        textView.textSelection = NSRange(location: insertionLocation, length: 0)
        textView.insertText("!", replacementRange: textView.selectedRange())
        let edited = (Self.source as NSString).replacingCharacters(
            in: NSRange(location: insertionLocation, length: 0),
            with: "!"
        )
        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.string, edited)
        XCTAssertTrue(undoManager.canUndo)

        undoManager.undo()
        let restored = try XCTUnwrap(MarkdownTextView.textStorage(of: textView)?.string)
        XCTAssertEqual(Data(restored.utf8), Data(Self.source.utf8))
        XCTAssertFalse(restored.contains("\u{FFFC}"))
        XCTAssertTrue(undoManager.canRedo)
        _ = try assertLiveAttachment(in: textView, imageRange: Self.imageRange)
    }

    func testI0OptionAAttachmentLineReservesOnlyAttachmentHeightAndKeepsSiblingLinesInViewport() throws {
        let prefix = (0 ..< 12).map { "Prelude line \($0)" }.joined(separator: "\n")
        let suffix = (0 ..< 12).map { "Following line \($0)" }.joined(separator: "\n")
        let source = """
        \(prefix)
        Top sibling line
        \(WYSIWYGImageAttachmentI0Spike.source)
        Bottom sibling line
        \(suffix)
        """
        let imageRange = (source as NSString).range(of: WYSIWYGImageAttachmentI0Spike.source)
        let topRange = (source as NSString).range(of: "Top sibling line")
        let bottomRange = (source as NSString).range(of: "Bottom sibling line")
        let frame = NSRect(x: 0, y: 0, width: 640, height: 160)
        let fixture = try makeWindowedEditor(source: source, frame: frame, spikeEnabled: false)
        let clipView = try XCTUnwrap(fixture.textView.enclosingScrollView?.contentView)

        let normalTopFrame = try lineFragmentFrame(containing: topRange, in: fixture.textView)
        let normalImageFrame = try lineFragmentFrame(containing: imageRange, in: fixture.textView)
        let normalBottomFrame = try lineFragmentFrame(containing: bottomRange, in: fixture.textView)
        clipView.scroll(to: CGPoint(x: 0, y: normalTopFrame.minY - 20))
        fixture.textView.enclosingScrollView?.reflectScrolledClipView(clipView)
        let originBeforeProjection = clipView.bounds.origin
        XCTAssertGreaterThan(originBeforeProjection.y, 0)
        XCTAssertTrue(fixture.textView.visibleRect.intersects(normalTopFrame))
        XCTAssertTrue(fixture.textView.visibleRect.intersects(normalBottomFrame))

        XCTAssertTrue(fixture.textView.setWYSIWYGImageAttachmentI0SpikeEnabled(true))
        ensureLayout(in: fixture.textView)
        _ = try assertLiveAttachment(in: fixture.textView, imageRange: imageRange)

        let projectedTopFrame = try lineFragmentFrame(containing: topRange, in: fixture.textView)
        let projectedImageFrame = try lineFragmentFrame(containing: imageRange, in: fixture.textView)
        let projectedBottomFrame = try lineFragmentFrame(containing: bottomRange, in: fixture.textView)

        XCTAssertGreaterThanOrEqual(
            projectedImageFrame.height,
            WYSIWYGImageAttachmentI0Spike.attachmentSize.height - 1
        )
        XCTAssertLessThanOrEqual(
            projectedImageFrame.height,
            WYSIWYGImageAttachmentI0Spike.attachmentSize.height + 4
        )
        XCTAssertGreaterThan(projectedImageFrame.height, projectedTopFrame.height)
        XCTAssertEqual(projectedTopFrame.height, normalTopFrame.height, accuracy: 1)
        XCTAssertEqual(projectedBottomFrame.height, normalBottomFrame.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(projectedBottomFrame.minY, projectedImageFrame.maxY - 1)

        let intentionalHeightDelta = projectedImageFrame.height - normalImageFrame.height
        let actualBottomShift = projectedBottomFrame.minY - normalBottomFrame.minY
        XCTAssertEqual(actualBottomShift, intentionalHeightDelta, accuracy: 2)
        XCTAssertEqual(clipView.bounds.origin.x, originBeforeProjection.x, accuracy: 0.5)
        XCTAssertEqual(clipView.bounds.origin.y, originBeforeProjection.y, accuracy: 0.5)
        XCTAssertTrue(fixture.textView.visibleRect.intersects(projectedTopFrame))
        XCTAssertTrue(fixture.textView.visibleRect.intersects(projectedBottomFrame))
    }

    func testI0OptionAInlineAttachmentDoesNotInflateWrappedSiblingLines() throws {
        let source = """
        Top paragraph
        \(WYSIWYGImageAttachmentI0Spike
            .source) alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau
        Bottom paragraph
        """
        let imageRange = (source as NSString).range(of: WYSIWYGImageAttachmentI0Spike.source)
        let frame = NSRect(x: 0, y: 0, width: 230, height: 280)
        let fixture = try makeWindowedEditor(source: source, frame: frame, spikeEnabled: true)
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
                XCTAssertGreaterThanOrEqual(
                    line.typographicBounds.height,
                    WYSIWYGImageAttachmentI0Spike.attachmentSize.height - 1
                )
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

    func testI0OptionAArrowMovementSnapsAcrossImageSpanToRawEdges() throws {
        let fixture = try makeWindowedEditor(spikeEnabled: true)
        let textView = fixture.textView
        _ = try assertLiveAttachment(in: textView, imageRange: Self.imageRange)
        let imageRange = Self.imageRange

        textView.textSelection = NSRange(location: imageRange.location, length: 0)
        textView.moveRight(nil)
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: NSMaxRange(imageRange), length: 0)
        )

        textView.moveLeft(nil)
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: imageRange.location, length: 0)
        )
        XCTAssertEqual(MarkdownTextView.textStorage(of: textView)?.string, Self.source)
    }

    func testI0OptionARealAttachmentClickPlacesEdgeCaretAndRevealsRawSource() throws {
        let fixture = try makeWindowedEditor(spikeEnabled: true)
        let imageRange = Self.imageRange
        let caret = try clickAttachment(in: fixture, imageRange: imageRange)
        XCTAssertTrue(
            caret == imageRange.location || caret == NSMaxRange(imageRange),
            "Attachment click must land on a raw image-span edge, got \(caret)"
        )
        XCTAssertEqual(MarkdownTextView.textStorage(of: fixture.textView)?.string, Self.source)

        let textContentStorage = try XCTUnwrap(
            fixture.textView.textContentManager as? NSTextContentStorage
        )
        let delegate = try XCTUnwrap(
            textContentStorage.delegate as? WYSIWYGZeroWidthTextContentStorageDelegate
        )
        XCTAssertTrue(delegate.isImageAttachmentI0SpikeRevealed)
        ensureLayout(in: fixture.textView)
        let revealedLine = try lineFragment(containing: imageRange, in: fixture.textView)
        XCTAssertTrue(revealedLine.attributedString.string.contains(WYSIWYGImageAttachmentI0Spike.source))
        XCTAssertFalse(revealedLine.attributedString.string.contains("\u{FFFC}"))
    }
}
