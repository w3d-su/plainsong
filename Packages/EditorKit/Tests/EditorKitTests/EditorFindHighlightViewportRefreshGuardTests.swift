import AppKit
@testable import EditorKit
import XCTest

/// The scroll-driven find-highlight refresh writes text-storage attributes, so it holds off
/// during a writer lease or an IME composition like every other presentation write.
@MainActor
final class EditorFindHighlightViewportRefreshGuardTests: XCTestCase {
    func testRefreshWaitsForAPendingWriterLease() throws {
        let fixture = try makeScrolledFixture()
        let before = fixture.coordinator.appliedFindMatchHighlightMaterialisation

        fixture.coordinator.asynchronousTextMutationLeaseCount = 1
        fixture.coordinator.refreshFindMatchHighlightAfterViewportChange(in: fixture.textView)
        XCTAssertEqual(fixture.coordinator.appliedFindMatchHighlightMaterialisation, before)

        fixture.coordinator.asynchronousTextMutationLeaseCount = 0
        fixture.coordinator.refreshFindMatchHighlightAfterViewportChange(in: fixture.textView)
        XCTAssertNotEqual(fixture.coordinator.appliedFindMatchHighlightMaterialisation, before)
    }

    func testRefreshWaitsForMarkedText() throws {
        let fixture = try makeScrolledFixture()
        fixture.textView.setMarkedText(
            "ㄓ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(fixture.textView.hasMarkedText())
        let before = fixture.coordinator.appliedFindMatchHighlightMaterialisation

        fixture.coordinator.refreshFindMatchHighlightAfterViewportChange(in: fixture.textView)

        XCTAssertEqual(fixture.coordinator.appliedFindMatchHighlightMaterialisation, before)
    }

    /// A find request materialised for the document start, with the viewport now at its end.
    private func makeScrolledFixture() throws -> EditorReplaceBatchSpikeSupport.Fixture {
        let source = String(repeating: "A line with a needle in it.\n", count: 400)
        let fixture = try EditorReplaceBatchSpikeSupport.makeFixture(source: source)
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))
        let coordinator = fixture.coordinator
        let request = EditorFindMatchHighlightRequest(
            generation: 1,
            matches: [(source as NSString).range(of: "needle")],
            currentIndex: 0
        )
        let start = NSRange(location: 0, length: 20)
        coordinator.trackFindHighlightEdits(in: storage)
        coordinator.appliedFindMatchHighlightSpan = EditorFindMatchHighlight.apply(
            request, visibleRange: start, previouslyDecorated: nil, to: storage
        )
        coordinator.appliedFindMatchHighlightMaterialisation = EditorFindMatchHighlight.materialisationRange(
            for: start, storageLength: storage.length
        )
        coordinator.appliedFindMatchHighlight = request
        coordinator.lastVisibleTextRange = NSRange(location: storage.length - 20, length: 20)
        return fixture
    }
}
