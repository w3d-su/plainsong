import AppKit
@testable import EditorKit
import STTextView
import SwiftUI
import XCTest

@MainActor
final class EditorInstalledDocumentTransitionTests: XCTestCase {
    private let documentA = EditorDocumentIdentity(rawValue: "document-a")
    private let documentB = EditorDocumentIdentity(rawValue: "document-b")

    func testCrossDocumentIMECommitAutomaticallyInstallsTheSinglePreparedDestinationUpdate() async throws {
        let scenario = try makeTransitionScenario()
        assertInitialDocumentA(in: scenario)
        beginMarkedTextComposition(in: scenario)

        scenario.documentBView.updateRepresentedTextView(
            scenario.fixture.scrollView,
            coordinator: scenario.fixture.coordinator
        )
        assertDocumentBRemainsPending(in: scenario)

        let originalOrigin = scenario.fixture.scrollView.contentView.bounds.origin
        scenario.fixture.textView.insertText("台", replacementRange: .notFound)
        assertDocumentACommitIsIsolated(in: scenario)

        await yieldForAutomaticTransition()
        assertDocumentBIsInstalledAndNavigated(in: scenario, originalOrigin: originalOrigin)

        let destinationSource = String(decoding: scenario.sourceBUTF16, as: UTF16.self)
        scenario.fixture.textView.textSelection = NSRange(
            location: scenario.sourceBUTF16.count,
            length: 0
        )
        scenario.fixture.textView.insertText("!", replacementRange: .notFound)
        XCTAssertEqual(scenario.model.sourceB, destinationSource + "!")
        XCTAssertEqual(scenario.model.sourceA, scenario.sourceA + "台")
    }

    func testNilDocumentIdentitiesKeepBindingsPinnedUntilAutomaticExactCandidateInstallation() async throws {
        let sourceA = "Nil identity A composition: "
        let sourceB = "Nil identity B a\u{301}\u{327} 中文 🧪 destination"
        let sourceBBytes = Data(sourceB.utf8)
        let sourceBUTF16 = Array(sourceB.utf16)
        let model = TransitionModel(sourceA: sourceA, sourceB: sourceB)
        let documentAView = makeNilIdentityRepresentable(model: model, document: .documentA)
        let documentBView = makeNilIdentityRepresentable(model: model, document: .documentB)
        let fixture = try makeWindowedFixture(representable: documentAView, source: sourceA)

        fixture.textView.textSelection = NSRange(location: (sourceA as NSString).length, length: 0)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        XCTAssertTrue(fixture.textView.hasMarkedText())

        documentBView.updateRepresentedTextView(fixture.scrollView, coordinator: fixture.coordinator)

        XCTAssertTrue(fixture.textView.hasMarkedText())
        XCTAssertEqual(Data(model.sourceB.utf8), sourceBBytes)
        XCTAssertEqual(Array(model.sourceB.utf16), sourceBUTF16)
        XCTAssertTrue(model.documentBTextWrites.isEmpty)
        XCTAssertTrue(model.documentBSelectionWrites.isEmpty)
        XCTAssertNotEqual(Array(Self.text(in: fixture.textView).utf16), sourceBUTF16)

        fixture.textView.insertText("台", replacementRange: .notFound)

        let committedSourceA = sourceA + "台"
        XCTAssertFalse(fixture.textView.hasMarkedText())
        XCTAssertEqual(Data(model.sourceA.utf8), Data(committedSourceA.utf8))
        XCTAssertEqual(Array(model.sourceA.utf16), Array(committedSourceA.utf16))
        XCTAssertEqual(model.documentATextWrites, [Data(committedSourceA.utf8)])
        XCTAssertEqual(Data(model.sourceB.utf8), sourceBBytes)
        XCTAssertEqual(Array(model.sourceB.utf16), sourceBUTF16)
        XCTAssertTrue(model.documentBTextWrites.isEmpty)
        XCTAssertTrue(model.documentBSelectionWrites.isEmpty)

        await yieldForAutomaticTransition()

        XCTAssertEqual(Data(Self.text(in: fixture.textView).utf8), sourceBBytes)
        XCTAssertEqual(Array(Self.text(in: fixture.textView).utf16), sourceBUTF16)
        XCTAssertTrue(fixture.coordinator.isPreparedDocumentInstalled)
        XCTAssertTrue(model.documentBTextWrites.isEmpty)
        XCTAssertTrue(model.documentBSelectionWrites.isEmpty)

        fixture.textView.textSelection = NSRange(location: sourceBUTF16.count, length: 0)
        fixture.textView.insertText("!", replacementRange: .notFound)

        let editedSourceB = sourceB + "!"
        XCTAssertEqual(Data(model.sourceA.utf8), Data(committedSourceA.utf8))
        XCTAssertEqual(Data(model.sourceB.utf8), Data(editedSourceB.utf8))
        XCTAssertEqual(Array(model.sourceB.utf16), Array(editedSourceB.utf16))
        XCTAssertEqual(model.documentBTextWrites, [Data(editedSourceB.utf8)])
    }

