import AppKit
@testable import EditorKit
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

private extension WYSIWYGImageThumbnailPresentationTests {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
