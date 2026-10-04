import AppKit
@testable import EditorKit
import MarkdownCore
import XCTest

private struct DelimiterCase {
    let source: String
    let pattern: String
    let replacement: String
    let post: String
    let kinds: [WYSIWYGFoldRegion.Kind]

    init(_ source: String, _ pattern: String, _ replacement: String, post: String, kinds: [WYSIWYGFoldRegion.Kind]) {
        self.source = source
        self.pattern = pattern
        self.replacement = replacement
        self.post = post
        self.kinds = kinds
    }
}

@MainActor
final class EditorReplaceWYSIWYGTests: XCTestCase {
    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testFoldedDelimitersNavigateThenReplaceExactSpanAndUndoRedo() async throws {
        // Each post-write source is the literal splice; the expected fold kinds are what the
        // parser derives from that unrepaired text. `*字🦊**` reads as emphasis plus a
        // literal `*`, and every other malformed result has no fold region at all.
        for item in [
            DelimiterCase("Intro **文字😀** tail", "**文字😀", "*字🦊", post: "Intro *字🦊** tail", kinds: [.emphasis]),
            DelimiterCase("Intro *one* tail", "*one", "one", post: "Intro one* tail", kinds: []),
            DelimiterCase("# Heading\nTail", "# ", "", post: "Heading\nTail", kinds: []),
            DelimiterCase("Intro ~~one~~ tail", "~~one", "one", post: "Intro one~~ tail", kinds: []),
            DelimiterCase("Intro `one` tail", "`one", "one", post: "Intro one` tail", kinds: []),
        ] {
            let ready = try await foldedReady(source: item.source, pattern: item.pattern)
            try navigateAndReveal(ready, replacement: item.replacement)
            try replaceAndUndoRedo(ready, replacement: item.replacement)
            XCTAssertEqual(ready.fixture.model.source, item.post, "no Markdown repair")
            let parsed = linkPresentation(item.post, selection: NSRange(location: 0, length: 0))
            XCTAssertEqual(parsed.foldPlan?.regions.map(\.kind), item.kinds, "post-write fold kinds: \(item.post)")
        }
    }

