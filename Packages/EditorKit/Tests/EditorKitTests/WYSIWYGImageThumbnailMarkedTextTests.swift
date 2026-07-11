import AppKit
@testable import EditorKit
import XCTest

@MainActor
extension WYSIWYGImageThumbnailPresentationTests {
    func testImagePresentationSkipsMarkedTextAndReappliesAfterCommit() async throws {
        let fixture = try makeWindowedEditor()
        _ = try await waitForMarker(
            in: fixture.textView,
            range: Self.imageRange,
            matching: { if case .ready = $0.visualState { true } else { false } }
        )
        let composingSource = try beginMarkedText(in: fixture)
        let imageRange = (composingSource as NSString).range(of: Self.imageSource)
        let composingPlan = foldPlan(for: composingSource)
        XCTAssertEqual(composingPlan?.imageRegions.count, 1)
        fixture.coordinator.applyImageThumbnailPresentation(
            foldPlan: composingPlan,
            in: fixture.textView,
            forceReapply: true
        )
        try assertRawImageProjection(in: fixture, imageRange: imageRange)

        fixture.textView.unmarkText()
        XCTAssertFalse(fixture.textView.hasMarkedText())
        let committedSource = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView)?.string)
        let committedPlan = foldPlan(for: committedSource)
        XCTAssertEqual(committedPlan?.imageRegions.count, 1)
        fixture.textView.textSelection = NSRange(location: (committedSource as NSString).length, length: 0)
        fixture.coordinator.applyImageThumbnailPresentation(
            foldPlan: committedPlan,
            in: fixture.textView,
            forceReapply: true
        )
        _ = try await waitForMarker(
            in: fixture.textView,
            range: imageRange,
            matching: { if case .ready = $0.visualState { true } else { false } }
        )
        let projected = try projectedImageParagraph(
            in: fixture.textView,
            imageRange: imageRange
        ).0.attributedString.string
        XCTAssertEqual(projected.unicodeScalars.filter { $0.value == 0xFFFC }.count, 1)
    }

    private func beginMarkedText(in fixture: WindowedEditor) throws -> String {
        fixture.textView.textDelegate = nil
        fixture.textView.textSelection = NSRange(location: 0, length: 0)
        fixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 0, length: 0)
        )
        XCTAssertTrue(fixture.textView.hasMarkedText())
        return try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView)?.string)
    }

    private func foldPlan(for source: String) -> WYSIWYGFoldPlan? {
        MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (source as NSString).length),
            developmentPresentation: .inlineFoldRevealWithLinkFolding,
            selection: NSRange(location: (source as NSString).length, length: 0)
        ).foldPlan
    }

    private func assertRawImageProjection(
        in fixture: WindowedEditor,
        imageRange: NSRange
    ) throws {
        ensureLayout(in: fixture.textView)
        let projected = try lineFragment(
            containing: imageRange,
            in: fixture.textView
        ).attributedString.string
        XCTAssertTrue(projected.contains(Self.imageSource))
        XCTAssertFalse(projected.contains("\u{FFFC}"))
    }
}
