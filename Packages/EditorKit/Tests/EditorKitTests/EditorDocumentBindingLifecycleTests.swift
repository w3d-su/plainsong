import AppKit
@testable import EditorKit
import SwiftUI
import XCTest

@MainActor
final class EditorDocumentBindingLifecycleTests: XCTestCase {
    func testLeaseTransfersOnlyAfterCandidateInstallationAndRevokesOnTeardown() throws {
        let model = Model()
        let bindingA = EditorDocumentBindingID()
        let bindingB = EditorDocumentBindingID()
        let documentA = EditorDocumentIdentity(rawValue: "document-a")
        let documentB = EditorDocumentIdentity(rawValue: "document-b")
        let documentAView = representable(
            text: Binding(get: { model.sourceA }, set: { model.sourceA = $0 }),
            identity: documentA,
            bindingID: bindingA,
            model: model
        )
        let documentBView = representable(
            text: Binding(get: { model.sourceB }, set: { model.sourceB = $0 }),
            identity: documentB,
            bindingID: bindingB,
            model: model
        )
        let fixture = try makeFixture(representable: documentAView, source: model.sourceA)
        XCTAssertEqual(model.lifecycle, [.installed(bindingA)])

        fixture.textView.textSelection = NSRange(location: (model.sourceA as NSString).length, length: 0)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        documentBView.updateRepresentedTextView(fixture.scrollView, coordinator: fixture.coordinator)
        XCTAssertEqual(model.lifecycle, [.installed(bindingA)])
        XCTAssertEqual(fixture.coordinator.currentDocumentIdentity, documentA)

        fixture.textView.insertText("台", replacementRange: .notFound)
        documentBView.updateRepresentedTextView(fixture.scrollView, coordinator: fixture.coordinator)
        XCTAssertEqual(model.lifecycle, [
            .installed(bindingA),
            .installed(bindingB),
            .revoked(bindingA),
        ])
        XCTAssertEqual(fixture.coordinator.currentDocumentIdentity, documentB)
        XCTAssertEqual(model.sourceA, "A composition: 台")
        XCTAssertEqual(model.sourceB, "B destination")

        MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
        XCTAssertEqual(model.lifecycle.last, .revoked(bindingB))
    }
}

@MainActor
private extension EditorDocumentBindingLifecycleTests {
    final class Model {
        var sourceA = "A composition: "
        var sourceB = "B destination"
        var lifecycle: [EditorDocumentBindingLifecycleEvent] = []
    }

    struct Fixture {
        let window: NSWindow
        let scrollView: NSScrollView
        let textView: MarkdownSTTextView
        let coordinator: MarkdownTextViewCoordinator
    }

    func representable(
        text: Binding<String>,
        identity: EditorDocumentIdentity,
        bindingID: EditorDocumentBindingID,
        model: Model
    ) -> MarkdownTextView {
        MarkdownTextView(
            text: text,
            styledText: nil,
            selection: .constant(nil),
            showsLineNumbers: false,
            documentIdentity: identity,
            documentBindingID: bindingID,
            onDocumentBindingLifecycle: { model.lifecycle.append($0) }
        )
    }

    func makeFixture(representable: MarkdownTextView, source: String) throws -> Fixture {
        let frame = NSRect(x: 0, y: 0, width: 560, height: 100)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.text = source
        let coordinator = representable.makeCoordinator()
        textView.textDelegate = coordinator
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        representable.updateRepresentedTextView(scrollView, coordinator: coordinator)
        return Fixture(window: window, scrollView: scrollView, textView: textView, coordinator: coordinator)
    }
}
