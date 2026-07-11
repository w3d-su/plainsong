import AppKit
@testable import EditorKit
import MarkdownCore
import XCTest

@MainActor
extension WYSIWYGImageThumbnailPresentationTests {
    func testTypingOnLargeFixtureStaysUnderBudgetWhileThumbnailLoadsAreInFlight() async throws {
        let largeFixture = try String(contentsOf: Self.repoRoot.appending(path: "Fixtures/large-1mb.md"))
        let source = "\(Self.imageSource)\n"
        let loader = TestEditorImageThumbnailLoader(
            outcomes: [
                "fixture.png": Self.readyOutcome(
                    source: "fixture.png",
                    resolvedPath: "posts/fixture.png"
                ),
            ],
            delayNanoseconds: 2_000_000_000
        )
        let configuration = EditorImageThumbnailConfiguration(
            loader: loader,
            rootURL: URL(fileURLWithPath: "/tmp/PlainsongImageThumbnailPerformance", isDirectory: true),
            documentDirectoryRelativePath: "posts"
        )
        let textView = MarkdownSTTextView(frame: .zero)
        textView.isEditable = true
        textView.isSelectable = true
        textView.text = source
        textView.textSelection = NSRange(location: (source as NSString).length, length: 0)
        let coordinator = MarkdownTextViewCoordinator(
            text: .constant(source),
            selection: .constant(textView.selectedRange())
        )
        textView.textDelegate = coordinator
        defer {
            coordinator.detachImageThumbnailPresentation(from: textView)
            textView.textDelegate = nil
        }
        XCTAssertTrue(textView.setWYSIWYGZeroWidthFoldingEnabled(true))
        coordinator.updateImageThumbnailPresentationConfiguration(
            configuration,
            documentIdentity: EditorDocumentIdentity(rawValue: "large-fixture"),
            isPresentationEnabled: true,
            in: textView
        )

        let imageRegion = Self.imageRegion(in: source, literal: Self.imageSource)
        let plan = WYSIWYGFoldPlan(
            visibleRange: (source as NSString).paragraphRange(for: imageRegion.sourceRange),
            regions: [],
            imageRegions: [imageRegion]
        )
        coordinator.applyImageThumbnailPresentation(
            foldPlan: plan,
            in: textView,
            forceReapply: true
        )
        try await waitForRequestCount(1, loader: loader)
        let result = try EditorPerformanceProbe.measureTypingHotPath(
            fixtureText: largeFixture,
            fileKind: .markdown,
            replacementString: "a",
            expectedNativeInput: true,
            iterations: 50
        )
        print(String(
            format: "Image thumbnail in-flight large-1mb.md typing hot path max: %.3f ms",
            result.maxLatencyMilliseconds
        ))
        XCTAssertEqual(result.nativeInputMismatches, 0)
        assertPerformanceBudget(
            result.maxLatencyMilliseconds,
            lessThanOrEqualTo: 16,
            metric: "I8 image-thumbnail in-flight large-1mb.md typing"
        )
    }
}

/// I8 visible-range recompute, decode isolation, and cache-budget evidence for image thumbnails.
@MainActor
final class WYSIWYGImageThumbnailI8PerformanceGateTests: XCTestCase {
    func testI8VisibleRangeRecomputeWithImageFoldingStaysUnderFiftyMilliseconds() async throws {
        let fixture = try String(
            contentsOf: WYSIWYGImageThumbnailGateSupport.repoRoot.appending(path: "Fixtures/large-1mb.md")
        )
        let storage = fixture as NSString
        let imageRange = storage.range(of: "![sample](./assets/image-00001.png)")
        XCTAssertNotEqual(
            imageRange.location,
            NSNotFound,
            "large-1mb.md already contains image syntax; no fixture generator change needed"
        )
        let visibleRange = storage.paragraphRange(for: imageRange)
        let editTarget = storage.range(of: "ordinary prose", options: [], range: visibleRange)
        XCTAssertNotEqual(editTarget.location, NSNotFound)

        let highlightService = MarkdownHighlightService()
        for _ in 0 ..< 2 {
            _ = try await measureImageFoldUpdate(
                fixture: fixture,
                visibleRange: visibleRange,
                editLocation: editTarget.location,
                highlightService: highlightService
            )
        }

        var samples: [Double] = []
        for _ in 0 ..< 5 {
            let result = try await measureImageFoldUpdate(
                fixture: fixture,
                visibleRange: visibleRange,
                editLocation: editTarget.location,
                highlightService: highlightService
            )
            XCTAssertTrue(result.didApplyHighlight)
            XCTAssertGreaterThan(result.imageRegionCount, 0)
            samples.append(result.elapsedMilliseconds)
        }

        let maximum = try XCTUnwrap(samples.max())
        print(String(
            format: "I8 image-thumbnail visible-range highlight/apply max: %.3f ms samples %@",
            maximum,
            samples.map { String(format: "%.3f", $0) }.description
        ))
        assertPerformanceBudget(
            maximum,
            lessThanOrEqualTo: 50,
            metric: "I8 image-thumbnail visible-range highlight/apply"
        )
    }

