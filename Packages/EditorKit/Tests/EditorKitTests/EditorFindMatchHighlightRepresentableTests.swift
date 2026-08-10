import AppKit
@testable import EditorKit
import STTextView
import SwiftUI
import XCTest

@MainActor
final class FindHighlightRepresentableTests: XCTestCase {
    private let documentA = EditorDocumentIdentity(rawValue: "find-highlight-doc")
    private let documentB = EditorDocumentIdentity(rawValue: "find-highlight-doc-b")

    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    // These drive `updateRepresentedTextView` — the same entry point SwiftUI uses — instead of
    // calling the helper directly. The earlier version of this file poked
    // `EditorFindMatchHighlight` and the coordinator by hand, so it stayed green while the
    // production path skipped the clear entirely.

    func testRepresentableUpdateAppliesDecoration() throws {
        let source = "alpha needle beta"
        let target = (source as NSString).range(of: "needle")
        let model = Model(text: source)
        let view = findRepresentable(
            model: model,
            identity: documentA,
            highlight: request(matches: [target])
        )
        let fixture = try makeRepresentableFixture(view, source: source)

        XCTAssertNotNil(
            try marker(in: storage(of: fixture), at: target.location),
            "removing the apply call from the representable must fail a test"
        )
    }

    func testClosingFindClearsDecorationThroughTheRepresentable() throws {
        let source = "alpha needle beta"
        let target = (source as NSString).range(of: "needle")
        let model = Model(text: source)
        let open = findRepresentable(model: model, identity: documentA, highlight: request(matches: [target]))
        let fixture = try makeRepresentableFixture(open, source: source)
        XCTAssertNotNil(try marker(in: storage(of: fixture), at: target.location))

        // Ordinary updates run first: `finishDocumentTransition` fires on every one of them, and
        // forgetting the applied request there made a nil request compare equal and skip the clear.
        open.updateRepresentedTextView(fixture.scrollView, coordinator: fixture.coordinator)
        open.updateRepresentedTextView(fixture.scrollView, coordinator: fixture.coordinator)

        let closed = findRepresentable(model: model, identity: documentA, highlight: nil)
        closed.updateRepresentedTextView(fixture.scrollView, coordinator: fixture.coordinator)

        XCTAssertNil(
            try marker(in: storage(of: fixture), at: target.location),
            "closing find must clear its highlight instead of leaving the last query lit"
        )
    }

    func testSwitchingDocumentForgetsBookkeepingSoTheSameRequestIsReapplied() throws {
        let source = "alpha needle beta"
        let target = (source as NSString).range(of: "needle")
        let model = Model(text: source)
        let shared = request(matches: [target])
        let documentAView = findRepresentable(model: model, identity: documentA, highlight: shared)
        let fixture = try makeRepresentableFixture(documentAView, source: source)
        XCTAssertNotNil(try marker(in: storage(of: fixture), at: target.location))

        // Same request value, different document: bookkeeping must not report "unchanged".
        let documentBView = findRepresentable(model: model, identity: documentB, highlight: shared)
        documentBView.updateRepresentedTextView(fixture.scrollView, coordinator: fixture.coordinator)

        XCTAssertEqual(fixture.coordinator.appliedFindMatchHighlightDocumentIdentity, documentB)
        XCTAssertNotNil(
            try marker(in: storage(of: fixture), at: target.location),
            "an identical request for a different document must be applied, not skipped"
        )
    }

    func testSwitchingDocumentWithoutARequestClearsOutgoingDecoration() throws {
        let source = "alpha needle beta"
        let target = (source as NSString).range(of: "needle")
        let model = Model(text: source)
        let documentAView = findRepresentable(
            model: model,
            identity: documentA,
            highlight: request(matches: [target])
        )
        let fixture = try makeRepresentableFixture(documentAView, source: source)
        XCTAssertNotNil(try marker(in: storage(of: fixture), at: target.location))

        // The representable and its NSTextStorage are reused across a document switch. The new
        // document can have the same bytes while its find bar is closed, so forgetting the old
        // request before clearing strands the outgoing document's presentation on the new one.
        let documentBView = findRepresentable(model: model, identity: documentB, highlight: nil)
        documentBView.updateRepresentedTextView(fixture.scrollView, coordinator: fixture.coordinator)

        XCTAssertNil(
            try marker(in: storage(of: fixture), at: target.location),
            "a document transition must clear presentation owned by the outgoing find session"
        )
        XCTAssertEqual(fixture.coordinator.appliedFindMatchHighlightDocumentIdentity, documentB)
    }