    func testNewestDeferredCandidateSupersedesOlderCandidateAndInstallsOnce() async throws {
        var sourceA = "A composition: "
        var sourceB = "B obsolete"
        var sourceC = "C newest"
        var selectionA: NSRange? = NSRange(location: (sourceA as NSString).length, length: 0)
        var selectionB: NSRange? = NSRange(location: 0, length: 0)
        var selectionC: NSRange? = NSRange(location: 2, length: 0)
        var lifecycleB: [EditorDocumentBindingLifecycleEvent] = []
        var lifecycleC: [EditorDocumentBindingLifecycleEvent] = []
        let bindingA = EditorDocumentBindingID()
        let bindingB = EditorDocumentBindingID()
        let bindingC = EditorDocumentBindingID()
        let viewA = MarkdownTextView(
            text: Binding(get: { sourceA }, set: { sourceA = $0 }),
            styledText: nil,
            selection: Binding(get: { selectionA }, set: { selectionA = $0 }),
            showsLineNumbers: false,
            documentIdentity: documentA,
            documentBindingID: bindingA,
            onDocumentBindingLifecycle: { _ in }
        )
        let fixture = try makeWindowedFixture(representable: viewA, source: sourceA)
        defer {
            fixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
        }
        fixture.textView.textSelection = selectionA ?? .notFound
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )

        let viewB = MarkdownTextView(
            text: Binding(get: { sourceB }, set: { sourceB = $0 }),
            styledText: nil,
            selection: Binding(get: { selectionB }, set: { selectionB = $0 }),
            showsLineNumbers: false,
            documentIdentity: documentB,
            documentBindingID: bindingB,
            onDocumentBindingLifecycle: { lifecycleB.append($0) }
        )
        viewB.updateRepresentedTextView(fixture.scrollView, coordinator: fixture.coordinator)

        let documentC = EditorDocumentIdentity(rawValue: "document-c")
        let viewC = MarkdownTextView(
            text: Binding(get: { sourceC }, set: { sourceC = $0 }),
            styledText: nil,
            selection: Binding(get: { selectionC }, set: { selectionC = $0 }),
            showsLineNumbers: false,
            documentIdentity: documentC,
            documentBindingID: bindingC,
            onDocumentBindingLifecycle: { lifecycleC.append($0) }
        )
        viewC.updateRepresentedTextView(fixture.scrollView, coordinator: fixture.coordinator)
        fixture.textView.insertText("臺", replacementRange: .notFound)

        await yieldForAutomaticTransition()

