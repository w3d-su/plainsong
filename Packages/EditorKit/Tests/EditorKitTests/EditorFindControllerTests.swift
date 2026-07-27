import AppKit
@testable import EditorKit
import MarkdownCore
import STTextView
import SwiftUI
import XCTest

@MainActor
final class EditorFindControllerTests: XCTestCase {
    private let documentA = EditorDocumentIdentity(rawValue: "find-doc-a")
    private let documentB = EditorDocumentIdentity(rawValue: "find-doc-b")

    // MARK: - F2 structural (off-main, cancel, fence)

    func testMatchWorkRunsOffMainAndIsDebouncedCancellable() async throws {
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: "alpha needle beta needle gamma",
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.setQuery(TextSearchQuery(pattern: "needle"))

        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 2
        }
        XCTAssertTrue(controller.lastMatchRanOffMain)
        XCTAssertEqual(controller.session?.currentOrdinal, 1)
        XCTAssertEqual(controller.completedMatchCount, 1)

        // Rapid query replace cancels prior work; only the latest generation applies.
        controller.debounceNanoseconds = 50_000_000
        controller.setQuery(TextSearchQuery(pattern: "alpha"))
        controller.setQuery(TextSearchQuery(pattern: "gamma"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 1
                && controller.session?.currentMatch?.range
                == ("alpha needle beta needle gamma" as NSString).range(of: "gamma")
        }
        XCTAssertGreaterThanOrEqual(controller.cancelledMatchCount, 0)
    }