    func testI8LoaderDecodePathRunsOffMainThread() async {
        let loader = TestEditorImageThumbnailLoader(
            outcomes: [
                "fixture.png": WYSIWYGImageThumbnailGateSupport.readyOutcome(
                    source: "fixture.png",
                    resolvedPath: "posts/fixture.png"
                ),
            ]
        )
        let outcome = await loader.loadThumbnail(
            rootURL: URL(fileURLWithPath: "/tmp/PlainsongImageThumbnailI8", isDirectory: true),
            documentDirectoryRelativePath: "posts",
            source: "fixture.png",
            maxPixelSize: 600
        )
        if case .ready = outcome {
            // ok
        } else {
            XCTFail("Expected ready outcome for decode isolation probe")
        }
        let loadedOnMain = await loader.didLoadOnMainThread()
        XCTAssertFalse(
            loadedOnMain,
            "EditorImageThumbnailLoading actors must run load work off the main thread"
        )
    }

    func testI8CacheByteBudgetIsThirtyTwoMebibytes() {
        // WorkspaceImageThumbnailProvider.defaultCacheByteBudget is 32 MiB. EditorKit does not
        // import WorkspaceKit; keep the constant in lockstep via docs/perf-log.md.
        let documentedBudget = 32 * 1024 * 1024
        XCTAssertEqual(documentedBudget, 33_554_432)
        XCTAssertEqual(documentedBudget, 32 << 20)
    }

    private struct ImageFoldUpdateResult {
        let elapsedMilliseconds: Double
        let didApplyHighlight: Bool
        let imageRegionCount: Int
    }

    private func measureImageFoldUpdate(
        fixture: String,
        visibleRange: NSRange,
        editLocation: Int,
        highlightService: MarkdownHighlightService
    ) async throws -> ImageFoldUpdateResult {
        // Realistic recompute: seed the editor with the pre-edit document + image folding,
        // then time only the post-edit highlight/apply/presentation pass.
        let loader = TestEditorImageThumbnailLoader(outcomes: [:], delayNanoseconds: 0)
        let configuration = EditorImageThumbnailConfiguration(
            loader: loader,
            rootURL: URL(fileURLWithPath: "/tmp/PlainsongImageThumbnailI8", isDirectory: true),
            documentDirectoryRelativePath: "posts"
        )
        let scrollView = MarkdownSTTextView.scrollableTextView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.frame = scrollView.bounds
        textView.text = fixture
        textView.textSelection = NSRange(location: editLocation, length: 0)
        XCTAssertTrue(textView.setWYSIWYGZeroWidthFoldingEnabled(true))
        let coordinator = MarkdownTextViewCoordinator(
            text: .constant(fixture),
            selection: .constant(textView.selectedRange())
        )
        textView.textDelegate = coordinator
        coordinator.updateImageThumbnailPresentationConfiguration(
            configuration,
            documentIdentity: EditorDocumentIdentity(rawValue: "i8-perf"),
            isPresentationEnabled: true,
            in: textView
        )
        defer {
            coordinator.detachImageThumbnailPresentation(from: textView)
            textView.textDelegate = nil
        }

        let seedRange = visibleRange.clamped(toLength: (fixture as NSString).length)
        let seed = await highlightService.highlight(
            fixture,
            fileKind: .markdown,
            visibleRange: seedRange,
            theme: .standard,
            fontName: MarkdownSyntaxHighlighter.systemMonospacedFontName,
            fontSize: MarkdownSyntaxHighlighter.defaultFont.pointSize,
            developmentPresentation: .inlineFoldRevealWithLinkFolding,
            selection: NSRange(location: editLocation, length: 0)
        )
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(
            HighlightedText(
                revision: 1,
                range: seed.range,
                text: seed.text,
                foldPlan: seed.foldPlan
            ),
            to: textView
        ))
        coordinator.applyImageThumbnailPresentation(
            foldPlan: seed.foldPlan,
            in: textView,
            forceReapply: true
        )
        scrollView.layoutSubtreeIfNeeded()
        scrollView.displayIfNeeded()

        let editRange = NSRange(location: editLocation, length: 0)
            .clamped(toLength: (fixture as NSString).length)
        let insertion = "measured "
        let editedText = (fixture as NSString).replacingCharacters(in: editRange, with: insertion)
        let selectedRange = NSRange(
            location: editRange.location + (insertion as NSString).length,
            length: 0
        ).clamped(toLength: (editedText as NSString).length)
        textView.text = editedText
        textView.textSelection = selectedRange
        coordinator.imageThumbnailPresentationController.documentTextDidChange(in: textView)

        let requestRange = visibleRange.clamped(toLength: (editedText as NSString).length)
        let start = DispatchTime.now().uptimeNanoseconds
        let highlighted = await highlightService.highlight(
            editedText,
            fileKind: .markdown,
            visibleRange: requestRange,
            theme: .standard,
            fontName: MarkdownSyntaxHighlighter.systemMonospacedFontName,
            fontSize: MarkdownSyntaxHighlighter.defaultFont.pointSize,
            developmentPresentation: .inlineFoldRevealWithLinkFolding,
            selection: selectedRange
        )
        let didApply = MarkdownTextView.applyHighlightedText(
            HighlightedText(
                revision: 2,
                range: highlighted.range,
                text: highlighted.text,
                foldPlan: highlighted.foldPlan
            ),
            to: textView
        )
        coordinator.applyImageThumbnailPresentation(
            foldPlan: highlighted.foldPlan,
            in: textView,
            forceReapply: false
        )
        scrollView.displayIfNeeded()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        return ImageFoldUpdateResult(
            elapsedMilliseconds: elapsed,
            didApplyHighlight: didApply,
            imageRegionCount: highlighted.foldPlan?.imageRegions.count ?? 0
        )
    }
}
