@testable import EditorKit
import SwiftUI
import XCTest

final class EditorSelectionPublicationTests: XCTestCase {
    @MainActor
    func testSameDocumentRepresentableNavigationPublishesOnNextMainTurn() async throws {
        var source = "source"
        var selection: NSRange? = NSRange(location: 1, length: 0)
        let textBinding = Binding(get: { source }, set: { source = $0 })
        let selectionBinding = Binding(get: { selection }, set: { selection = $0 })
        let coordinator = MarkdownTextViewCoordinator(
            text: textBinding,
            selection: selectionBinding
        )
        let scrollView = MarkdownSTTextView.scrollableTextView()
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.text = source
        let candidate = coordinator.prepareDocumentTransition(
            text: textBinding,
            selection: selectionBinding,
            documentIdentity: EditorDocumentIdentity(rawValue: "same"),
            navigationCommand: nil,
            in: textView
        )
        XCTAssertNotNil(coordinator.finishDocumentTransition(candidate, in: textView))
        let target = NSRange(location: 3, length: 2)

        coordinator.beginRepresentableUpdate()
        coordinator.publishAppliedSelection(target)
        coordinator.endRepresentableUpdate()
        XCTAssertEqual(selection, NSRange(location: 1, length: 0))

        await drainMainQueue()
        XCTAssertEqual(selection, target)
    }

    @MainActor
    func testObservedSelectionDuringRepresentableUpdateDefersAndLatestReceiptWins() async {
        var selection: NSRange? = NSRange(location: 1, length: 0)
        let coordinator = MarkdownTextViewCoordinator(
            text: .constant("source"),
            selection: Binding(get: { selection }, set: { selection = $0 })
        )
        let stale = NSRange(location: 3, length: 2)
        let latest = NSRange(location: 7, length: 0)

        coordinator.beginRepresentableUpdate()
        coordinator.publishObservedSelection(stale)
        coordinator.publishObservedSelection(latest)
        coordinator.endRepresentableUpdate()
        XCTAssertEqual(selection, NSRange(location: 1, length: 0))

        await drainMainQueue()
        XCTAssertEqual(selection, latest)
    }

    @MainActor
    func testInvalidationDropsDeferredSelectionReceipt() async {
        var selection: NSRange? = NSRange(location: 1, length: 0)
        let coordinator = MarkdownTextViewCoordinator(
            text: .constant("source"),
            selection: Binding(get: { selection }, set: { selection = $0 })
        )

        coordinator.beginRepresentableUpdate()
        coordinator.publishAppliedSelection(NSRange(location: 3, length: 2))
        coordinator.endRepresentableUpdate()
        coordinator.invalidateDeferredSelectionPublication()

        await drainMainQueue()
        XCTAssertEqual(selection, NSRange(location: 1, length: 0))
    }

    @MainActor
    func testOldDocumentDeferredReceiptCannotWriteNewDocumentBinding() async throws {
        var sourceA = "document a"
        var sourceB = "document b"
        var selectionA: NSRange? = NSRange(location: 1, length: 0)
        var selectionB: NSRange? = NSRange(location: 2, length: 0)
        let textA = Binding(get: { sourceA }, set: { sourceA = $0 })
        let textB = Binding(get: { sourceB }, set: { sourceB = $0 })
        let bindingA = Binding(get: { selectionA }, set: { selectionA = $0 })
        let bindingB = Binding(get: { selectionB }, set: { selectionB = $0 })
        let coordinator = MarkdownTextViewCoordinator(text: textA, selection: bindingA)
        let scrollView = MarkdownSTTextView.scrollableTextView()
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.text = sourceA

        let candidateA = coordinator.prepareDocumentTransition(
            text: textA,
            selection: bindingA,
            documentIdentity: EditorDocumentIdentity(rawValue: "a"),
            navigationCommand: nil,
            in: textView
        )
        XCTAssertNotNil(coordinator.finishDocumentTransition(candidateA, in: textView))

        coordinator.beginRepresentableUpdate()
        coordinator.publishAppliedSelection(NSRange(location: 5, length: 1))
        coordinator.endRepresentableUpdate()

        let candidateB = coordinator.prepareDocumentTransition(
            text: textB,
            selection: bindingB,
            documentIdentity: EditorDocumentIdentity(rawValue: "b"),
            navigationCommand: nil,
            in: textView
        )
        coordinator.isUpdating = true
        textView.text = sourceB
        coordinator.isUpdating = false
        XCTAssertNotNil(coordinator.finishDocumentTransition(candidateB, in: textView))

        await drainMainQueue()
        XCTAssertEqual(selectionA, NSRange(location: 1, length: 0))
        XCTAssertEqual(selectionB, NSRange(location: 2, length: 0))
    }

    @MainActor
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