        XCTAssertEqual(sourceA, "A composition: 臺")
        XCTAssertEqual(sourceB, "B obsolete")
        XCTAssertEqual(sourceC, "C newest")
        XCTAssertEqual(Self.text(in: fixture.textView), sourceC)
        XCTAssertEqual(fixture.coordinator.currentDocumentIdentity, documentC)
        XCTAssertTrue(lifecycleB.isEmpty)
        XCTAssertEqual(lifecycleC.count, 1)
        guard case let .installed(installation) = lifecycleC[0] else {
            return XCTFail("Newest candidate must install exactly once")
        }
        XCTAssertEqual(installation.bindingID, bindingC)
    }

    func testDismantleBeforeDeferredRetryDiscardsDestinationCandidate() async throws {
        var sourceA = "A composition: "
        var sourceB = "B must not install"
        var lifecycleB: [EditorDocumentBindingLifecycleEvent] = []
        let viewA = MarkdownTextView(
            text: Binding(get: { sourceA }, set: { sourceA = $0 }),
            styledText: nil,
            selection: .constant(nil),
            showsLineNumbers: false,
            documentIdentity: documentA
        )
        let fixture = try makeWindowedFixture(representable: viewA, source: sourceA)
        fixture.textView.textSelection = NSRange(location: (sourceA as NSString).length, length: 0)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        let viewB = MarkdownTextView(
            text: Binding(get: { sourceB }, set: { sourceB = $0 }),
            styledText: nil,
            selection: .constant(nil),
            showsLineNumbers: false,
            documentIdentity: documentB,
            documentBindingID: EditorDocumentBindingID(),
            onDocumentBindingLifecycle: { lifecycleB.append($0) }
        )
        viewB.updateRepresentedTextView(fixture.scrollView, coordinator: fixture.coordinator)
        fixture.textView.insertText("臺", replacementRange: .notFound)
        MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)

        await yieldForAutomaticTransition()

        XCTAssertEqual(sourceA, "A composition: 臺")
        XCTAssertEqual(sourceB, "B must not install")
        XCTAssertEqual(Self.text(in: fixture.textView), sourceA)
        XCTAssertTrue(lifecycleB.isEmpty)
        fixture.window.orderOut(nil)
    }

    func testNavigationCancellationClearsSelectionWorkButStillInstallsDeferredDestination() async throws {
        var sourceA = "A composition: "
        var sourceB = "B destination"
        var selectionB: NSRange? = NSRange(location: 2, length: 0)
        let viewA = MarkdownTextView(
            text: Binding(get: { sourceA }, set: { sourceA = $0 }),
            styledText: nil,
            selection: .constant(nil),
            showsLineNumbers: false,
            documentIdentity: documentA
        )
        let fixture = try makeWindowedFixture(representable: viewA, source: sourceA)
        defer {
            fixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
        }
        fixture.textView.textSelection = NSRange(location: (sourceA as NSString).length, length: 0)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        let cancelledView = MarkdownTextView(
            text: Binding(get: { sourceB }, set: { sourceB = $0 }),
            styledText: nil,
            selection: Binding(get: { selectionB }, set: { selectionB = $0 }),
            showsLineNumbers: false,
            documentIdentity: documentB,
            navigationCommand: .cancel(id: 1)
        )
        cancelledView.updateRepresentedTextView(
            fixture.scrollView,
            coordinator: fixture.coordinator
        )
        fixture.textView.insertText("臺", replacementRange: .notFound)

        await yieldForAutomaticTransition()

        XCTAssertEqual(sourceA, "A composition: 臺")
        XCTAssertEqual(sourceB, "B destination")
        XCTAssertEqual(Self.text(in: fixture.textView), sourceB)
        XCTAssertEqual(fixture.coordinator.currentDocumentIdentity, documentB)
        XCTAssertEqual(fixture.textView.selectedRange(), selectionB)
    }

    func testBindingOnlySameDocumentRetryRefreshesCommittedIMETextBeforeNextEdit() async throws {
        var source = "A"
        var selection: NSRange? = NSRange(location: 1, length: 0)
        let view = MarkdownTextView(
            text: Binding(get: { source }, set: { source = $0 }),
            styledText: nil,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            showsLineNumbers: false,
            documentIdentity: documentA
        )
        let fixture = try makeWindowedFixture(representable: view, source: source)
        defer {
            fixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
        }
        fixture.textView.textSelection = NSRange(location: 1, length: 0)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )

        view.updateRepresentedTextView(fixture.scrollView, coordinator: fixture.coordinator)
        fixture.textView.insertText("台", replacementRange: .notFound)
        XCTAssertEqual(source, "A台")

        await yieldForAutomaticTransition()
        XCTAssertEqual(Self.text(in: fixture.textView), "A台")
        XCTAssertEqual(source, "A台")

        fixture.textView.insertText("!", replacementRange: .notFound)
        XCTAssertEqual(source, "A台!")
        XCTAssertEqual(Self.text(in: fixture.textView), "A台!")
    }

    func testBindingOnlyCrossDocumentRetryRefreshesDestinationTextAndSelection() async throws {
        var sourceA = "A"
        var sourceB = "B"
        var selectionA: NSRange? = NSRange(location: 1, length: 0)
        var selectionB: NSRange? = NSRange(location: 0, length: 0)
        let viewA = MarkdownTextView(
            text: Binding(get: { sourceA }, set: { sourceA = $0 }),
            styledText: nil,
            selection: Binding(get: { selectionA }, set: { selectionA = $0 }),
            showsLineNumbers: false,
            documentIdentity: documentA
        )
        let fixture = try makeWindowedFixture(representable: viewA, source: sourceA)
        defer {
            fixture.window.orderOut(nil)
            MarkdownTextView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)
        }
        fixture.textView.textSelection = NSRange(location: 1, length: 0)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        let viewB = MarkdownTextView(
            text: Binding(get: { sourceB }, set: { sourceB = $0 }),
            styledText: nil,
            selection: Binding(get: { selectionB }, set: { selectionB = $0 }),
            showsLineNumbers: false,
            documentIdentity: documentB
        )
        viewB.updateRepresentedTextView(fixture.scrollView, coordinator: fixture.coordinator)

        sourceB = "B changed while deferred"
        selectionB = NSRange(location: 9, length: 0)
        fixture.textView.insertText("台", replacementRange: .notFound)
        await yieldForAutomaticTransition()

        XCTAssertEqual(sourceA, "A台")
        XCTAssertEqual(Self.text(in: fixture.textView), sourceB)
        XCTAssertEqual(fixture.textView.selectedRange(), selectionB)
        XCTAssertEqual(fixture.coordinator.currentDocumentIdentity, documentB)
    }

    func testDismantleCancelsNavigationTasksAndDetachesTheInstalledBinding() throws {
        var modelText = "installed"
        var writes: [Data] = []
        let textBinding = Binding(
            get: { modelText },
            set: {
                modelText = $0
                writes.append(Data($0.utf8))
            }
        )
        let scrollView = MarkdownSTTextView.scrollableTextView()
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.text = modelText
        let coordinator = MarkdownTextViewCoordinator(text: textBinding, selection: .constant(nil))
        textView.textDelegate = coordinator
        let retryTask = sleepingTask()
        let deferralTask = sleepingTask()
        coordinator.navigationRetryTask = retryTask
        coordinator.navigationInputDeferralTask = deferralTask

        MarkdownTextView.dismantleNSView(scrollView, coordinator: coordinator)

        XCTAssertTrue(retryTask.isCancelled)
        XCTAssertTrue(deferralTask.isCancelled)
        XCTAssertNil(coordinator.navigationRetryTask)
        XCTAssertNil(coordinator.navigationInputDeferralTask)
        XCTAssertNil(textView.textDelegate)
        textView.textSelection = NSRange(location: (modelText as NSString).length, length: 0)
        textView.insertText(" stale", replacementRange: .notFound)
        XCTAssertEqual(Data(modelText.utf8), Data("installed".utf8))
        XCTAssertTrue(writes.isEmpty)
    }
}

