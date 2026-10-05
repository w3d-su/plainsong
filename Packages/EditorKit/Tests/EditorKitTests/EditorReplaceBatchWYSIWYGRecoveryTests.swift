import AppKit
@testable import EditorKit
import MarkdownCore
import STTextView
import XCTest

@MainActor
final class EditorReplaceBatchWYSIWYGRecoveryTests: XCTestCase {
    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testRejectedPublicationResetsImageCacheAndRequestsExactlyOnePresentationDerivation() async throws {
        try await assertFailedBatchRestoresPresentation(rejectPublication: true)
    }

    func testNotAppliedNativeInsertResetsImageCacheAndRequestsExactlyOnePresentationDerivation() async throws {
        try await assertFailedBatchRestoresPresentation(rejectPublication: false)
    }

    private func assertFailedBatchRestoresPresentation(rejectPublication: Bool) async throws {
        let source = "**one** ![image](fixture.png) one **untouched**"
        let selection = NSRange(location: source.utf16.count, length: 0)
        let ready = try await EditorReplaceSingleSupport.makeReady(
            source: source, pattern: "one", selection: selection, enableWYSIWYG: true
        )
        let fixture = ready.fixture
        let loader = TestEditorImageThumbnailLoader(outcomes: [:])
        fixture.coordinator.updateImageThumbnailPresentationConfiguration(
            EditorImageThumbnailConfiguration(
                loader: loader,
                rootURL: URL(fileURLWithPath: "/tmp"),
                documentDirectoryRelativePath: ""
            ),
            documentIdentity: fixture.coordinator.currentDocumentIdentity,
            isPresentationEnabled: true, in: fixture.textView
        )
        func derive() {
            WYSIWYGImageThumbnailGateSupport.applyPresentation(
                source: source, selection: selection,
                coordinator: fixture.coordinator, textView: fixture.textView
            )
        }
        derive()
        let imageRange = (source as NSString).range(of: "![image](fixture.png)")
        _ = try await WYSIWYGImageThumbnailGateSupport.waitForMarker(
            in: fixture.textView, range: imageRange, matching: { $0.visualState == .failed }
        )
        let storage = try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))
        XCTAssertNotNil(storage.attribute(WYSIWYGInlineFoldPresentation.foldedDelimiterAttribute,
                                          at: 0, effectiveRange: nil))
        let prepared = try EditorReplaceBatchProductSupport.prepare(ready, replacement: "ONE")
        var requests = 0
        fixture.coordinator.reconciledSourcePresentationInvalidationHandler = {
            requests += 1
            return requests + 1
        }
        fixture.model.rejectsPublications = rejectPublication
        let refusing = BatchRefusingTextDelegate()
        if !rejectPublication {
            fixture.textView.textDelegate = refusing
        }
        let outcome = EditorReplaceBatchProductSupport.perform(ready, replacement: "ONE", prepared: prepared)
        fixture.textView.textDelegate = fixture.coordinator
        XCTAssertEqual(outcome, .refused(.writeNotApplied))
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(fixture.model.publications.count, rejectPublication ? 1 : 0)
        XCTAssertEqual(refusing.refusals, rejectPublication ? 0 : 1)
        XCTAssertEqual(fixture.model.revision, 0)
        XCTAssertEqual(fixture.model.source, source)
        XCTAssertEqual(fixture.textView.selectedRange(), selection)
        XCTAssertFalse(fixture.textView.undoManager?.canUndo == true)
        // Fulfil the requested fresh parse; forceReapply=false proves the old marker
        // ownership was discarded, rather than forcing attributes over stale caches.
        let highlighted = MarkdownSyntaxHighlighter().highlight(
            source, fileKind: .markdown, visibleRange: NSRange(location: 0, length: source.utf16.count),
            developmentPresentation: .inlineFoldReveal, selection: selection
        )
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(
            HighlightedText(
                revision: 2,
                range: highlighted.range,
                text: highlighted.text,
                foldPlan: highlighted.foldPlan
            ),
            to: fixture.textView
        ))
        fixture.coordinator.applyImageThumbnailPresentation(
            foldPlan: highlighted.foldPlan, in: fixture.textView, forceReapply: false
        )
        _ = try await WYSIWYGImageThumbnailGateSupport.waitForMarker(in: fixture.textView, range: imageRange)
        XCTAssertNotNil(storage.attribute(WYSIWYGInlineFoldPresentation.foldedDelimiterAttribute,
                                          at: 0, effectiveRange: nil))
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(storage.string, source)
    }
}

private final class BatchRefusingTextDelegate: STTextViewDelegate {
    var refusals = 0

    func textView(_: STTextView, shouldChangeTextIn _: NSTextRange, replacementString _: String?) -> Bool {
        refusals += 1
        return false
    }
}
