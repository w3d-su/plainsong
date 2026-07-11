import AppKit
@testable import EditorKit
import STTextView
import XCTest

@MainActor
extension WYSIWYGImageThumbnailNativeGateTests {
    // MARK: - I4 Copy / paste

    func testI4WholePartialBoundaryAndAltToPathSelectionsCopyExactRawPlainAndRTF() async throws {
        let fixture = try Support.makeWindowedEditor()
        let source = Support.source
        let imageRange = Support.imageRange
        _ = try await Support.waitForMarker(in: fixture.textView, range: imageRange)
        _ = try Support.assertLiveAttachment(in: fixture.textView, imageRange: imageRange)

        let altRange = (source as NSString).range(of: "alt")
        let pathRange = (source as NSString).range(of: "fixture.png")
        let altIntoPath = NSRange(
            location: altRange.location + 1,
            length: (pathRange.location + 4) - (altRange.location + 1)
        )
        let selections: [(name: String, range: NSRange)] = [
            ("whole", imageRange),
            ("partial", NSRange(location: imageRange.location + 2, length: imageRange.length - 5)),
            ("leading boundary", NSRange(location: imageRange.location - 1, length: 6)),
            ("trailing boundary", NSRange(location: NSMaxRange(imageRange) - 5, length: 6)),
            ("alt into path", altIntoPath),
        ]

        for selection in selections {
            try Support.assertRawCopy(
                from: fixture.textView,
                source: source,
                range: selection.range,
                expected: (source as NSString).substring(with: selection.range)
            )
        }
        XCTAssertEqual(
            (source as NSString).substring(with: altIntoPath),
            "lt](fixt"
        )
    }

    func testI4PasteIntoFoldedAndRevealedImageRegionsMutatesSourceNormally() async throws {
        let folded = try Support.makeWindowedEditor()
        let imageRange = Support.imageRange
        _ = try await Support.waitForMarker(in: folded.textView, range: imageRange)
        let altRange = (Support.source as NSString).range(of: "alt")
        folded.textView.textSelection = altRange
        let foldedPasteboard = Support.uniquePasteboard(prefix: "PlainsongImagePasteFolded")
        foldedPasteboard.setString("caption", forType: .string)
        XCTAssertTrue(folded.textView.readSelection(from: foldedPasteboard, type: .string))
        let foldedExpected = (Support.source as NSString)
            .replacingCharacters(in: altRange, with: "caption")
        XCTAssertEqual(Data(Support.text(in: folded.textView).utf8), Data(foldedExpected.utf8))
        Support.assertNoObjectReplacementOrZeroWidth(Support.text(in: folded.textView))

        let revealed = try Support.makeWindowedEditor()
        _ = try await Support.waitForMarker(in: revealed.textView, range: imageRange)
        _ = try Support.clickAttachment(in: revealed, imageRange: imageRange)
        XCTAssertNil(Support.imageMarker(in: revealed.textView, range: imageRange))
        let pathRange = (Support.source as NSString).range(of: "fixture.png")
        revealed.textView.textSelection = pathRange
        let revealedPasteboard = Support.uniquePasteboard(prefix: "PlainsongImagePasteRevealed")
        revealedPasteboard.setString("other.jpg", forType: .string)
        XCTAssertTrue(revealed.textView.readSelection(from: revealedPasteboard, type: .string))
        let revealedExpected = (Support.source as NSString)
            .replacingCharacters(in: pathRange, with: "other.jpg")
        XCTAssertEqual(Data(Support.text(in: revealed.textView).utf8), Data(revealedExpected.utf8))
        Support.assertNoObjectReplacementOrZeroWidth(Support.text(in: revealed.textView))
    }

    // MARK: - I7 Accessibility

    func testI7AXValueAndSelectedTextStayExactRawWithThumbnailPresent() async throws {
        let fixture = try Support.makeWindowedEditor()
        let source = Support.source
        let imageRange = Support.imageRange
        _ = try await Support.waitForMarker(in: fixture.textView, range: imageRange)
        _ = try Support.assertLiveAttachment(in: fixture.textView, imageRange: imageRange)

        let accessibilityValue = try XCTUnwrap(fixture.textView.accessibilityValue() as? String)
        XCTAssertEqual(Data(accessibilityValue.utf8), Data(source.utf8))
        Support.assertNoObjectReplacementOrZeroWidth(accessibilityValue)

        let selections = [
            imageRange,
            NSRange(location: imageRange.location + 2, length: imageRange.length - 5),
            NSRange(location: imageRange.location - 1, length: 6),
            NSRange(location: NSMaxRange(imageRange) - 5, length: 6),
        ]
        for selection in selections {
            fixture.textView.textSelection = selection
            let selectedText = try XCTUnwrap(fixture.textView.accessibilitySelectedText())
            let expected = (source as NSString).substring(with: selection)
            XCTAssertEqual(Data(selectedText.utf8), Data(expected.utf8))
            Support.assertNoObjectReplacementOrZeroWidth(selectedText)
        }
    }