@MainActor
private final class TransitionModel {
    enum Document {
        case documentA
        case documentB
    }

    var sourceA: String
    var sourceB: String
    var selectionA: NSRange? = NSRange(location: 0, length: 0)
    var selectionB: NSRange?
    private(set) var documentATextWrites: [Data] = []
    private(set) var documentBTextWrites: [Data] = []
    private(set) var documentASelectionWrites: [NSRange?] = []
    private(set) var documentBSelectionWrites: [NSRange?] = []

    init(sourceA: String, sourceB: String) {
        self.sourceA = sourceA
        self.sourceB = sourceB
    }

    func textBinding(for document: Document) -> Binding<String> {
        Binding(
            get: { [self] in
                switch document {
                case .documentA: sourceA
                case .documentB: sourceB
                }
            },
            set: { [self] newValue in
                switch document {
                case .documentA:
                    sourceA = newValue
                    documentATextWrites.append(Data(newValue.utf8))
                case .documentB:
                    sourceB = newValue
                    documentBTextWrites.append(Data(newValue.utf8))
                }
            }
        )
    }

    func selectionBinding(for document: Document) -> Binding<NSRange?> {
        Binding(
            get: { [self] in
                switch document {
                case .documentA: selectionA
                case .documentB: selectionB
                }
            },
            set: { [self] newValue in
                switch document {
                case .documentA:
                    selectionA = newValue
                    documentASelectionWrites.append(newValue)
                case .documentB:
                    selectionB = newValue
                    documentBSelectionWrites.append(newValue)
                }
            }
        )
    }
}