    func testLargeInsertionBeforeMatchDoesNotStrandDecorationWhenFindCloses() throws {
        let source = "alpha needle beta"
        let target = (source as NSString).range(of: "needle")
        let model = Model(text: source)
        let open = findRepresentable(
            model: model,
            identity: documentA,
            highlight: request(matches: [target])
        )
        let fixture = try makeRepresentableFixture(open, source: source)
        let textStorage = try storage(of: fixture)
        XCTAssertNotNil(marker(in: textStorage, at: target.location))

        // Move the attributed marker farther than the materialisation padding. NSTextStorage
        // shifts the attribute with the characters; F8's bounded clear bookkeeping must follow
        // that authoritative edit instead of searching the marker's stale pre-edit coordinates.
        let prefix = String(
            repeating: "x",
            count: EditorFindMatchHighlight.visibleRangePadding * 3
        )
        model.text = prefix + source
        textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: prefix)
        let shiftedTarget = NSRange(location: target.location + prefix.utf16.count, length: target.length)

        XCTAssertNotNil(marker(in: textStorage, at: shiftedTarget.location))
        XCTAssertEqual(fixture.coordinator.appliedFindMatchHighlightSpan, shiftedTarget)

        let closed = findRepresentable(model: model, identity: documentA, highlight: nil)
        let started = ContinuousClock.now
        closed.updateRepresentedTextView(fixture.scrollView, coordinator: fixture.coordinator)
        let cleanup = started.duration(to: .now)

        XCTAssertNil(
            marker(in: textStorage, at: shiftedTarget.location),
            "closing find must clear a marker that moved beyond the current viewport window"
        )
        XCTAssertNil(fixture.coordinator.appliedFindMatchHighlightSpan)
        print("F8 shifted-marker close cleanup: \(cleanup)")
    }

    final class Model {
        var text: String

        init(text: String) {
            self.text = text
        }
    }

    struct RepresentableFixture {
        let window: NSWindow
        let scrollView: NSScrollView
        let textView: MarkdownSTTextView
        let coordinator: MarkdownTextViewCoordinator
    }

    private func request(matches: [NSRange]) -> EditorFindMatchHighlightRequest {
        EditorFindMatchHighlightRequest(generation: 1, matches: matches, currentIndex: 0)
    }

    private func findRepresentable(
        model: Model,
        identity: EditorDocumentIdentity,
        highlight: EditorFindMatchHighlightRequest?
    ) -> MarkdownTextView {
        MarkdownTextView(
            text: Binding(get: { model.text }, set: { model.text = $0 }),
            styledText: nil,
            selection: .constant(nil),
            showsLineNumbers: false,
            documentIdentity: identity,
            findMatchHighlight: highlight
        )
    }

    private func makeRepresentableFixture(
        _ view: MarkdownTextView,
        source: String
    ) throws -> RepresentableFixture {
        let frame = NSRect(x: 0, y: 0, width: 560, height: 120)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.text = source
        let coordinator = view.makeCoordinator()
        textView.textDelegate = coordinator
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        EditorFindControllerTestSupport.registerWindowForTeardown(window)
        window.makeKeyAndOrderFront(nil)
        view.updateRepresentedTextView(scrollView, coordinator: coordinator)
        return RepresentableFixture(
            window: window,
            scrollView: scrollView,
            textView: textView,
            coordinator: coordinator
        )
    }

    private func storage(of fixture: RepresentableFixture) throws -> NSTextStorage {
        try XCTUnwrap(MarkdownTextView.textStorage(of: fixture.textView))
    }

    private func marker(
        in storage: NSTextStorage,
        at location: Int
    ) -> EditorFindMatchHighlightMarker? {
        guard location >= 0, location < storage.length else { return nil }
        return storage.attribute(
            EditorFindMatchHighlightMarker.attribute,
            at: location,
            effectiveRange: nil
        ) as? EditorFindMatchHighlightMarker
    }
}