    func testLinkDestinationRevealsWholeSourceWithoutURLNormalization() async throws {
        let ready = try await foldedReady(
            source: "Intro [文字😀](https://host/a%2Fb_(c)) tail",
            pattern: "%2F"
        )
        let region = try XCTUnwrap(ready.fixture.textView.replacePresentationSnapshot?.styledText.foldPlan?.regions
            .first { $0.kind == .link })
        XCTAssertFalse(region.isRevealed)
        try navigateAndReveal(ready, replacement: "%2f")
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: ready.fixture.textView))
        let foldedAttribute = WYSIWYGInlineFoldPresentation.foldedDelimiterAttribute
        storage.enumerateAttribute(foldedAttribute, in: region.sourceRange) { value, _, _ in
            XCTAssertNotEqual(value as? Bool, true, "whole link source must be raw")
        }
        try replaceAndUndoRedo(ready, replacement: "%2f")
        XCTAssertEqual(ready.fixture.model.source, "Intro [文字😀](https://host/a%2fb_(c)) tail")
    }

    func testImageProjectionNavigatesRevealsAndRebuildsAfterUndoRedo() async throws {
        let ready = try await foldedReady(source: "Intro ![文字😀](fixture.png) tail", pattern: "文字😀")
        let configuration = imageConfiguration()
        configureImages(ready, configuration)
        let imageRange = (ready.fixture.model.source as NSString).range(of: "![文字😀](fixture.png)")
        let marker = try await WYSIWYGImageThumbnailGateSupport.waitForMarker(
            in: ready.fixture.textView, range: imageRange
        )
        XCTAssertEqual(marker.sourceRange, imageRange)
        try navigateAndReveal(ready, replacement: "新🦊")
        XCTAssertNil(WYSIWYGImageThumbnailGateSupport.imageMarker(in: ready.fixture.textView, range: imageRange))
        try replaceAndUndoRedo(ready, replacement: "新🦊", imageConfiguration: configuration)
        XCTAssertEqual(ready.fixture.model.source, "Intro ![新🦊](fixture.png) tail")
    }

    func testInvalidImageAfterReplaceStaysRawAndEditable() async throws {
        let ready = try await foldedReady(source: "Intro ![alt](fixture.png) tail", pattern: "](fixture.png)")
        configureImages(ready, imageConfiguration())
        try navigateAndReveal(ready, replacement: "]fixture.png)")
        try replaceAndUndoRedo(ready, replacement: "]fixture.png)")
        let invalid = ready.fixture.model.source
        let highlighted = reparse(ready, selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(highlighted.foldPlan?.imageRegions.count, 0)
        XCTAssertFalse(hasHiddenAttributes(ready))
        ready.fixture.textView.insertText(
            "!",
            replacementRange: NSRange(location: (invalid as NSString).length, length: 0)
        )
        XCTAssertEqual(ready.fixture.model.source, invalid + "!")
    }

    func testAdjacentMatchNeitherRevealsFoldNorRefuses() async throws {
        let ready = try await foldedReady(source: "Intro **one**tail", pattern: "tail")
        try navigateAndReveal(ready, replacement: "TAIL")
        let region = try XCTUnwrap(ready.fixture.textView.replacePresentationSnapshot?.styledText.foldPlan?.regions
            .first)
        XCTAssertFalse(region.isRevealed)
        XCTAssertTrue(hasHiddenAttributes(ready))
        guard case .replaced = EditorReplaceSingleSupport.perform(ready, replacement: "TAIL") else {
            return XCTFail("an adjacent match must remain eligible")
        }
        XCTAssertEqual(ready.fixture.model.source, "Intro **one**TAIL")
    }

    func testRefoldedPresentationAtStillValidOffsetRefusesWithZeroEffect() async throws {
        let ready = try await foldedReady(source: "Intro [one](https://host/a) tail", pattern: "host")
        try navigateAndReveal(ready, replacement: "HOST")
        let match = try XCTUnwrap(ready.session.currentMatch?.range)
        ready.fixture.textView.textSelection = NSRange(location: 0, length: 0)
        _ = reparse(ready, selection: ready.fixture.textView.selectedRange())
        // Non-Find selection returns before the debounced reveal has applied.
        ready.fixture.textView.textSelection = match
        let before = ready.fixture.model.revision
        XCTAssertEqual(EditorReplaceSingleSupport.perform(ready, replacement: "HOST"),
                       .refused(.wysiwygRangeNotRevealed))
        XCTAssertEqual(ready.fixture.model.revision, before)
        XCTAssertEqual(ready.fixture.model.writerActivations, 0)
        XCTAssertEqual(ready.fixture.model.publications, [])
        XCTAssertEqual(ready.fixture.textView.selectedRange(), match)
        XCTAssertEqual(ready.controller.session, ready.session)
        XCTAssertTrue(hasHiddenAttributes(ready))
        XCTAssertFalse(ready.fixture.textView.undoManager?.canUndo == true)
    }

    func testWholeLinkProofRejectsHiddenChromeOutsideTheMatch() async throws {
        let ready = try await foldedReady(source: "Intro [one](https://host/a) tail", pattern: "host")
        try navigateAndReveal(ready, replacement: "HOST")
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: ready.fixture.textView))
        let opening = (storage.string as NSString).range(of: "[")
        storage.addAttribute(WYSIWYGInlineFoldPresentation.foldedDelimiterAttribute, value: true, range: opening)
        XCTAssertEqual(EditorReplaceSingleSupport.perform(ready, replacement: "HOST"),
                       .refused(.wysiwygRangeNotRevealed))
        XCTAssertEqual(ready.fixture.model.writerActivations, 0)
    }

    func testImageProjectionReinstalledAtExactSelectionRefusesWithoutReveal() async throws {
        let ready = try await foldedReady(source: "Intro ![alt](fixture.png) tail", pattern: "alt")
        configureImages(ready, imageConfiguration())
        try navigateAndReveal(ready, replacement: "ALT")
        let source = ready.fixture.model.source
        let range = (source as NSString).range(of: "![alt](fixture.png)")
        let marker = WYSIWYGImagePresentationMarker(generation: 99, sourceRange: range, source: "fixture.png",
                                                    altText: "alt", canvasSize: NSSize(width: 100, height: 60),
                                                    outcome: nil)
        ready.fixture.textView.applyWYSIWYGImagePresentationMarkers([marker], replacing: [], generation: 99,
                                                                    forceReapply: true)
        XCTAssertEqual(EditorReplaceSingleSupport.perform(ready, replacement: "ALT"),
                       .refused(.wysiwygRangeNotRevealed))
        XCTAssertNotNil(WYSIWYGImageThumbnailGateSupport.imageMarker(in: ready.fixture.textView, range: range))
        XCTAssertEqual(ready.fixture.model.publications, [])
    }

    func testMarkedTextWithWYSIWYGRefusesBeforeAuthorizationOrReveal() async throws {
        let ready = try await foldedReady(source: "Intro **one** tail", pattern: "one")
        ready.fixture.textView.setMarkedText("ㄓ", selectedRange: NSRange(location: 1, length: 0),
                                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let selection = ready.fixture.textView.selectedRange()
        XCTAssertEqual(EditorReplaceSingleSupport.perform(ready, replacement: "ONE",
                                                          authorization: EditorReplaceAuthorization {
                                                              XCTFail("IME precedes authorization"); return true
                                                          }),
                       .refused(.markedText))
        XCTAssertEqual(ready.fixture.textView.selectedRange(), selection)
        XCTAssertEqual(ready.fixture.model.writerActivations, 0)
        XCTAssertEqual(ready.fixture.model.publications, [])
        XCTAssertEqual(ready.controller.session, ready.session)
    }

    func foldedReady(source: String, pattern: String) async throws -> EditorReplaceSingleSupport.Ready {
        let ready = try await EditorReplaceSingleSupport.makeReady(source: source, pattern: pattern,
                                                                   selection: NSRange(location: 0, length: 0),
                                                                   enableWYSIWYG: true)
        EditorReplaceSingleSupport.routePublicationsToFind(ready)
        _ = reparse(ready, selection: ready.fixture.textView.selectedRange())
        return ready
    }

    func navigateAndReveal(_ ready: EditorReplaceSingleSupport.Ready, replacement: String) throws {
        let source = ready.fixture.model.source
        let match = try XCTUnwrap(ready.session.currentMatch?.range)
        XCTAssertEqual(
            EditorReplaceSingleSupport.perform(ready, replacement: replacement),
            .navigatedToCurrentMatch(match)
        )
        XCTAssertEqual(ready.fixture.textView.selectedRange(), match)
        XCTAssertEqual(ready.fixture.model.source, source)
        XCTAssertEqual(ready.fixture.model.writerActivations, 0)
        XCTAssertFalse(ready.fixture.textView.undoManager?.canUndo == true)
        _ = reparse(ready, selection: match)
        XCTAssertTrue(ready.fixture.coordinator.isReplaceRangeRevealed(match, in: ready.fixture.textView))
    }

    func replaceAndUndoRedo(_ ready: EditorReplaceSingleSupport.Ready, replacement: String,
                            imageConfiguration: EditorImageThumbnailConfiguration? = nil) throws
    {
        let source = ready.fixture.model.source
        let match = try XCTUnwrap(ready.session.currentMatch?.range)
        let expected = (source as NSString).replacingCharacters(in: match, with: replacement)
        guard case .replaced = EditorReplaceSingleSupport.perform(ready, replacement: replacement) else {
            return XCTFail("expected a fully revealed exact mutation")
        }
        XCTAssertEqual(ready.fixture.model.source, expected)
        XCTAssertEqual(ready.fixture.model.publications, [expected])
        XCTAssertEqual(ready.controller.replacementScheduleCount, 1)
        XCTAssertEqual(ready.controller.editScheduleCount, 0)
        assertCanonical(ready, source: expected)
        _ = reparse(ready, selection: NSRange(location: 0, length: 0))
        ready.fixture.textView.undoManager?.undo()
        XCTAssertEqual(ready.fixture.model.source, source)
        _ = reparse(ready, selection: NSRange(location: 0, length: 0))
        if let imageConfiguration { configureImages(ready, imageConfiguration) }
        assertCanonical(ready, source: source)
        XCTAssertFalse(ready.fixture.textView.undoManager?.canUndo == true, "presentation added no second undo step")
        XCTAssertTrue(ready.fixture.textView.undoManager?.canRedo == true)
        ready.fixture.textView.undoManager?.redo()
        XCTAssertEqual(ready.fixture.model.source, expected)
        _ = reparse(ready, selection: NSRange(location: 0, length: 0))
        assertCanonical(ready, source: expected)
    }

    @discardableResult
    func reparse(_ ready: EditorReplaceSingleSupport.Ready, selection: NSRange) -> HighlightedText {
        let source = ready.fixture.model.source
        ready.fixture.textView.textSelection = selection
        let highlighted = linkPresentation(source, selection: selection,
                                           revision: ready.fixture.model.revision + 1)
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(highlighted, to: ready.fixture.textView))
        ready.fixture.coordinator.applyImageThumbnailPresentation(foldPlan: highlighted.foldPlan,
                                                                  in: ready.fixture.textView, forceReapply: false)
        XCTAssertEqual(ready.fixture.textView.selectedRange(), selection)
        return highlighted
    }

    func imageConfiguration() -> EditorImageThumbnailConfiguration {
        EditorImageThumbnailConfiguration(loader: TestEditorImageThumbnailLoader(outcomes: [:]),
                                          rootURL: URL(fileURLWithPath: "/tmp/PlainsongReplaceImageTests"),
                                          documentDirectoryRelativePath: "")
    }

    func configureImages(
        _ ready: EditorReplaceSingleSupport.Ready,
        _ config: EditorImageThumbnailConfiguration
    ) {
        ready.fixture.coordinator.updateImageThumbnailPresentationConfiguration(config,
                                                                                documentIdentity: ready.fixture
                                                                                    .coordinator
                                                                                    .currentDocumentIdentity,
                                                                                isPresentationEnabled: true,
                                                                                in: ready.fixture.textView)
        _ = reparse(ready, selection: ready.fixture.textView.selectedRange())
    }

    func hasHiddenAttributes(_ ready: EditorReplaceSingleSupport.Ready) -> Bool {
        guard let storage = MarkdownTextView.textStorage(of: ready.fixture.textView) else { return false }
        var hidden = false
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, _, _ in
            hidden = hidden || WYSIWYGInlineFoldPresentation.containsFoldedDelimiterAttributes(attrs)
                || (attrs[WYSIWYGImagePresentationMarker.attribute] as? WYSIWYGImagePresentationMarker).map {
                    $0.generation == ready.fixture.textView.wysiwygZeroWidthContentStorageDelegate?
                        .imagePresentationGeneration
                } == true
        }
        return hidden
    }

    func assertCanonical(_ ready: EditorReplaceSingleSupport.Ready, source: String) {
        let view = ready.fixture.textView
        XCTAssertEqual(EditorReplaceBatchSpikeSupport.viewText(in: view), source)
        XCTAssertEqual(view.accessibilityValue() as? String, source)
        XCTAssertFalse(source.contains("\u{FFFC}"))
        XCTAssertFalse(source.contains("\u{200B}"))
        let range = view.selectedRange()
        XCTAssertEqual(view.accessibilitySelectedText() as? String, (source as NSString).substring(with: range))
        view.textSelection = NSRange(location: 0, length: (source as NSString).length)
        defer { view.textSelection = range }
        let board = NSPasteboard(name: NSPasteboard.Name("ReplaceWYSIWYG-\(UUID().uuidString)"))
        XCTAssertTrue(view.writeSelection(to: board, types: [.string]))
        XCTAssertEqual(board.string(forType: .string), source)
    }
}