@MainActor
private extension EditorInstalledDocumentTransitionTests {
    struct TransitionScenario {
        let sourceA: String
        let sourceBBytes: Data
        let sourceBUTF16: [UInt16]
        let target: NSRange
        let request: EditorNavigationRequest
        let model: TransitionModel
        let documentBView: MarkdownTextView
        let fixture: WindowedFixture
    }

    struct WindowedFixture {
        let window: NSWindow
        let scrollView: NSScrollView
        let textView: MarkdownSTTextView
        let coordinator: MarkdownTextViewCoordinator
    }

    func makeTransitionScenario() throws -> TransitionScenario {
        let sourceA = "Document A composition: "
        let sourceB = (0 ... 220)
            .map { $0 == 200 ? "line \($0) exact destination" : "line \($0) filler" }
            .joined(separator: "\n")
        let target = (sourceB as NSString).range(of: "exact destination")
        let request = EditorNavigationRequest(
            id: 1,
            documentIdentity: documentB,
            selection: target
        )
        let model = TransitionModel(sourceA: sourceA, sourceB: sourceB)
        let documentAView = makeRepresentable(
            model: model,
            document: .documentA,
            identity: documentA,
            request: nil
        )
        let documentBView = makeRepresentable(
            model: model,
            document: .documentB,
            identity: documentB,
            request: request
        )
        return try TransitionScenario(
            sourceA: sourceA,
            sourceBBytes: Data(sourceB.utf8),
            sourceBUTF16: Array(sourceB.utf16),
            target: target,
            request: request,
            model: model,
            documentBView: documentBView,
            fixture: makeWindowedFixture(representable: documentAView, source: sourceA)
        )
    }

    func assertInitialDocumentA(in scenario: TransitionScenario) {
        XCTAssertEqual(scenario.fixture.coordinator.currentDocumentIdentity, documentA)
        XCTAssertEqual(
            Array(Self.text(in: scenario.fixture.textView).utf16),
            Array(scenario.sourceA.utf16)
        )
    }

