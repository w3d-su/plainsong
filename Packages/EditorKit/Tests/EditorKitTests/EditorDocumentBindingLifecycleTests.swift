import AppKit
@testable import EditorKit
import MarkdownCore
import STTextView
import SwiftUI
import XCTest

@MainActor
final class EditorDocumentBindingLifecycleTests: XCTestCase {
    func testSourceSnapshotEqualityDistinguishesCanonicalEquivalentUTF16() {
        let composed = EditorDocumentSourceSnapshot(source: "\u{00E9}", revision: 7)
        let decomposed = EditorDocumentSourceSnapshot(source: "e\u{0301}", revision: 7)

        XCTAssertEqual(composed.source, decomposed.source)
        XCTAssertNotEqual(composed, decomposed)
        XCTAssertEqual(composed, EditorDocumentSourceSnapshot(source: "\u{00E9}", revision: 7))
        XCTAssertNotEqual(composed, EditorDocumentSourceSnapshot(source: "\u{00E9}", revision: 8))
    }

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
        let lifecycleAfterFirstRevocation = model.lifecycle
        fixture.coordinator.revokeInstalledDocumentBinding()
        MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
        XCTAssertEqual(model.lifecycle, lifecycleAfterFirstRevocation)
        XCTAssertEqual(Set(model.lifecycleEvents.map(\.installationID)).count, 1)
    }

    func testExactSourceContractPublishesInstallationBaseAndPendingCompositionLifecycle() throws {
        var source = "Composition: "
        var revision = 7
        var lifecycleEvents: [EditorDocumentBindingLifecycleEvent] = []
        var writerEvents: [EditorDocumentWriterEvent] = []
        var pendingEvents: [EditorDocumentPendingSourceEvent] = []
        var publications: [EditorDocumentSourcePublication] = []
        let bindingID = EditorDocumentBindingID()
        let contract = EditorDocumentSourceContract(
            bindingID: bindingID,
            snapshot: { EditorDocumentSourceSnapshot(source: source, revision: revision) },
            lifecycle: { lifecycleEvents.append($0) },
            writer: { event in
                writerEvents.append(event)
                switch event {
                case let .activate(_, snapshot):
                    return .activated(snapshot)
                case .release:
                    return .released
                }
            },
            pendingSource: { pendingEvents.append($0) },
            publish: { publication in
                publications.append(publication)
                source = publication.source
                revision += 1
                return .accepted(
                    EditorDocumentSourceSnapshot(source: source, revision: revision),
                    sourceWasReconciled: false
                )
            }
        )
        let view = MarkdownTextView(
            text: Binding(get: { source }, set: { source = $0 }),
            styledText: nil,
            selection: .constant(nil),
            showsLineNumbers: false,
            documentIdentity: EditorDocumentIdentity(rawValue: "document"),
            documentBindingID: bindingID,
            onDocumentBindingLifecycle: { lifecycleEvents.append($0) },
            documentSourceContract: contract
        )
        let fixture = try makeFixture(representable: view, source: source)
        defer {
            fixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
        }
        let installation = try XCTUnwrap(lifecycleEvents.first?.installation)

        fixture.textView.textSelection = NSRange(location: (source as NSString).length, length: 0)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        XCTAssertEqual(source, "Composition: ")
        XCTAssertEqual(pendingEvents, [.began(installation)])

        fixture.textView.insertText("臺e\u{0301}🧪", replacementRange: .notFound)
        let publication = try XCTUnwrap(publications.first)
        XCTAssertEqual(publication.installation, installation)
        XCTAssertEqual(publication.base, EditorDocumentSourceSnapshot(source: "Composition: ", revision: 7))
        XCTAssertEqual(Array(publication.source.utf16), Array("Composition: 臺e\u{0301}🧪".utf16))
        XCTAssertEqual(Array(source.utf16), Array(publication.source.utf16))
        XCTAssertEqual(revision, 8)
        XCTAssertEqual(pendingEvents, [.began(installation), .synchronized(installation)])
        XCTAssertTrue(writerEvents.contains(.activate(
            installation,
            from: EditorDocumentSourceSnapshot(source: "Composition: ", revision: 7)
        )), "writer events: \(writerEvents)")

        MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
        XCTAssertEqual(lifecycleEvents.last, .revoked(installation))
        XCTAssertEqual(writerEvents.last, .release(installation))
    }

    func testRevisionOnlyDriftSynchronizesAndReacquiresWriterBeforeNativeMutation() throws {
        var source = "Saved copy"
        var revision = 4
        var lifecycleEvents: [EditorDocumentBindingLifecycleEvent] = []
        var writerEvents: [EditorDocumentWriterEvent] = []
        var publications: [EditorDocumentSourcePublication] = []
        let bindingID = EditorDocumentBindingID()
        let contract = EditorDocumentSourceContract(
            bindingID: bindingID,
            snapshot: { EditorDocumentSourceSnapshot(source: source, revision: revision) },
            lifecycle: { lifecycleEvents.append($0) },
            writer: { event in
                writerEvents.append(event)
                switch event {
                case let .activate(_, base):
                    let current = EditorDocumentSourceSnapshot(
                        source: source,
                        revision: revision
                    )
                    return base == current ? .activated(current) : .synchronize(current)
                case .release:
                    return .released
                }
            },
            pendingSource: { _ in },
            publish: { publication in
                publications.append(publication)
                source = publication.source
                revision += 1
                return .accepted(
                    EditorDocumentSourceSnapshot(
                        source: source,
                        revision: revision
                    ),
                    sourceWasReconciled: false
                )
            }
        )
        let view = MarkdownTextView(
            text: Binding(get: { source }, set: { source = $0 }),
            styledText: nil,
            selection: .constant(nil),
            showsLineNumbers: false,
            documentIdentity: EditorDocumentIdentity(rawValue: "document"),
            documentBindingID: bindingID,
            onDocumentBindingLifecycle: { lifecycleEvents.append($0) },
            documentSourceContract: contract
        )
        let fixture = try makeFixture(representable: view, source: source)
        defer {
            fixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
        }
        let installation = try XCTUnwrap(lifecycleEvents.first?.installation)
        fixture.textView.textSelection = NSRange(location: (source as NSString).length, length: 0)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))

        // Save Copy changes the installed session identity and therefore its
        // revision, while the exact source and native selection stay unchanged.
        revision += 1
        fixture.textView.insertText(" edit", replacementRange: .notFound)

        XCTAssertEqual(source, "Saved copy edit")
        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(publications.first?.base, EditorDocumentSourceSnapshot(
            source: "Saved copy",
            revision: 5
        ))
        let activations = writerEvents.compactMap { event -> EditorDocumentSourceSnapshot? in
            guard case let .activate(eventInstallation, snapshot) = event,
                  eventInstallation == installation
            else {
                return nil
            }
            return snapshot
        }
        XCTAssertEqual(activations, [
            EditorDocumentSourceSnapshot(source: "Saved copy", revision: 4),
            EditorDocumentSourceSnapshot(source: "Saved copy", revision: 5),
        ])
    }

    func testSameRevisionRepresentableUpdateUsesProofWhileStaleUpdateRecordsNativeComparison() throws {
        var source = "current source"
        var revision = 0
        var comparisons: [EditorDocumentSourceFullComparisonKind] = []
        let bindingID = EditorDocumentBindingID()
        let contract = EditorDocumentSourceContract(
            bindingID: bindingID,
            snapshot: { EditorDocumentSourceSnapshot(source: source, revision: revision) },
            lifecycle: { _ in },
            writer: { event in
                switch event {
                case let .activate(_, snapshot): .activated(snapshot)
                case .release: .released
                }
            },
            pendingSource: { _ in },
            publish: { publication in
                source = publication.source
                revision += 1
                return .accepted(
                    EditorDocumentSourceSnapshot(source: source, revision: revision),
                    sourceWasReconciled: false
                )
            },
            recordFullSourceComparison: { comparisons.append($0) }
        )
        let view = MarkdownTextView(
            text: Binding(get: { source }, set: { source = $0 }),
            styledText: nil,
            selection: .constant(nil),
            showsLineNumbers: false,
            documentIdentity: EditorDocumentIdentity(rawValue: "document"),
            documentBindingID: bindingID,
            onDocumentBindingLifecycle: { _ in },
            documentSourceContract: contract
        )
        let fixture = try makeFixture(representable: view, source: source)
        defer {
            fixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
        }
        comparisons.removeAll()

        view.updateRepresentedTextView(fixture.scrollView, coordinator: fixture.coordinator)
        XCTAssertTrue(comparisons.isEmpty)

        source = "external source"
        revision += 1
        view.updateRepresentedTextView(fixture.scrollView, coordinator: fixture.coordinator)

        XCTAssertEqual(Self.text(in: fixture.textView), source)
        XCTAssertEqual(comparisons, [.nativeView])
    }

    func testClosingDelimiterSkipAdvancesSelectionWithoutSourcePublication() throws {
        var source = "()"
        var revision = 0
        var writerEvents: [EditorDocumentWriterEvent] = []
        var publications: [EditorDocumentSourcePublication] = []
        let bindingID = EditorDocumentBindingID()
        let contract = EditorDocumentSourceContract(
            bindingID: bindingID,
            snapshot: { EditorDocumentSourceSnapshot(source: source, revision: revision) },
            lifecycle: { _ in },
            writer: { event in
                writerEvents.append(event)
                switch event {
                case let .activate(_, snapshot): return .activated(snapshot)
                case .release: return .released
                }
            },
            pendingSource: { _ in },
            publish: { publication in
                publications.append(publication)
                source = publication.source
                revision += 1
                return .accepted(
                    EditorDocumentSourceSnapshot(source: source, revision: revision),
                    sourceWasReconciled: false
                )
            }
        )
        let view = MarkdownTextView(
            text: Binding(get: { source }, set: { source = $0 }),
            styledText: nil,
            selection: .constant(nil),
            showsLineNumbers: false,
            documentIdentity: EditorDocumentIdentity(rawValue: "document"),
            documentBindingID: bindingID,
            onDocumentBindingLifecycle: { _ in },
            documentSourceContract: contract
        )
        let fixture = try makeFixture(representable: view, source: source)
        defer {
            fixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
        }
        fixture.textView.textSelection = NSRange(location: 1, length: 0)
        writerEvents.removeAll()

        fixture.textView.insertText(")", replacementRange: .notFound)

        XCTAssertEqual(Self.text(in: fixture.textView), "()")
        XCTAssertEqual(fixture.textView.selectedRange(), NSRange(location: 2, length: 0))
        XCTAssertEqual(source, "()")
        XCTAssertEqual(revision, 0)
        XCTAssertTrue(writerEvents.isEmpty)
        XCTAssertTrue(publications.isEmpty)
    }

    func testStaleIMEInsertionAtReplacementLowerBoundaryReconcilesExactUTF16() throws {
        try assertStaleIMEBoundaryReconciliation(
            caretLocation: 1,
            expected: "A\u{81FA}e\u{0301}\u{1F9EA}B"
        )
    }

    func testStaleIMEInsertionAtReplacementUpperBoundaryReconcilesExactUTF16() throws {
        try assertStaleIMEBoundaryReconciliation(
            caretLocation: 4,
            expected: "A\u{1F9EA}\u{81FA}e\u{0301}B"
        )
    }
}

