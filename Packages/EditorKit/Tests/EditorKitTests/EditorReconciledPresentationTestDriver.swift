import AppKit
@testable import EditorKit
import MarkdownCore
import STTextView
import XCTest

/// Drives the production scheduler from the coordinator's reconciliation callback.
/// Holding its debounce makes the raw pending window deterministic; only releasing
/// that wait is needed to derive and apply presentation from the settled source.
@MainActor
final class EditorReconciledPresentationTestDriver {
    let fixture: EditorReplaceBatchSpikeSupport.Fixture
    let presentation: MarkdownEditorDevelopmentPresentation
    private let debounce = ReconciledPresentationDebounce()
    private let service = MarkdownHighlightService()
    private let selectionProvider: () -> NSRange?
    private(set) var selectionAtRequest: NSRange?
    private lazy var scheduler = EditorHighlightScheduler { [debounce] in
        await debounce.wait()
    }

    private(set) var requestCount = 0
    private(set) var completedCount = 0
    private(set) var appliedCount = 0
    private(set) var revision = 100

    init(
        fixture: EditorReplaceBatchSpikeSupport.Fixture,
        presentation: MarkdownEditorDevelopmentPresentation = .inlineFoldRevealWithLinkFolding,
        selectionProvider: (() -> NSRange?)? = nil
    ) {
        self.fixture = fixture
        self.presentation = presentation
        self.selectionProvider = selectionProvider ?? { fixture.textView.selectedRange() }
        fixture.coordinator.reconciledSourcePresentationInvalidationHandler = { [weak self] in
            guard let self else { return 0 }
            return restart()
        }
    }

    func stop() {
        fixture.coordinator.reconciledSourcePresentationInvalidationHandler = nil
        scheduler.cancel()
        let debounce = debounce
        Task { await debounce.release() }
    }

