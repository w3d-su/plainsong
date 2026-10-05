import AppKit
@testable import EditorKit
import MarkdownCore
import SwiftUI
import XCTest

@MainActor
extension EditorDocumentBindingLifecycleTests {
    func testReconciliationHandlerIsClearedOnDismantle() throws {
        let model = Model()
        var calls = 0
        let view = representable(
            text: Binding(get: { model.sourceA }, set: { model.sourceA = $0 }),
            identity: EditorDocumentIdentity(rawValue: "a"),
            bindingID: EditorDocumentBindingID(), model: model,
            onReconciliation: { calls += 1; return calls }
        )
        let fixture = try makeFixture(representable: view, source: model.sourceA)
        defer { fixture.window.orderOut(nil) }
        XCTAssertNotNil(fixture.coordinator.reconciledSourcePresentationInvalidationHandler)

        MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)

        XCTAssertNil(fixture.coordinator.reconciledSourcePresentationInvalidationHandler)
        XCTAssertNil(fixture.coordinator.currentDocumentBindingInstallation)
        fixture.coordinator.applyReconciledSource(model.sourceA, replacing: model.sourceA, in: fixture.textView)
        XCTAssertEqual(calls, 0)
    }

    func testDeferredTransitionKeepsInstalledHandlerUntilDestinationCompletes() async throws {
        try await assertDeferredTransitionHandler(supersede: false)
    }

    func testSupersededDeferredTransitionNeverInstallsStaleHandler() async throws {
        try await assertDeferredTransitionHandler(supersede: true)
    }

    func testReconciliationInsideRepresentableUpdateDefersCallbackUntilSelectionPublication() async throws {
        var source = "Long source beyond heading"
        let oldSelection = NSRange(location: (source as NSString).length, length: 0)
        var selection: NSRange? = oldSelection
        var callbackSelections: [NSRange?] = []
        let view = MarkdownTextView(
            text: Binding(get: { source }, set: { source = $0 }), styledText: nil,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            showsLineNumbers: false,
            onReconciledSourcePresentationInvalidated: {
                callbackSelections.append(selection)
                return 17
            }
        )
        let fixture = try makeFixture(representable: view, source: source)
        defer {
            fixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
        }
        fixture.coordinator.isUpdating = true
        fixture.textView.textSelection = oldSelection
        fixture.coordinator.isUpdating = false
        source = "## Heading"
        let clamped = NSRange(location: (source as NSString).length, length: 0)

        fixture.coordinator.beginRepresentableUpdate()
        fixture.coordinator.applyReconciledSource(source, replacing: "old", in: fixture.textView)
        fixture.coordinator.applyReconciledSource(source, replacing: source, in: fixture.textView)
        fixture.coordinator.endRepresentableUpdate()

        XCTAssertEqual(selection, oldSelection)
        XCTAssertEqual(fixture.textView.selectedRange(), clamped)
        XCTAssertTrue(callbackSelections.isEmpty)
        XCTAssertFalse(fixture.coordinator.canApplyHighlightRevision(16))
        XCTAssertFalse(fixture.coordinator.canApplyHighlightRevision(18))
        await drainReconciliationMainQueue()
        XCTAssertEqual(selection, clamped)
        XCTAssertEqual(callbackSelections, [clamped], "Repeated restores in an update coalesce")
        XCTAssertFalse(fixture.coordinator.canApplyHighlightRevision(16))
        XCTAssertTrue(fixture.coordinator.canApplyHighlightRevision(17))
    }

    func testDismantleCancelsDeferredReconciliationCallback() async throws {
        let model = Model()
        var calls = 0
        let view = representable(
            text: Binding(get: { model.sourceA }, set: { model.sourceA = $0 }),
            identity: EditorDocumentIdentity(rawValue: "a"),
            bindingID: EditorDocumentBindingID(), model: model,
            onReconciliation: { calls += 1; return calls }
        )
        let fixture = try makeFixture(representable: view, source: model.sourceA)
        defer { fixture.window.orderOut(nil) }
        fixture.coordinator.beginRepresentableUpdate()
        fixture.coordinator.applyReconciledSource(model.sourceA, replacing: model.sourceA, in: fixture.textView)
        fixture.coordinator.endRepresentableUpdate()

        MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
        await drainReconciliationMainQueue()

        XCTAssertEqual(calls, 0)
        XCTAssertNil(fixture.coordinator.minimumHighlightRevisionAfterReconciliation)
    }

    func testDocumentTransitionCancelsDeferredReconciliationWithoutCallingEitherHandler() async throws {
        let model = Model()
        var calls: [String] = []
        let viewA = representable(
            text: Binding(get: { model.sourceA }, set: { model.sourceA = $0 }),
            identity: EditorDocumentIdentity(rawValue: "a"),
            bindingID: EditorDocumentBindingID(), model: model,
            onReconciliation: { calls.append("a"); return 17 }
        )
        let viewB = representable(
            text: Binding(get: { model.sourceB }, set: { model.sourceB = $0 }),
            identity: EditorDocumentIdentity(rawValue: "b"),
            bindingID: EditorDocumentBindingID(), model: model,
            onReconciliation: { calls.append("b"); return 18 }
        )
        let fixture = try makeFixture(representable: viewA, source: model.sourceA)
        defer {
            fixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
        }
        fixture.coordinator.beginRepresentableUpdate()
        fixture.coordinator.applyReconciledSource(model.sourceA, replacing: model.sourceA, in: fixture.textView)
        fixture.coordinator.endRepresentableUpdate()

        viewB.updateRepresentedTextView(fixture.scrollView, coordinator: fixture.coordinator)
        await drainReconciliationMainQueue()

        XCTAssertTrue(calls.isEmpty)
        XCTAssertNil(fixture.coordinator.minimumHighlightRevisionAfterReconciliation)
        XCTAssertEqual(fixture.coordinator.reconciledSourcePresentationInvalidationHandler?(), 18)
        XCTAssertEqual(calls, ["b"])
    }

    private func assertDeferredTransitionHandler(supersede: Bool) async throws {
        let model = Model()
        var calls: [String] = []
        let viewA = representable(
            text: Binding(get: { model.sourceA }, set: { model.sourceA = $0 }),
            identity: EditorDocumentIdentity(rawValue: "a"),
            bindingID: EditorDocumentBindingID(), model: model,
            onReconciliation: { calls.append("a"); return 10 }
        )
        let bindingB = EditorDocumentBindingID()
        let viewB = representable(
            text: Binding(get: { model.sourceB }, set: { model.sourceB = $0 }),
            identity: EditorDocumentIdentity(rawValue: "b"), bindingID: bindingB, model: model,
            onReconciliation: { calls.append("b"); return 20 }
        )
        let fixture = try makeFixture(representable: viewA, source: model.sourceA)
        defer {
            fixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
        }
        fixture.textView.textSelection = NSRange(location: (model.sourceA as NSString).length, length: 0)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.setMarkedText("ㄊ", selectedRange: NSRange(location: 1, length: 0), replacementRange: .notFound)

        viewB.updateRepresentedTextView(fixture.scrollView, coordinator: fixture.coordinator)
        XCTAssertEqual(fixture.coordinator.reconciledSourcePresentationInvalidationHandler?(), 10)
        if supersede {
            let viewC = representable(
                text: Binding(get: { model.sourceB }, set: { model.sourceB = $0 }),
                identity: EditorDocumentIdentity(rawValue: "c"),
                bindingID: EditorDocumentBindingID(), model: model,
                onReconciliation: { calls.append("c"); return 30 }
            )
            viewC.updateRepresentedTextView(fixture.scrollView, coordinator: fixture.coordinator)
            XCTAssertEqual(fixture.coordinator.reconciledSourcePresentationInvalidationHandler?(), 10)
        }
        calls.removeAll()
        fixture.textView.insertText("台", replacementRange: .notFound)
        let expectedIdentity = EditorDocumentIdentity(rawValue: supersede ? "c" : "b")
        try await EditorFindControllerTestSupport.waitUntil(timeout: 2) {
            fixture.coordinator.currentDocumentIdentity == expectedIdentity
        }

        XCTAssertEqual(fixture.coordinator.reconciledSourcePresentationInvalidationHandler?(), supersede ? 30 : 20)
        XCTAssertEqual(calls, [supersede ? "c" : "b"])
        XCTAssertEqual(Self.text(in: fixture.textView), model.sourceB)
        XCTAssertEqual(model.sourceA, "A composition: 台")
        if supersede { XCTAssertFalse(model.lifecycle.contains(.installed(bindingB))) }
    }

    private func drainReconciliationMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
