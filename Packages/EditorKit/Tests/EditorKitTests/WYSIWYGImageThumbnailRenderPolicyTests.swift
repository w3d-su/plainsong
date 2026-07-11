import AppKit
@testable import EditorKit
import XCTest

@MainActor
extension WYSIWYGImageThumbnailPresentationTests {
    func testDevelopmentHookOffKeepsBothPublicPresentationsImageByteIdentical() throws {
        let source = "Before ![alt](fixture.png) after\n"
        let range = NSRange(location: 0, length: (source as NSString).length)
        let highlighter = MarkdownSyntaxHighlighter()
        let sourceResult = highlighter.highlight(
            source,
            fileKind: .markdown,
            visibleRange: range,
            developmentPresentation: .source
        )
        let inlineResult = highlighter.highlight(
            source,
            fileKind: .markdown,
            visibleRange: range,
            developmentPresentation: .inlineFoldReveal
        )
        let linkResult = highlighter.highlight(
            source,
            fileKind: .markdown,
            visibleRange: range,
            developmentPresentation: .inlineFoldRevealWithLinkFolding
        )

        XCTAssertEqual(sourceResult.range, inlineResult.range)
        XCTAssertEqual(sourceResult.range, linkResult.range)
        XCTAssertEqual(sourceResult.text, inlineResult.text)
        XCTAssertEqual(sourceResult.text, linkResult.text)

        let textView = MarkdownSTTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        textView.text = source
        XCTAssertTrue(textView.setWYSIWYGZeroWidthFoldingEnabled(true))
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(
            HighlightedText(
                revision: 1,
                range: inlineResult.range,
                text: inlineResult.text,
                foldPlan: inlineResult.foldPlan
            ),
            to: textView
        ))
        let textStorage = try XCTUnwrap(MarkdownTextView.textStorage(of: textView))
        XCTAssertEqual(Data(textStorage.string.utf8), Data(source.utf8))
        XCTAssertNil(textStorage.attribute(
            WYSIWYGImagePresentationMarker.attribute,
            at: (source as NSString).range(of: Self.imageSource).location,
            effectiveRange: nil
        ))
    }

    func testLoadingPlaceholderAndReadyThumbnailShareGeometrySelectionAndScroll() async throws {
        let fixture = try makeWindowedEditor(delayNanoseconds: 180_000_000)
        let textView = fixture.textView
        let loadingMarker = try await waitForMarker(
            in: textView,
            range: Self.imageRange,
            matching: { $0.visualState == .loading }
        )
        ensureLayout(in: textView)
        let placeholderFrame = try lineFragmentFrame(containing: Self.imageRange, in: textView)
        let bottomRange = (Self.source as NSString).range(of: "Bottom sibling line")
        let bottomFrameBefore = try lineFragmentFrame(containing: bottomRange, in: textView)
        let selectionBefore = textView.selectedRange()
        let scrollOriginBefore = textView.enclosingScrollView?.contentView.bounds.origin

        let readyMarker = try await waitForMarker(
            in: textView,
            range: Self.imageRange,
            matching: { if case .ready = $0.visualState { true } else { false } }
        )
        ensureLayout(in: textView)
        let readyFrame = try lineFragmentFrame(containing: Self.imageRange, in: textView)
        let bottomFrameAfter = try lineFragmentFrame(containing: bottomRange, in: textView)

        XCTAssertEqual(loadingMarker.canvasSize, readyMarker.canvasSize)
        XCTAssertEqual(placeholderFrame.width, readyFrame.width, accuracy: 1)
        XCTAssertEqual(placeholderFrame.height, readyFrame.height, accuracy: 1)
        XCTAssertEqual(bottomFrameBefore.minY, bottomFrameAfter.minY, accuracy: 1)
        XCTAssertEqual(textView.selectedRange(), selectionBefore)
        XCTAssertEqual(textView.enclosingScrollView?.contentView.bounds.origin, scrollOriginBefore)
    }

    func testMissingFailureAndCorruptReadyDataKeepDeterministicAltPlaceholder() async throws {
        let missingFixture = try makeWindowedEditor(
            outcomes: ["fixture.png": .failed(.missingFile)]
        )
        let missingMarker = try await waitForMarker(
            in: missingFixture.textView,
            range: Self.imageRange,
            matching: { $0.visualState == .failed }
        )
        let missingLine = try assertLiveAttachment(
            in: missingFixture.textView,
            imageRange: Self.imageRange,
            expectedSize: missingMarker.canvasSize
        )
        XCTAssertTrue(missingLine.attributedString.string.contains("\u{FFFC}"))

        let corrupt = EditorImageThumbnail(
            pngData: Data([0x00, 0x01, 0x02]),
            pixelWidth: 100,
            pixelHeight: 50,
            resolvedWorkspaceRelativePath: "posts/fixture.png",
            contentModificationDate: Date(timeIntervalSinceReferenceDate: 1)
        )
        let corruptFixture = try makeWindowedEditor(
            outcomes: ["fixture.png": .ready(corrupt)]
        )
        let corruptMarker = try await waitForMarker(
            in: corruptFixture.textView,
            range: Self.imageRange,
            matching: { $0.visualState == .failed }
        )
        let paragraph = try projectedImageParagraph(
            in: corruptFixture.textView,
            imageRange: Self.imageRange
        ).0
        let attachmentLocation = (paragraph.attributedString.string as NSString).range(of: "\u{FFFC}").location
        let attachment = try XCTUnwrap(
            paragraph.attributedString.attribute(
                .attachment,
                at: attachmentLocation,
                effectiveRange: nil
            ) as? NSTextAttachment
        )
        XCTAssertEqual(attachment.bounds.size, corruptMarker.canvasSize)
        XCTAssertEqual(attachment.image?.accessibilityDescription, "alt")
    }

    func testReadyThumbnailFitsEditorAndUsesPixelAspectInsideThreeHundredPointCap() async throws {
        let outcome = Self.readyOutcome(
            source: "fixture.png",
            resolvedPath: "posts/fixture.png",
            pixelWidth: 1200,
            pixelHeight: 200
        )
        let fixture = try makeWindowedEditor(
            frame: NSRect(x: 0, y: 0, width: 250, height: 360),
            outcomes: ["fixture.png": outcome]
        )
        let marker = try await waitForMarker(
            in: fixture.textView,
            range: Self.imageRange,
            matching: { if case .ready = $0.visualState { true } else { false } }
        )
        let availableWidth = fixture.textView.textContainer.size.width
            - fixture.textView.textContainer.lineFragmentPadding * 2

        XCTAssertLessThanOrEqual(marker.canvasSize.width, availableWidth)
        XCTAssertLessThanOrEqual(
            marker.canvasSize.height,
            WYSIWYGImagePresentationMetrics.maximumDisplayHeight
        )
        XCTAssertGreaterThan(marker.contentRect.width, 0)
        XCTAssertGreaterThan(marker.contentRect.height, 0)
        XCTAssertEqual(marker.contentRect.width / marker.contentRect.height, 6, accuracy: 0.1)
        XCTAssertTrue(NSRect(origin: .zero, size: marker.canvasSize).contains(marker.contentRect))
    }

    func testMultipleImagesShareOneLineWithFoldedLinkAndCoalesceDuplicateLoad() async throws {
        let first = "![one](same.png)"
        let second = "![two](same.png)"
        let source = "Lead \(first) [link](dest.md) \(second) tail\n"
        let storage = source as NSString
        let firstRange = storage.range(of: first)
        let secondRange = storage.range(
            of: second,
            options: [],
            range: NSRange(location: NSMaxRange(firstRange), length: storage.length - NSMaxRange(firstRange))
        )
        let fixture = try makeWindowedEditor(
            source: source,
            frame: NSRect(x: 0, y: 0, width: 1000, height: 420),
            outcomes: [
                "same.png": Self.readyOutcome(
                    source: "same.png",
                    resolvedPath: "posts/same.png"
                ),
            ],
            delayNanoseconds: 80_000_000
        )
        let firstMarker = try await waitForMarker(
            in: fixture.textView,
            range: firstRange,
            matching: { if case .ready = $0.visualState { true } else { false } }
        )
        let secondMarker = try await waitForMarker(
            in: fixture.textView,
            range: secondRange,
            matching: { if case .ready = $0.visualState { true } else { false } }
        )
        let requests = await fixture.loader.recordedRequests()
        XCTAssertEqual(requests.filter { $0.source == "same.png" }.count, 1)
        XCTAssertEqual(firstMarker.canvasSize, secondMarker.canvasSize)

        let paragraph = try projectedImageParagraph(
            in: fixture.textView,
            imageRange: firstRange
        ).0.attributedString
        XCTAssertEqual(paragraph.string.unicodeScalars.filter { $0.value == 0xFFFC }.count, 2)
        XCTAssertTrue(paragraph.string.contains("link"))
        XCTAssertFalse(paragraph.string.contains("dest.md"))
        XCTAssertTrue(paragraph.string.contains("\u{200B}"))
    }

    func testStayRawOutcomeRemovesPlaceholderAndLeavesExactSource() async throws {
        let source = "Before ![alt](art.svg) after\n"
        let imageRange = (source as NSString).range(of: "![alt](art.svg)")
        let fixture = try makeWindowedEditor(
            source: source,
            outcomes: ["art.svg": .stayRaw(.unsupportedPathExtension("svg"))],
            delayNanoseconds: 60_000_000
        )
        _ = try await waitForMarker(
            in: fixture.textView,
            range: imageRange,
            matching: { $0.visualState == .loading }
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(imageMarker(in: fixture.textView, range: imageRange))
        let line = try lineFragment(containing: imageRange, in: fixture.textView)
        XCTAssertTrue(line.attributedString.string.contains("![alt](art.svg)"))
        XCTAssertFalse(line.attributedString.string.contains("\u{FFFC}"))
        XCTAssertEqual(MarkdownTextView.textStorage(of: fixture.textView)?.string, source)
    }

    func testTextChangeCancelsAndDropsStaleLoadBeforeNewPlanApplies() async throws {
        let fixture = try makeWindowedEditor(delayNanoseconds: 300_000_000)
        _ = try await waitForMarker(
            in: fixture.textView,
            range: Self.imageRange,
            matching: { $0.visualState == .loading }
        )
        try await waitForRequestCount(1, loader: fixture.loader)

        fixture.textView.textSelection = NSRange(location: 0, length: 0)
        fixture.textView.insertText("!", replacementRange: fixture.textView.selectedRange())
        let editedSource = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView)?.string)
        let shiftedRange = (editedSource as NSString).range(of: Self.imageSource)
        XCTAssertNil(fixture.textView.wysiwygZeroWidthContentStorageDelegate?.imagePresentationGeneration)
        ensureLayout(in: fixture.textView)
        let rawLine = try lineFragment(containing: shiftedRange, in: fixture.textView)
        XCTAssertTrue(rawLine.attributedString.string.contains(Self.imageSource))
        XCTAssertFalse(rawLine.attributedString.string.contains("\u{FFFC}"))

        applyPresentation(
            source: editedSource,
            selection: NSRange(location: 0, length: 0),
            coordinator: fixture.coordinator,
            textView: fixture.textView
        )
        try await waitForRequestCount(2, loader: fixture.loader)
        _ = try await waitForMarker(
            in: fixture.textView,
            range: shiftedRange,
            matching: { if case .ready = $0.visualState { true } else { false } }
        )
    }

    func testDocumentChangeCancelsOldGenerationAndStartsFreshRequest() async throws {
        let fixture = try makeWindowedEditor(delayNanoseconds: 250_000_000)
        _ = try await waitForMarker(
            in: fixture.textView,
            range: Self.imageRange,
            matching: { $0.visualState == .loading }
        )
        try await waitForRequestCount(1, loader: fixture.loader)

        fixture.coordinator.updateImageThumbnailPresentationConfiguration(
            fixture.configuration,
            documentIdentity: EditorDocumentIdentity(rawValue: "replacement-document"),
            isPresentationEnabled: true,
            in: fixture.textView
        )
        XCTAssertNil(imageMarker(in: fixture.textView, range: Self.imageRange))
        applyPresentation(
            source: Self.source,
            selection: NSRange(location: 0, length: 0),
            coordinator: fixture.coordinator,
            textView: fixture.textView
        )
        try await waitForRequestCount(2, loader: fixture.loader)
        _ = try await waitForMarker(
            in: fixture.textView,
            range: Self.imageRange,
            matching: { if case .ready = $0.visualState { true } else { false } }
        )
    }

    func testRefreshProxyReloadsOnlyAffectedPathAndPreservesSelectionAndScroll() async throws {
        let source = "Top\n![a](a.png)\nMiddle\n![b](b.png)\nBottom\n"
        let storage = source as NSString
        let firstRange = storage.range(of: "![a](a.png)")
        let secondRange = storage.range(of: "![b](b.png)")
        let refreshProxy = EditorImageThumbnailRefreshProxy()
        let firstDate = Date(timeIntervalSinceReferenceDate: 1)
        let secondDate = Date(timeIntervalSinceReferenceDate: 2)
        let fixture = try makeWindowedEditor(
            source: source,
            outcomes: [
                "a.png": Self.readyOutcome(
                    source: "a.png",
                    resolvedPath: "posts/a.png",
                    modificationDate: firstDate
                ),
                "b.png": Self.readyOutcome(
                    source: "b.png",
                    resolvedPath: "posts/b.png",
                    modificationDate: firstDate
                ),
            ],
            refreshProxy: refreshProxy
        )
        _ = try await waitForMarker(
            in: fixture.textView,
            range: firstRange,
            matching: { if case .ready = $0.visualState { true } else { false } }
        )
        let unaffectedBefore = try await waitForMarker(
            in: fixture.textView,
            range: secondRange,
            matching: { if case .ready = $0.visualState { true } else { false } }
        )
        let selectionBefore = fixture.textView.selectedRange()
        let originBefore = fixture.textView.enclosingScrollView?.contentView.bounds.origin

        await fixture.loader.setOutcome(
            Self.readyOutcome(
                source: "a.png",
                resolvedPath: "posts/a.png",
                pixelWidth: 200,
                pixelHeight: 300,
                modificationDate: secondDate
            ),
            for: "a.png"
        )
        await fixture.loader.setDelayNanoseconds(100_000_000)
        refreshProxy.invalidateThumbnails(forWorkspaceRelativePaths: ["posts/a.png"])
        let loadingMarker = try XCTUnwrap(imageMarker(in: fixture.textView, range: firstRange))
        XCTAssertEqual(loadingMarker.visualState, .loading)
        XCTAssertEqual(imageMarker(in: fixture.textView, range: secondRange)?.signature, unaffectedBefore.signature)

        let refreshed = try await waitForMarker(
            in: fixture.textView,
            range: firstRange,
            matching: { marker in
                if case let .ready(_, date, _, _, _) = marker.visualState {
                    return date == secondDate
                }
                return false
            }
        )
        XCTAssertEqual(refreshed.resolvedWorkspaceRelativePath, "posts/a.png")
        XCTAssertEqual(fixture.textView.selectedRange(), selectionBefore)
        XCTAssertEqual(fixture.textView.enclosingScrollView?.contentView.bounds.origin, originBefore)

        let requests = await fixture.loader.recordedRequests()
        XCTAssertEqual(requests.filter { $0.source == "a.png" }.count, 2)
        XCTAssertEqual(requests.filter { $0.source == "b.png" }.count, 1)
    }
}
