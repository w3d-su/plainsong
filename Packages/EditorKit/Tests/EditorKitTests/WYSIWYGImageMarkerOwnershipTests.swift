import AppKit
@testable import EditorKit
import MarkdownCore
import STTextView
import XCTest

/// The image controller decides what to write by comparing against the markers it believes it
/// applied. These cover the paths that removed marker attributes without telling it.
@MainActor
final class WYSIWYGImageMarkerOwnershipTests: XCTestCase {
    private typealias Support = WYSIWYGImageThumbnailGateSupport

    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testRevealedImageIsProjectedAgainWhenTheNextPlanStillCoversIt() async throws {
        let fixture = try Support.makeWindowedEditor()
        _ = try await Support.waitForMarker(in: fixture.textView, range: Support.imageRange)

        fixture.textView.revealWYSIWYGImagePresentationIfNeeded(at: Support.imageRange.location)
        XCTAssertNil(Support.imageMarker(in: fixture.textView, range: Support.imageRange))

        // The click moved on before a highlight for the touching selection was applied.
        applyUnforcedPresentation(
            source: Support.source,
            selection: NSRange(location: 0, length: 0),
            coordinator: fixture.coordinator,
            textView: fixture.textView
        )

        XCTAssertNotNil(
            Support.imageMarker(in: fixture.textView, range: Support.imageRange),
            "a revealed image the selection no longer touches must be projected again"
        )
    }

    func testSameLengthReplaceAllProjectsTheImageAgain() async throws {
        // Longer than the controller's 64-unit endpoint samples on both sides, so the
        // same-length replacement looks like the recorded source.
        let padding = String(repeating: "padding words ", count: 6)
        let image = "![image](fixture.png)"
        let source = "\(padding)\n\none \(image) one\n\n\(padding)"
        let expected = source.replacingOccurrences(of: "one", with: "ONE")
        let selection = NSRange(location: 0, length: 0)
        let ready = try await EditorReplaceSingleSupport.makeReady(
            source: source, pattern: "one", selection: selection, enableWYSIWYG: true
        )
        let fixture = ready.fixture
        fixture.coordinator.updateImageThumbnailPresentationConfiguration(
            EditorImageThumbnailConfiguration(
                loader: TestEditorImageThumbnailLoader(outcomes: [:]),
                rootURL: URL(fileURLWithPath: "/tmp"),
                documentDirectoryRelativePath: ""
            ),
            documentIdentity: fixture.coordinator.currentDocumentIdentity,
            isPresentationEnabled: true, in: fixture.textView
        )
        Support.applyPresentation(
            source: source, selection: selection,
            coordinator: fixture.coordinator, textView: fixture.textView
        )
        let imageRange = (source as NSString).range(of: image)
        _ = try await Support.waitForMarker(
            in: fixture.textView, range: imageRange, matching: { $0.visualState == .failed }
        )

        let prepared = try EditorReplaceBatchProductSupport.prepare(ready, replacement: "ONE")
        let outcome = EditorReplaceBatchProductSupport.perform(ready, replacement: "ONE", prepared: prepared)
        guard case .replaced = outcome else {
            return XCTFail("expected the batch to be replaced, got \(outcome)")
        }
        XCTAssertEqual(MarkdownTextView.textStorage(of: fixture.textView)?.string, expected)
        XCTAssertNil(Support.imageMarker(in: fixture.textView, range: imageRange))

        applyUnforcedPresentation(
            source: expected,
            selection: fixture.textView.selectedRange(),
            coordinator: fixture.coordinator,
            textView: fixture.textView
        )

        XCTAssertNotNil(
            Support.imageMarker(in: fixture.textView, range: imageRange),
            "the post-write parse must project the image the batch suspended"
        )
    }

    func testEditThatEndsAnImageLeavesNoMarkerBehind() async throws {
        let fixture = try Support.makeWindowedEditor()
        _ = try await Support.waitForMarker(in: fixture.textView, range: Support.imageRange)

        // Without the "!" the span is a link; no plan owns its characters as an image again.
        fixture.textView.insertText(
            "",
            replacementRange: NSRange(location: Support.imageRange.location, length: 1)
        )
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))
        let edited = storage.string
        XCTAssertFalse(edited.contains("!["))

        applyUnforcedPresentation(
            source: edited,
            selection: NSRange(location: 0, length: 0),
            coordinator: fixture.coordinator,
            textView: fixture.textView
        )

        var strandedRanges: [NSRange] = []
        storage.enumerateAttribute(
            WYSIWYGImagePresentationMarker.attribute,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            if value != nil {
                strandedRanges.append(range)
            }
        }
        XCTAssertEqual(strandedRanges, [], "markers of an earlier source must not outlive the next highlight")
    }

    private func applyUnforcedPresentation(
        source: String,
        selection: NSRange,
        coordinator: MarkdownTextViewCoordinator,
        textView: MarkdownSTTextView
    ) {
        textView.textSelection = selection
        let highlighted = MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (source as NSString).length),
            developmentPresentation: .inlineFoldRevealWithLinkFolding,
            selection: selection
        )
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(
            HighlightedText(
                revision: 2,
                range: highlighted.range,
                text: highlighted.text,
                foldPlan: highlighted.foldPlan
            ),
            to: textView
        ))
        coordinator.applyImageThumbnailPresentation(
            foldPlan: highlighted.foldPlan,
            in: textView,
            forceReapply: false
        )
    }
}