    func beginMarkedTextComposition(in scenario: TransitionScenario) {
        let textView = scenario.fixture.textView
        textView.textSelection = NSRange(location: (scenario.sourceA as NSString).length, length: 0)
        XCTAssertTrue(scenario.fixture.window.makeFirstResponder(textView))
        textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )
        XCTAssertTrue(textView.hasMarkedText())
    }

    func assertDocumentBRemainsPending(in scenario: TransitionScenario) {
        let coordinator = scenario.fixture.coordinator
        XCTAssertTrue(scenario.fixture.textView.hasMarkedText())
        XCTAssertEqual(coordinator.currentDocumentIdentity, documentA)
        XCTAssertEqual(coordinator.navigationState.pendingRequest, scenario.request)
        XCTAssertNil(coordinator.navigationState.lastHandledRequestID)
        XCTAssertEqual(Data(scenario.model.sourceB.utf8), scenario.sourceBBytes)
        XCTAssertEqual(Array(scenario.model.sourceB.utf16), scenario.sourceBUTF16)
        XCTAssertTrue(scenario.model.documentBTextWrites.isEmpty)
        XCTAssertNotEqual(
            Array(Self.text(in: scenario.fixture.textView).utf16),
            scenario.sourceBUTF16
        )
    }

    func assertDocumentACommitIsIsolated(in scenario: TransitionScenario) {
        let coordinator = scenario.fixture.coordinator
        XCTAssertFalse(scenario.fixture.textView.hasMarkedText())
        XCTAssertEqual(Data(scenario.model.sourceA.utf8), Data((scenario.sourceA + "台").utf8))
        XCTAssertEqual(Data(scenario.model.sourceB.utf8), scenario.sourceBBytes)
        XCTAssertEqual(Array(scenario.model.sourceB.utf16), scenario.sourceBUTF16)
        XCTAssertTrue(scenario.model.documentBTextWrites.isEmpty)
        XCTAssertEqual(coordinator.currentDocumentIdentity, documentA)
        XCTAssertEqual(coordinator.navigationState.pendingRequest, scenario.request)
        XCTAssertNil(coordinator.navigationState.lastHandledRequestID)
    }

    func assertDocumentBIsInstalledAndNavigated(
        in scenario: TransitionScenario,
        originalOrigin: NSPoint
    ) {
        let coordinator = scenario.fixture.coordinator
        let textView = scenario.fixture.textView
        XCTAssertTrue(textView.textDelegate as? MarkdownTextViewCoordinator === coordinator)
        XCTAssertEqual(Array(Self.text(in: textView).utf16), scenario.sourceBUTF16)
        XCTAssertEqual(Data(Self.text(in: textView).utf8), scenario.sourceBBytes)
        XCTAssertEqual(Data(scenario.model.sourceB.utf8), scenario.sourceBBytes)
        XCTAssertTrue(scenario.model.documentBTextWrites.isEmpty)
        XCTAssertEqual(coordinator.currentDocumentIdentity, documentB)
        XCTAssertNil(coordinator.navigationState.pendingRequest)
        XCTAssertEqual(coordinator.navigationState.lastHandledRequestID, scenario.request.id)
        XCTAssertEqual(textView.selectedRange(), scenario.target)
        XCTAssertEqual(scenario.model.selectionB, scenario.target)
        XCTAssertGreaterThan(scenario.fixture.scrollView.contentView.bounds.origin.y, originalOrigin.y)
        XCTAssertTrue(scenario.fixture.window.firstResponder === textView)
    }

    func makeRepresentable(
        model: TransitionModel,
        document: TransitionModel.Document,
        identity: EditorDocumentIdentity,
        request: EditorNavigationRequest?
    ) -> MarkdownTextView {
        MarkdownTextView(
            text: model.textBinding(for: document),
            styledText: nil,
            selection: model.selectionBinding(for: document),
            showsLineNumbers: false,
            documentIdentity: identity,
            navigationCommand: request.map(EditorNavigationCommand.navigate)
        )
    }

    func makeNilIdentityRepresentable(
        model: TransitionModel,
        document: TransitionModel.Document
    ) -> MarkdownTextView {
        MarkdownTextView(
            text: model.textBinding(for: document),
            styledText: nil,
            selection: model.selectionBinding(for: document),
            showsLineNumbers: false
        )
    }

    func makeWindowedFixture(
        representable: MarkdownTextView,
        source: String
    ) throws -> WindowedFixture {
        let frame = NSRect(x: 0, y: 0, width: 560, height: 100)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.isEditable = true
        textView.isSelectable = true
        textView.showsLineNumbers = false
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        textView.text = source
        textView.textSelection = NSRange(location: 0, length: 0)
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
        textView.layoutSubtreeIfNeeded()
        textView.textLayoutManager.ensureLayout(for: textView.textLayoutManager.documentRange)
        return WindowedFixture(
            window: window,
            scrollView: scrollView,
            textView: textView,
            coordinator: coordinator
        )
    }

    func sleepingTask() -> Task<Void, Never> {
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {}
        }
    }

    func yieldForAutomaticTransition() async {
        for _ in 0 ..< 16 {
            await Task.yield()
        }
    }

    static func text(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }
}