    func testStaleMatchCompletionIsDropped() async throws {
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: String(repeating: "needle ", count: 200),
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.setQuery(TextSearchQuery(pattern: "needle"))
        // Immediately rebind with empty text before the first match can apply.
        controller.rebindDocument(
            EditorFindDocumentBinding(identity: documentA, text: "clean", revision: 2)
        )
        controller.setQuery(TextSearchQuery(pattern: "zzz-no-match"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session != nil && controller.session?.total == 0
        }
        // Either stale drops happened, or only the latest generation completed cleanly.
        XCTAssertEqual(controller.session?.total, 0)
        XCTAssertNil(controller.session?.currentMatch)
    }

    // MARK: - F3 exact navigation

    func testActivateEmitsExactUTF16NavigationWithMonotonicIDs() async throws {
        let text = "prefix 🧪 target suffix"
        let target = (text as NSString).range(of: "target")
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: text,
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.setQuery(TextSearchQuery(pattern: "target"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { controller.session?.total == 1 }

        guard case let .navigate(first)? = controller.pendingNavigationCommand else {
            return XCTFail("Expected navigation command after match")
        }
        XCTAssertEqual(first.documentIdentity, documentA)
        XCTAssertEqual(first.selection, target)

        controller.activateCurrentMatch()
        guard case let .navigate(second)? = controller.pendingNavigationCommand else {
            return XCTFail("Expected second navigation")
        }
        XCTAssertEqual(second.selection, target)
        XCTAssertGreaterThan(second.id, first.id, "re-activation needs a fresh monotonic ID")

        controller.findNext()
        guard case let .navigate(third)? = controller.pendingNavigationCommand else {
            return XCTFail("Expected third navigation")
        }
        XCTAssertGreaterThan(third.id, second.id)
        XCTAssertEqual(third.selection, target)
    }

    func testNavigationAppliesThroughExistingEditorNavigationPath() async throws {
        let text = (0 ... 200)
            .map { $0 == 150 ? "line \($0) exact find-hit" : "line \($0) filler" }
            .joined(separator: "\n")
        let target = (text as NSString).range(of: "exact find-hit")
        let model = EditorFindControllerTestSupport.FindNavModel(text: text, selection: NSRange(location: 0, length: 0))
        let fixture = try EditorFindControllerTestSupport.makeWindowedFixture(
            model: model,
            source: text,
            documentIdentity: documentA,
            height: 100
        )
        fixture.textView.textSelection = NSRange(location: 0, length: 0)
        let sourceBytes = Data(text.utf8)

        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: text,
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.setQuery(TextSearchQuery(pattern: "exact find-hit"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { controller.session?.total == 1 }

        let command = try XCTUnwrap(controller.pendingNavigationCommand)
        fixture.coordinator.observeNavigationCommand(command)
        fixture.coordinator.applyPendingNavigationIfPossible(in: fixture.textView)

        XCTAssertEqual(fixture.textView.selectedRange(), target)
        XCTAssertEqual(Data(EditorFindControllerTestSupport.viewText(in: fixture.textView).utf8), sourceBytes)
        XCTAssertFalse(fixture.textView.undoManager?.canUndo == true)
    }

    // MARK: - F4 edit invalidation

    func testEditInvalidatesAndRecomputesWithoutStaleJump() async throws {
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: "one needle two needle",
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.setQuery(TextSearchQuery(pattern: "needle"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { controller.session?.total == 2 }
        XCTAssertEqual(controller.session?.matches.count, 2)
        let secondOld = try XCTUnwrap(controller.session?.matches.last?.range)

        controller.documentTextDidChange(text: "one needle only", revision: 2)
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 1
                && controller.documentBinding.revision == 2
        }
        XCTAssertEqual(controller.session?.total, 1)
        let only = ("one needle only" as NSString).range(of: "needle")
        XCTAssertEqual(controller.session?.currentMatch?.range, only)
        // The removed second match from revision 1 must not remain
        XCTAssertNotEqual(controller.session?.matches.last?.range.location, secondOld.location)
        XCTAssertEqual(controller.session?.matches.count, 1)
    }

    // MARK: - F4b controller half

    func testRebindToNewDocumentClearsOldMatchesAndReruns() async throws {
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: "document A has apple",
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.setQuery(TextSearchQuery(pattern: "apple"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { controller.session?.total == 1 }
        XCTAssertEqual(
            controller.pendingNavigationCommand.map(\.id),
            controller.pendingNavigationCommand.map(\.id)
        )

        controller.rebindDocument(
            EditorFindDocumentBinding(
                identity: documentB,
                text: "document B has apple and apple",
                revision: 1
            )
        )
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            controller.session?.total == 2
                && controller.documentBinding.identity == self.documentB
        }
        XCTAssertEqual(controller.session?.total, 2)
        if case let .navigate(request)? = controller.pendingNavigationCommand {
            XCTAssertEqual(request.documentIdentity, documentB)
        } else {
            XCTFail("Expected navigation for document B")
        }
    }

    func testClearForNoDocumentCancelsAndClearsSession() async throws {
        let controller = EditorFindController(
            documentBinding: EditorFindDocumentBinding(
                identity: documentA,
                text: "needle",
                revision: 1
            )
        )
        controller.debounceNanoseconds = 0
        controller.setQuery(TextSearchQuery(pattern: "needle"))
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) { controller.session?.total == 1 }

        controller.clearForNoDocument()
        XCTAssertNil(controller.session)
        XCTAssertNil(controller.pendingNavigationCommand)
        XCTAssertEqual(controller.documentBinding, .empty)
    }

    // MARK: - F5 WYSIWYG + source configurations

    func testExperimentalWYSIWYGFindNavigationRevealsMatchWithoutSourceMutation() async throws {
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

        let revealed = editorNavigationWYSIWYGPresentation(source, selection: target, revision: 2)
        let revealedRegion = try XCTUnwrap(revealed.foldPlan?.regions.first { $0.kind == .strong })
        XCTAssertTrue(revealedRegion.isRevealed)
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(revealed, to: fixture.textView))
        XCTAssertEqual(fixture.textView.selectedRange(), target)
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
        // WYSIWYG folding off (source-only control)
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

    func testSourcePreviewFindNavigationUsesSameSelectionChannel() async throws {
        // Source+preview keeps the same EditorNavigationRequest path; scroll proxy is
        // driven by selection change (Decision Log 2026-06-25). Prove selection+reveal.
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
        let initialOrigin = fixture.scrollView.contentView.bounds.origin

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
        XCTAssertGreaterThanOrEqual(
            fixture.scrollView.contentView.bounds.origin.y,
            initialOrigin.y
        )
    }
}