    func testI7AttachmentExposesAltTextAndEmptyAltUsesImageFallback() async throws {
        let withAlt = try Support.makeWindowedEditor()
        _ = try await Support.waitForMarker(in: withAlt.textView, range: Support.imageRange)
        let projected = try Support.projectedImageParagraph(
            in: withAlt.textView,
            imageRange: Support.imageRange
        ).0
        let attachmentLocation = (projected.attributedString.string as NSString)
            .range(of: "\u{FFFC}").location
        let attachment = try XCTUnwrap(
            projected.attributedString.attribute(
                .attachment,
                at: attachmentLocation,
                effectiveRange: nil
            ) as? NSTextAttachment
        )
        XCTAssertEqual(attachment.image?.accessibilityDescription, "alt")

        let emptyAltSource = "![](fixture.png)"
        let emptySource = "Top\n\(emptyAltSource)\nbottom\n"
        let emptyRange = (emptySource as NSString).range(of: emptyAltSource)
        let emptyFixture = try Support.makeWindowedEditor(source: emptySource)
        _ = try await Support.waitForMarker(in: emptyFixture.textView, range: emptyRange)
        let emptyProjected = try Support.projectedImageParagraph(
            in: emptyFixture.textView,
            imageRange: emptyRange
        ).0
        let emptyAttachmentLocation = (emptyProjected.attributedString.string as NSString)
            .range(of: "\u{FFFC}").location
        let emptyAttachment = try XCTUnwrap(
            emptyProjected.attributedString.attribute(
                .attachment,
                at: emptyAttachmentLocation,
                effectiveRange: nil
            ) as? NSTextAttachment
        )
        XCTAssertEqual(
            emptyAttachment.image?.accessibilityDescription,
            "Image",
            "Empty alt must expose the deterministic 'Image' accessibility fallback"
        )
    }

    // MARK: - I9 Undo / redo

    func testI9PresentationNeverRegistersUndoIncludingPlaceholderReadyAndRefresh() async throws {
        let fixture = try Support.makeWindowedEditor(delayNanoseconds: 80_000_000)
        let imageRange = Support.imageRange
        let undoManager = try XCTUnwrap(fixture.textView.undoManager)
        undoManager.removeAllActions()

        _ = try await Support.waitForMarker(
            in: fixture.textView,
            range: imageRange,
            matching: { $0.visualState == .loading }
        )
        XCTAssertFalse(undoManager.canUndo, "Loading placeholder must not register undo")

        _ = try await Support.waitForMarker(
            in: fixture.textView,
            range: imageRange,
            matching: { if case .ready = $0.visualState { true } else { false } }
        )
        XCTAssertFalse(undoManager.canUndo, "placeholder→ready swap must not register undo")

        Support.applyPresentation(
            source: Support.source,
            selection: NSRange(location: 0, length: 0),
            coordinator: fixture.coordinator,
            textView: fixture.textView
        )
        _ = try await Support.waitForMarker(in: fixture.textView, range: imageRange)
        XCTAssertFalse(undoManager.canUndo, "Presentation refresh must not register undo")

        _ = try Support.clickAttachment(in: fixture, imageRange: imageRange)
        XCTAssertFalse(undoManager.canUndo, "Reveal presentation must not register undo")
    }

