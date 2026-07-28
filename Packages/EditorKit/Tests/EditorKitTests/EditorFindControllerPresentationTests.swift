import AppKit
@testable import EditorKit
import MarkdownCore
import STTextView
import XCTest

@MainActor
final class EditorFindControllerPresentationTests: XCTestCase {
    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    private let documentA = EditorDocumentIdentity(rawValue: "find-doc-a")

    // MARK: - F5 WYSIWYG off/on (source+preview deferred to PR C)

    func testExperimentalWYSIWYGFindNavigationSelectsMatchAndRevealsFoldRegion() async throws {
        let source = "Intro **folded match** tail\n"
        let target = (source as NSString).range(of: "folded match")
        let outsideSelection = NSRange(location: 0, length: 0)
        let model = EditorFindControllerTestSupport.FindNavModel(text: source, selection: outsideSelection)
        let fixture = try EditorFindControllerTestSupport.makeWindowedFixture(
            model: model,
            source: source,
            documentIdentity: documentA
        )
        XCTAssertTrue(fixture.textView.setWYSIWYGZeroWidthFoldingEnabled(true))
        fixture.textView.textSelection = outsideSelection
        let folded = editorNavigationWYSIWYGPresentation(source, selection: outsideSelection, revision: 1)
        let foldedRegion = try XCTUnwrap(folded.foldPlan?.regions.first { $0.kind == .strong })
        XCTAssertFalse(foldedRegion.isRevealed)
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(folded, to: fixture.textView))
        // Folded: delimiter runs carry the folded-delimiter attribute.
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))
        for foldRange in foldedRegion.foldRanges {
            var effective = NSRange()
            let value = storage.attribute(
                WYSIWYGInlineFoldPresentation.foldedDelimiterAttribute,
                at: foldRange.location,
                effectiveRange: &effective
            ) as? Bool
            XCTAssertEqual(value, true, "pre-navigation delimiters should be folded")
        }
        fixture.textView.undoManager?.removeAllActions()
        let sourceBytes = Data(source.utf8)

        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: source,
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.setQuery(TextSearchQuery(pattern: "folded match"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { controller.session?.total == 1 }

        let command = try XCTUnwrap(controller.pendingNavigationCommand)
        fixture.coordinator.observeNavigationCommand(command)
        fixture.coordinator.applyPendingNavigationIfPossible(in: fixture.textView)

        let appliedSelection = fixture.textView.selectedRange()
        XCTAssertEqual(appliedSelection, target)
        // Recompute presentation from the **post-navigation** selection (not a hardcoded target).
        let revealed = editorNavigationWYSIWYGPresentation(
            source,
            selection: appliedSelection,
            revision: 2
        )
        let revealedRegion = try XCTUnwrap(revealed.foldPlan?.regions.first { $0.kind == .strong })
        XCTAssertTrue(
            revealedRegion.isRevealed,
            "Fold plan driven by the applied selection must mark the strong region revealed"
        )
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(revealed, to: fixture.textView))
        for foldRange in revealedRegion.foldRanges {
            let value = storage.attribute(
                WYSIWYGInlineFoldPresentation.foldedDelimiterAttribute,
                at: foldRange.location,
                effectiveRange: nil
            ) as? Bool
            XCTAssertNotEqual(
                value,
                true,
                "After reveal presentation, delimiter runs must not keep the folded attribute"
            )
        }
        XCTAssertEqual(Data(EditorFindControllerTestSupport.viewText(in: fixture.textView).utf8), sourceBytes)
        XCTAssertFalse(fixture.textView.undoManager?.canUndo == true)
    }

    func testSourceOnlyFindNavigationSelectsWithoutSourceMutation() async throws {
        let source = "plain **not folded** source mode"
        let target = (source as NSString).range(of: "not folded")
        let model = EditorFindControllerTestSupport.FindNavModel(
            text: source,
            selection: NSRange(location: 0, length: 0)
        )
        let fixture = try EditorFindControllerTestSupport.makeWindowedFixture(
            model: model,
            source: source,
            documentIdentity: documentA
        )
        XCTAssertTrue(fixture.textView.setWYSIWYGZeroWidthFoldingEnabled(false))
        let sourceBytes = Data(source.utf8)

        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: source,
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.setQuery(TextSearchQuery(pattern: "not folded"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { controller.session?.total == 1 }

        let command = try XCTUnwrap(controller.pendingNavigationCommand)
        fixture.coordinator.observeNavigationCommand(command)
        fixture.coordinator.applyPendingNavigationIfPossible(in: fixture.textView)

        XCTAssertEqual(fixture.textView.selectedRange(), target)
        XCTAssertEqual(Data(EditorFindControllerTestSupport.viewText(in: fixture.textView).utf8), sourceBytes)
    }

    func testQueryMatchUsesSameNavigationChannelAsWorkspaceSearch() async throws {
        // Proves find emits EditorNavigationRequest over the existing path (selection).
        // Source+preview scroll-proxy coverage is PR C (App layout + live preview).
        let source = (0 ... 80)
            .map { $0 == 40 ? "preview-sync-needle-\($0)" : "line-\($0)" }
            .joined(separator: "\n")
        let target = (source as NSString).range(of: "preview-sync-needle-40")
        let model = EditorFindControllerTestSupport.FindNavModel(
            text: source,
            selection: NSRange(location: 0, length: 0)
        )
        let fixture = try EditorFindControllerTestSupport.makeWindowedFixture(
            model: model,
            source: source,
            documentIdentity: documentA,
            height: 120
        )

        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: source,
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.setQuery(TextSearchQuery(pattern: "preview-sync-needle-40"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { controller.session?.total == 1 }

        let command = try XCTUnwrap(controller.pendingNavigationCommand)
        fixture.coordinator.observeNavigationCommand(command)
        fixture.coordinator.applyPendingNavigationIfPossible(in: fixture.textView)

        XCTAssertEqual(fixture.textView.selectedRange(), target)
    }
}