@MainActor
private extension EditorDocumentBindingLifecycleTests {
    final class Model {
        var sourceA = "A composition: "
        var sourceB = "B destination"
        var lifecycleEvents: [EditorDocumentBindingLifecycleEvent] = []

        var lifecycle: [RecordedLifecycle] {
            lifecycleEvents.map { event in
                switch event {
                case let .installed(installation):
                    .installed(installation.bindingID)
                case let .revoked(installation):
                    .revoked(installation.bindingID)
                }
            }
        }
    }

    enum RecordedLifecycle: Equatable {
        case installed(EditorDocumentBindingID)
        case revoked(EditorDocumentBindingID)
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
            onDocumentBindingLifecycle: { model.lifecycleEvents.append($0) }
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

    static func text(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }

    func assertStaleIMEBoundaryReconciliation(
        caretLocation: Int,
        expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let base = "AoldB"
        var source = base
        var revision = 0
        var publications: [EditorDocumentSourcePublication] = []
        let bindingID = EditorDocumentBindingID()
        let contract = EditorDocumentSourceContract(
            bindingID: bindingID,
            snapshot: { EditorDocumentSourceSnapshot(source: source, revision: revision) },
            lifecycle: { _ in },
            writer: { event in
                switch event {
                case let .activate(_, snapshot): .activated(snapshot)
                case .release: .released
                }
            },
            pendingSource: { _ in },
            publish: { publication in
                publications.append(publication)
                guard let reconciled = ExactSourceText.reconciling(
                    base: publication.base.source,
                    current: source,
                    proposed: publication.source
                ) else {
                    return .rejected(EditorDocumentSourceSnapshot(
                        source: source,
                        revision: revision
                    ))
                }
                source = reconciled
                revision += 1
                return .accepted(
                    EditorDocumentSourceSnapshot(source: source, revision: revision),
                    sourceWasReconciled: true
                )
            }
        )
        let view = MarkdownTextView(
            text: Binding(get: { source }, set: { source = $0 }),
            styledText: nil,
            selection: .constant(nil),
            showsLineNumbers: false,
            documentIdentity: EditorDocumentIdentity(rawValue: "document"),
            documentBindingID: bindingID,
            onDocumentBindingLifecycle: { _ in },
            documentSourceContract: contract
        )
        let fixture = try makeFixture(representable: view, source: source)
        defer {
            fixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
        }
        fixture.textView.textSelection = NSRange(location: caretLocation, length: 0)
        fixture.textView.setMarkedText(
            "\u{310A}",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        XCTAssertTrue(fixture.textView.hasMarkedText(), file: file, line: line)

        source = "A\u{1F9EA}B"
        revision += 1
        fixture.textView.insertText("\u{81FA}e\u{0301}", replacementRange: .notFound)

        XCTAssertEqual(publications.count, 1, file: file, line: line)
        XCTAssertEqual(Array(source.utf16), Array(expected.utf16), file: file, line: line)
        XCTAssertEqual(
            Array(Self.text(in: fixture.textView).utf16),
            Array(expected.utf16),
            file: file,
            line: line
        )
    }
}

private extension EditorDocumentBindingLifecycleEvent {
    var installation: EditorDocumentBindingInstallation {
        switch self {
        case let .installed(installation), let .revoked(installation):
            installation
        }
    }

    var installationID: EditorDocumentBindingInstallationID {
        installation.installationID
    }
}