    func testI9EditingAltAndPathAfterRevealUndoRedoAndRebuildProjection() async throws {
        let fixture = try Support.makeWindowedEditor()
        let imageRange = Support.imageRange
        let undoManager = try XCTUnwrap(fixture.textView.undoManager)
        _ = try await Support.waitForMarker(in: fixture.textView, range: imageRange)
        undoManager.removeAllActions()

        _ = try Support.clickAttachment(in: fixture, imageRange: imageRange)
        XCTAssertNil(Support.imageMarker(in: fixture.textView, range: imageRange))
        XCTAssertFalse(undoManager.canUndo)

        let altRange = (Support.source as NSString).range(of: "alt")
        fixture.textView.textSelection = altRange
        fixture.textView.insertText("caption", replacementRange: altRange)
        let afterAlt = Support.text(in: fixture.textView)
        XCTAssertTrue(afterAlt.contains("![caption](fixture.png)"))
        XCTAssertTrue(undoManager.canUndo)

        let pathLiteral = "fixture.png"
        let pathRange = (afterAlt as NSString).range(of: pathLiteral)
        fixture.textView.insertText("other.png", replacementRange: pathRange)
        let afterPath = Support.text(in: fixture.textView)
        XCTAssertTrue(afterPath.contains("![caption](other.png)"))

        undoManager.undo()
        XCTAssertEqual(Support.text(in: fixture.textView), afterAlt)
        undoManager.undo()
        XCTAssertEqual(Support.text(in: fixture.textView), Support.source)

        // Recompute folded presentation after undo — projected paragraph must rebuild.
        Support.applyPresentation(
            source: Support.source,
            selection: NSRange(location: 0, length: 0),
            coordinator: fixture.coordinator,
            textView: fixture.textView
        )
        _ = try await Support.waitForMarker(in: fixture.textView, range: imageRange)
        _ = try Support.assertLiveAttachment(in: fixture.textView, imageRange: imageRange)
        XCTAssertTrue(undoManager.canRedo)

        undoManager.redo()
        let redoneAlt = Support.text(in: fixture.textView)
        XCTAssertEqual(redoneAlt, afterAlt)
        let redoneImageRange = (redoneAlt as NSString).range(of: "![caption](fixture.png)")
        Support.applyPresentation(
            source: redoneAlt,
            selection: NSRange(location: 0, length: 0),
            coordinator: fixture.coordinator,
            textView: fixture.textView
        )
        // Outside selection should re-fold; path still fixture.png so the ready marker returns.
        _ = try await Support.waitForMarker(in: fixture.textView, range: redoneImageRange)
        _ = try Support.assertLiveAttachment(in: fixture.textView, imageRange: redoneImageRange)
        XCTAssertFalse(Support.text(in: fixture.textView).contains("\u{FFFC}"))

        undoManager.redo()
        let redonePath = Support.text(in: fixture.textView)
        XCTAssertEqual(redonePath, afterPath)
        let finalImageRange = (redonePath as NSString).range(of: "![caption](other.png)")
        Support.applyPresentation(
            source: redonePath,
            selection: NSRange(location: 0, length: 0),
            coordinator: fixture.coordinator,
            textView: fixture.textView
        )
        // other.png is not in the loader outcomes — deterministic failed placeholder, no stale ready.
        let finalMarker = try await Support.waitForMarker(
            in: fixture.textView,
            range: finalImageRange,
            matching: { $0.visualState == .failed || $0.visualState == .loading }
        )
        XCTAssertNotEqual(
            {
                if case .ready = finalMarker.visualState { return true }
                return false
            }(),
            true,
            "Redo to an unknown path must not keep a stale ready attachment"
        )
        _ = try Support.assertLiveAttachment(in: fixture.textView, imageRange: finalImageRange)
    }

    func testI9NestedUndoIsolationFromPresentationTestsStaysGreen() async throws {
        // Keeps the #80 nested isolation invariant as a named I9 reference (not a reimplementation
        // of the I0 matrix). Presentation mutations stay outside the undo stack.
        let fixture = try Support.makeWindowedEditor()
        let textView = fixture.textView
        let undoManager = try XCTUnwrap(textView.undoManager)
        _ = try await Support.waitForMarker(in: textView, range: Support.imageRange)
        undoManager.removeAllActions()

        undoManager.disableUndoRegistration()
        XCTAssertFalse(undoManager.isUndoRegistrationEnabled)
        Support.applyPresentation(
            source: Support.source,
            selection: NSRange(location: 0, length: 0),
            coordinator: fixture.coordinator,
            textView: textView
        )
        XCTAssertFalse(undoManager.isUndoRegistrationEnabled)
        undoManager.enableUndoRegistration()
        XCTAssertFalse(undoManager.canUndo)

        let insertionLocation = NSMaxRange((Support.source as NSString).range(of: "Top sibling line"))
        textView.textSelection = NSRange(location: insertionLocation, length: 0)
        textView.insertText("!", replacementRange: textView.selectedRange())
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(Data(Support.text(in: textView).utf8), Data(Support.source.utf8))
        Support.applyPresentation(
            source: Support.source,
            selection: NSRange(location: 0, length: 0),
            coordinator: fixture.coordinator,
            textView: textView
        )
        _ = try await Support.waitForMarker(in: textView, range: Support.imageRange)
        _ = try Support.assertLiveAttachment(in: textView, imageRange: Support.imageRange)
    }
}

private typealias Support = WYSIWYGImageThumbnailGateSupport