    func releaseAndWaitForApply() async throws {
        await debounce.release()
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            self.appliedCount == 1
        }
    }

    func releaseAndWaitForCompletion() async throws {
        await debounce.release()
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            self.completedCount == 1
        }
    }

    @discardableResult
    func installInitialPresentation() -> HighlightedText {
        let source = EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView)
        let highlighted = Self.freshPresentation(
            source,
            selection: fixture.textView.selectedRange(),
            revision: revision,
            presentation: presentation
        )
        apply(highlighted)
        return highlighted
    }

    func prepareUnappliedPresentation(selection: NSRange) -> HighlightedText {
        revision += 1
        return Self.freshPresentation(
            EditorReplaceBatchSpikeSupport.viewText(in: fixture.textView),
            selection: selection,
            revision: revision,
            presentation: presentation
        )
    }

    static func configureImages(in fixture: EditorReplaceBatchSpikeSupport.Fixture) {
        let configuration = EditorImageThumbnailConfiguration(
            loader: TestEditorImageThumbnailLoader(outcomes: [:]),
            rootURL: URL(fileURLWithPath: "/tmp/PlainsongReconciledPresentationTests"),
            documentDirectoryRelativePath: ""
        )
        fixture.coordinator.updateImageThumbnailPresentationConfiguration(
            configuration,
            documentIdentity: fixture.coordinator.currentDocumentIdentity,
            isPresentationEnabled: true,
            in: fixture.textView
        )
    }

    static func assertRawPending(
        in fixture: EditorReplaceBatchSpikeSupport.Fixture,
        source: String,
        selection: NSRange,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView), file: file, line: line)
        XCTAssertEqual(storage.string, source, file: file, line: line)
        XCTAssertEqual(fixture.textView.selectedRange(), selection, file: file, line: line)
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
            XCTAssertFalse(WYSIWYGInlineFoldPresentation.containsFoldedDelimiterAttributes(attributes),
                           "Pending presentation must leave every delimiter raw", file: file, line: line)
            XCTAssertNil(attributes[WYSIWYGImagePresentationMarker.attribute], file: file, line: line)
        }
        XCTAssertEqual(projectedText(in: fixture.textView), source, file: file, line: line)
        XCTAssertNil(fixture.textView.replacePresentationSnapshot, file: file, line: line)
        XCTAssertNil(fixture.coordinator.lastAppliedHighlightFoldPlan, file: file, line: line)
        XCTAssertFalse(fixture.textView.undoManager?.canUndo == true, file: file, line: line)
        XCTAssertFalse(fixture.textView.undoManager?.canRedo == true, file: file, line: line)
    }

    static func assertMatchesFreshParse(
        in fixture: EditorReplaceBatchSpikeSupport.Fixture,
        presentation: MarkdownEditorDevelopmentPresentation,
        includesImage: Bool = true,
        assertsNoUndoStep: Bool = true,
        findDecoration: EditorFindMatchHighlightRequest? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let source = fixture.model.source
        let selection = fixture.textView.selectedRange()
        let fresh = try EditorReplaceBatchSpikeSupport.makeFixture(
            source: source,
            selection: selection,
            enableWYSIWYG: presentation != .source
        )
        let expected = freshPresentation(source, selection: selection, revision: 1, presentation: presentation)
        if includesImage { configureImages(in: fresh) }
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(expected, to: fresh.textView), file: file, line: line)
        applyFindDecoration(findDecoration, to: fresh.textView)
        fresh.coordinator.applyImageThumbnailPresentation(
            foldPlan: expected.foldPlan,
            in: fresh.textView,
            forceReapply: false
        )
        if includesImage {
            let imageRange = (source as NSString).range(of: "![alt](fixture.png)")
            let actualMarker = try await WYSIWYGImageThumbnailGateSupport.waitForMarker(
                in: fixture.textView, range: imageRange, matching: { $0.visualState == .failed }
            )
            let freshMarker = try await WYSIWYGImageThumbnailGateSupport.waitForMarker(
                in: fresh.textView, range: imageRange, matching: { $0.visualState == .failed }
            )
            XCTAssertEqual(actualMarker.sourceRange, freshMarker.sourceRange, file: file, line: line)
            XCTAssertEqual(actualMarker.source, freshMarker.source, file: file, line: line)
            XCTAssertEqual(actualMarker.altText, freshMarker.altText, file: file, line: line)
            XCTAssertEqual(actualMarker.canvasSize, freshMarker.canvasSize, file: file, line: line)
            XCTAssertEqual(actualMarker.visualState, freshMarker.visualState, file: file, line: line)
        }

        let actual = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView), file: file, line: line)
        let expectedStorage = try XCTUnwrap(MarkdownTextView.textStorage(of: fresh.textView), file: file, line: line)
        XCTAssertTrue(
            attributesWithoutIdentityMarkers(actual).isEqual(to: attributesWithoutIdentityMarkers(expectedStorage)),
            "Syntax, delimiter, link and Find decoration attributes must equal an independent fresh parse",
            file: file, line: line
        )
        XCTAssertEqual(fixture.textView.replacePresentationSnapshot?.styledText.foldPlan, expected.foldPlan,
                       file: file, line: line)
        XCTAssertEqual(projectedText(in: fixture.textView), projectedText(in: fresh.textView), file: file, line: line)
        XCTAssertEqual(actual.string, source, file: file, line: line)
        XCTAssertEqual(fixture.textView.accessibilityValue() as? String, source, file: file, line: line)
        XCTAssertEqual(fixture.textView.selectedRange(), selection, file: file, line: line)
        if assertsNoUndoStep {
            XCTAssertFalse(fixture.textView.undoManager?.canUndo == true, file: file, line: line)
            XCTAssertFalse(fixture.textView.undoManager?.canRedo == true, file: file, line: line)
        }
    }

    private func restart() -> Int {
        requestCount += 1
        selectionAtRequest = selectionProvider()
        revision += 1
        scheduler.restart(revision: revision) { [weak self] revision in
            guard let self else { return }
            let source = fixture.model.source
            let selection = selectionProvider()
            let result = await service.highlight(
                source,
                fileKind: .markdown,
                visibleRange: NSRange(location: 0, length: (source as NSString).length),
                theme: .standard,
                fontName: MarkdownSyntaxHighlighter.systemMonospacedFontName,
                fontSize: MarkdownSyntaxHighlighter.defaultFont.pointSize,
                developmentPresentation: presentation,
                selection: selection
            )
            guard !Task.isCancelled, revision == self.revision else { return }
            let highlighted = HighlightedText(revision: revision, range: result.range,
                                              text: result.text, foldPlan: result.foldPlan)
            if apply(highlighted) { appliedCount += 1 }
            completedCount += 1
        }
        return revision
    }

    @discardableResult
    private func apply(_ highlighted: HighlightedText) -> Bool {
        guard fixture.coordinator.canApplyHighlightRevision(highlighted.revision),
              MarkdownTextView.applyHighlightedText(highlighted, to: fixture.textView)
        else { return false }
        fixture.coordinator.lastAppliedHighlightRevision = highlighted.revision
        fixture.coordinator.lastAppliedHighlightFoldPlan = highlighted.foldPlan
        fixture.coordinator.applyImageThumbnailPresentation(
            foldPlan: highlighted.foldPlan,
            in: fixture.textView,
            forceReapply: false
        )
        return true
    }

    private static func freshPresentation(
        _ source: String,
        selection: NSRange,
        revision: Int,
        presentation: MarkdownEditorDevelopmentPresentation
    ) -> HighlightedText {
        let result = MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (source as NSString).length),
            developmentPresentation: presentation,
            selection: selection
        )
        return HighlightedText(revision: revision, range: result.range, text: result.text, foldPlan: result.foldPlan)
    }

    private static func applyFindDecoration(_ request: EditorFindMatchHighlightRequest?, to textView: STTextView) {
        guard let request, let storage = MarkdownTextView.textStorage(of: textView) else { return }
        _ = EditorFindMatchHighlight.apply(request, visibleRange: nil, previouslyDecorated: nil, to: storage)
    }

    /// Image and Find markers use object identity, so only their value-comparable effects
    /// (fonts, colours, the covered background) take part in the equality oracle.
    private static func attributesWithoutIdentityMarkers(_ storage: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: storage)
        let full = NSRange(location: 0, length: result.length)
        result.removeAttribute(WYSIWYGImagePresentationMarker.attribute, range: full)
        result.removeAttribute(EditorFindMatchHighlightMarker.attribute, range: full)
        return result
    }

    private static func projectedText(in textView: MarkdownSTTextView) -> String {
        guard let storage = MarkdownTextView.textStorage(of: textView),
              let contentStorage = textView.textContentManager as? NSTextContentStorage
        else { return "" }
        let range = NSRange(location: 0, length: storage.length)
        return textView.wysiwygZeroWidthContentStorageDelegate?.textContentStorage(
            contentStorage,
            textParagraphWith: range
        )?.attributedString.string ?? storage.string
    }
}

private actor ReconciledPresentationDebounce {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func wait() async -> Bool {
        if isOpen { return true }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: true)
        }
    }
}
