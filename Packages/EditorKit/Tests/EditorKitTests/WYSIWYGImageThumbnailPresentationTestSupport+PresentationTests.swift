import AppKit
@testable import EditorKit
import MarkdownCore
import STTextView
import XCTest

@MainActor
extension WYSIWYGImageThumbnailPresentationTests {
    typealias WindowedEditor = WYSIWYGImageThumbnailGateSupport.WindowedEditor

    static var imageSource: String {
        WYSIWYGImageThumbnailGateSupport.imageSource
    }

    static var source: String {
        WYSIWYGImageThumbnailGateSupport.source
    }

    static var imageRange: NSRange {
        WYSIWYGImageThumbnailGateSupport.imageRange
    }

    static var repoRoot: URL {
        WYSIWYGImageThumbnailGateSupport.repoRoot
    }

    func makeWindowedEditor(
        source: String? = nil,
        selection: NSRange = NSRange(location: 0, length: 0),
        frame: NSRect = NSRect(x: 0, y: 0, width: 760, height: 420),
        pinnedTextContainerWidth: CGFloat? = nil,
        outcomes: [String: EditorImageThumbnailOutcome]? = nil,
        delayNanoseconds: UInt64 = 0,
        linkFoldingEnabled: Bool = true,
        refreshProxy: EditorImageThumbnailRefreshProxy? = nil
    ) throws -> WindowedEditor {
        try WYSIWYGImageThumbnailGateSupport.makeWindowedEditor(
            source: source,
            selection: selection,
            frame: frame,
            pinnedTextContainerWidth: pinnedTextContainerWidth,
            outcomes: outcomes,
            delayNanoseconds: delayNanoseconds,
            linkFoldingEnabled: linkFoldingEnabled,
            refreshProxy: refreshProxy
        )
    }

    func applyPresentation(
        source: String,
        selection: NSRange,
        linkFoldingEnabled: Bool = true,
        coordinator: MarkdownTextViewCoordinator,
        textView: MarkdownSTTextView
    ) {
        WYSIWYGImageThumbnailGateSupport.applyPresentation(
            source: source,
            selection: selection,
            linkFoldingEnabled: linkFoldingEnabled,
            coordinator: coordinator,
            textView: textView
        )
    }

    func waitForMarker(
        in textView: MarkdownSTTextView,
        range: NSRange,
        matching predicate: @escaping (WYSIWYGImagePresentationMarker) -> Bool = { _ in true },
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async throws -> WYSIWYGImagePresentationMarker {
        try await WYSIWYGImageThumbnailGateSupport.waitForMarker(
            in: textView,
            range: range,
            matching: predicate,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    func waitForRequestCount(
        _ expectedCount: Int,
        loader: TestEditorImageThumbnailLoader,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async throws {
        try await WYSIWYGImageThumbnailGateSupport.waitForRequestCount(
            expectedCount,
            loader: loader,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    func imageMarker(
        in textView: MarkdownSTTextView,
        range: NSRange
    ) -> WYSIWYGImagePresentationMarker? {
        WYSIWYGImageThumbnailGateSupport.imageMarker(in: textView, range: range)
    }

    @discardableResult
    func assertLiveAttachment(
        in textView: STTextView,
        imageRange: NSRange,
        expectedSize: NSSize? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSTextLineFragment {
        try WYSIWYGImageThumbnailGateSupport.assertLiveAttachment(
            in: textView,
            imageRange: imageRange,
            expectedSize: expectedSize,
            file: file,
            line: line
        )
    }

    func clickAttachment(in fixture: WindowedEditor, imageRange: NSRange) throws -> Int {
        try WYSIWYGImageThumbnailGateSupport.clickAttachment(in: fixture, imageRange: imageRange)
    }

    func projectedImageParagraph(
        in textView: MarkdownSTTextView,
        imageRange: NSRange
    ) throws -> (NSTextParagraph, NSRange) {
        try WYSIWYGImageThumbnailGateSupport.projectedImageParagraph(
            in: textView,
            imageRange: imageRange
        )
    }

    func ensureLayout(in textView: STTextView) {
        WYSIWYGImageThumbnailGateSupport.ensureLayout(in: textView)
    }

    func lineFragmentFrame(containing range: NSRange, in textView: STTextView) throws -> CGRect {
        try WYSIWYGImageThumbnailGateSupport.lineFragmentFrame(containing: range, in: textView)
    }

    func lineFragment(containing range: NSRange, in textView: STTextView) throws -> NSTextLineFragment {
        try WYSIWYGImageThumbnailGateSupport.lineFragment(containing: range, in: textView)
    }

    func layoutFragment(containing range: NSRange, in textView: STTextView) throws -> NSTextLayoutFragment {
        try WYSIWYGImageThumbnailGateSupport.layoutFragment(containing: range, in: textView)
    }

    func uniquePasteboard() -> NSPasteboard {
        WYSIWYGImageThumbnailGateSupport.uniquePasteboard()
    }

    static func readyOutcome(
        source: String,
        resolvedPath: String,
        pixelWidth: Int = 320,
        pixelHeight: Int = 180,
        modificationDate: Date = Date(timeIntervalSinceReferenceDate: 1)
    ) -> EditorImageThumbnailOutcome {
        WYSIWYGImageThumbnailGateSupport.readyOutcome(
            source: source,
            resolvedPath: resolvedPath,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            modificationDate: modificationDate
        )
    }

    static func imageRegion(in source: String, literal: String) -> MarkdownInlineImageRegion {
        WYSIWYGImageThumbnailGateSupport.imageRegion(in: source, literal: literal)
    }
}
