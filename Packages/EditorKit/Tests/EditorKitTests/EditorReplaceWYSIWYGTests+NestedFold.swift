import AppKit
@testable import EditorKit
import MarkdownCore
import XCTest

/// PR F review: selection-driven reveal opens only the regions the selection touches.
/// A construct nested inside a revealed owner, but untouched by the match, keeps its
/// own fold, so the proof must not require it revealed or Replace would refuse forever.
@MainActor
extension EditorReplaceWYSIWYGTests {
    func testNestedFoldInLinkTextStillRejectsEveryHiddenChromePiece() async throws {
        let source = "Intro [**bold** text](https://host/a \"T\") tail"
        for piece in ["[", "]", "(", "https://host/a", "\"T\"", ")", "](https://host/a \"T\")"] {
            let ready = try await foldedReady(source: source, pattern: "text")
            try navigateAndReveal(ready, replacement: "TEXT")
            let nested = try region(.strong, in: ready)
            XCTAssertFalse(nested.isRevealed, "untouched nested bold remains folded")
            let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: ready.fixture.textView))
            let hidden = (source as NSString).range(of: piece)
            XCTAssertNotEqual(hidden.location, NSNotFound)
            storage.addAttribute(WYSIWYGInlineFoldPresentation.foldedDelimiterAttribute,
                                 value: true, range: hidden)
            XCTAssertEqual(EditorReplaceSingleSupport.perform(ready, replacement: "TEXT"),
                           .refused(.wysiwygRangeNotRevealed), "hidden chrome: \(piece)")
            XCTAssertEqual(ready.fixture.model.writerActivations, 0)
            XCTAssertEqual(ready.fixture.model.publications, [])
            XCTAssertEqual(ready.fixture.model.source, source)
            XCTAssertEqual(ready.fixture.model.revision, 0)
            XCTAssertFalse(ready.fixture.textView.undoManager?.canUndo == true)
        }
    }

    func testRevealedLinkChromeWithUntouchedNestedBoldCommits() async throws {
        try await assertNestedFoldCommits(source: "Intro [**bold** text](https://host/a \"T\") tail",
                                          pattern: "text", replacement: "TEXT", owner: .link, nested: .strong)
    }

    func testHeadingOwnerWithUntouchedFoldedStrongCommits() async throws {
        try await assertNestedFoldCommits(source: "# Title **bold** word", pattern: "word", replacement: "WORD",
                                          owner: .heading(level: 1), nested: .strong)
    }

    func testHeadingOwnerWithUntouchedFoldedLinkCommits() async throws {
        try await assertNestedFoldCommits(source: "## See [Astro](https://astro.build) docs", pattern: "docs",
                                          replacement: "DOCS", owner: .heading(level: 2), nested: .link)
    }

    func testLinkDestinationWithUntouchedFoldedCodeInLinkTextCommits() async throws {
        try await assertNestedFoldCommits(source: "Intro [`code` docs](https://host/a) tail", pattern: "host",
                                          replacement: "HOST", owner: .link, nested: .inlineCode)
    }

    func testStrongOwnerWithUntouchedFoldedEmphasisCommits() async throws {
        try await assertNestedFoldCommits(source: "Intro **very *it* note** tail", pattern: "note",
                                          replacement: "NOTE", owner: .strong, nested: .emphasis)
    }

    func testHeadingOwnerWithUntouchedImageProjectionCommits() async throws {
        let source = "# Title ![alt](fixture.png) word"
        let ready = try await foldedReady(source: source, pattern: "word")
        let configuration = imageConfiguration()
        configureImages(ready, configuration)
        let imageRange = (source as NSString).range(of: "![alt](fixture.png)")
        _ = try await WYSIWYGImageThumbnailGateSupport.waitForMarker(in: ready.fixture.textView, range: imageRange)
        try navigateAndReveal(ready, replacement: "WORD")
        XCTAssertNotNil(WYSIWYGImageThumbnailGateSupport.imageMarker(in: ready.fixture.textView, range: imageRange),
                        "an image the match does not overlap keeps its projection")
        XCTAssertEqual(try region(.heading(level: 1), in: ready).isRevealed, true)
        try replaceAndUndoRedo(ready, replacement: "WORD", imageConfiguration: configuration)
        XCTAssertEqual(ready.fixture.model.source, "# Title ![alt](fixture.png) WORD")
    }

    /// PR E's undo contract under WYSIWYG: a rejected publication is `.writeNotApplied`
    /// with no undo step and unchanged raw source. The presentation model is not advanced
    /// and nothing becomes hidden. PR D's restore (`applyReconciledSource`, shared with
    /// source mode) resets the storage attributes, so the folds come back through the
    /// normal reparse rather than surviving in place.
    func testRejectedPublicationWithWYSIWYGLeavesNoUndoStepRawSourceAndRederivablePresentation() async throws {
        let source = "Intro **one** and *two* tail"
        let ready = try await foldedReady(source: source, pattern: "one")
        try navigateAndReveal(ready, replacement: "ONE")
        let before = presentationState(ready)
        let emphasis = (source as NSString).range(of: "*two*")
        XCTAssertTrue(before.foldedRanges.contains(emphasis.location), "the untouched emphasis is folded")
        ready.fixture.model.rejectsPublications = true

        XCTAssertEqual(EditorReplaceSingleSupport.perform(ready, replacement: "ONE"), .refused(.writeNotApplied))

        XCTAssertEqual(ready.fixture.model.source, source)
        XCTAssertEqual(ready.fixture.model.revision, 0)
        XCTAssertEqual(ready.fixture.model.writerActivations, 1)
        XCTAssertFalse(ready.fixture.textView.undoManager?.canUndo == true, "no undo step")
        XCTAssertFalse(ready.fixture.textView.undoManager?.canRedo == true)
        assertCanonical(ready, source: source)
        let refused = presentationState(ready)
        XCTAssertEqual(refused.revision, before.revision, "the applied presentation model is not advanced")
        XCTAssertEqual(refused.sourceRevision, before.sourceRevision)
        XCTAssertTrue(refused.foldedRanges.isSubset(of: before.foldedRanges), "a refused write hides nothing")
        XCTAssertTrue(refused.imageMarkerRanges.isSubset(of: before.imageMarkerRanges))

        _ = reparse(ready, selection: ready.fixture.textView.selectedRange())
        XCTAssertEqual(presentationState(ready).foldedRanges, before.foldedRanges,
                       "the normal reparse re-derives the same presentation from the unchanged source")
        assertCanonical(ready, source: source)
    }

    private func assertNestedFoldCommits(source: String, pattern: String, replacement: String,
                                         owner: WYSIWYGFoldRegion.Kind,
                                         nested: WYSIWYGFoldRegion.Kind) async throws
    {
        let ready = try await foldedReady(source: source, pattern: pattern)
        try navigateAndReveal(ready, replacement: replacement)
        XCTAssertEqual(try region(owner, in: ready).isRevealed, true)
        let nestedRegion = try region(nested, in: ready)
        XCTAssertFalse(nestedRegion.isRevealed, "selection-driven reveal leaves the untouched construct folded")
        let folded = presentationState(ready).foldedRanges
        XCTAssertTrue(nestedRegion.foldRanges.allSatisfy { folded.contains($0.location) },
                      "the nested fold is still hidden when Replace commits")
        let expected = (source as NSString).replacingCharacters(
            in: (source as NSString).range(of: pattern),
            with: replacement
        )
        try replaceAndUndoRedo(ready, replacement: replacement)
        XCTAssertEqual(ready.fixture.model.source, expected)
        // The end of the document is outside every owner, including a first-line heading.
        let outside = NSRange(location: (expected as NSString).length, length: 0)
        let refolded = try XCTUnwrap(reparse(ready, selection: outside).foldPlan?.regions)
        XCTAssertEqual(refolded.count, 2)
        XCTAssertEqual(Set(refolded.filter { !$0.isRevealed }.map(\.kind)), [owner, nested],
                       "the valid owner and nested construct both refold after the selection leaves")
    }

    private func region(_ kind: WYSIWYGFoldRegion.Kind,
                        in ready: EditorReplaceSingleSupport.Ready) throws -> WYSIWYGFoldRegion
    {
        try XCTUnwrap(ready.fixture.textView.replacePresentationSnapshot?.styledText.foldPlan?.regions
            .first { $0.kind == kind })
    }

    private struct PresentationState: Equatable {
        let revision: Int?
        let sourceRevision: Int?
        let foldedRanges: IndexSet
        let imageMarkerRanges: IndexSet
    }

    private func presentationState(_ ready: EditorReplaceSingleSupport.Ready) -> PresentationState {
        let view = ready.fixture.textView
        var folded = IndexSet()
        var images = IndexSet()
        if let storage = MarkdownTextView.textStorage(of: view) {
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
                if WYSIWYGInlineFoldPresentation.containsFoldedDelimiterAttributes(attributes) {
                    folded.insert(integersIn: range.location ..< NSMaxRange(range))
                }
                if attributes[WYSIWYGImagePresentationMarker.attribute] != nil {
                    images.insert(integersIn: range.location ..< NSMaxRange(range))
                }
            }
        }
        return PresentationState(revision: view.replacePresentationSnapshot?.styledText.revision,
                                 sourceRevision: view.replacePresentationSnapshot?.sourceRevision,
                                 foldedRanges: folded, imageMarkerRanges: images)
    }
}
