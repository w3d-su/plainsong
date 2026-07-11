import AppKit
@testable import EditorKit
import STTextView
import SwiftUI
import XCTest

@MainActor
final class EditorInstalledDocumentTransitionTests: XCTestCase {
    private let documentA = EditorDocumentIdentity(rawValue: "document-a")
    private let documentB = EditorDocumentIdentity(rawValue: "document-b")

    func testCrossDocumentIMECommitKeepsInstalledBindingUntilDestinationTextIsInstalled() throws {
        let scenario = try makeTransitionScenario()
        assertInitialDocumentA(in: scenario)
        beginMarkedTextComposition(in: scenario)

        scenario.documentBView.updateRepresentedTextView(
            scenario.fixture.scrollView,
            coordinator: scenario.fixture.coordinator
        )
        assertDocumentBRemainsPending(in: scenario)

        scenario.fixture.textView.insertText("台", replacementRange: .notFound)
        assertDocumentACommitIsIsolated(in: scenario)

        scenario.fixture.window.makeFirstResponder(nil)
        let originalOrigin = scenario.fixture.scrollView.contentView.bounds.origin
        scenario.documentBView.updateRepresentedTextView(
            scenario.fixture.scrollView,
            coordinator: scenario.fixture.coordinator
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        assertDocumentBIsInstalledAndNavigated(in: scenario, originalOrigin: originalOrigin)
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
                case .documentA: selectionA = newValue
                case .documentB: selectionB = newValue
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
            navigationRequest: request
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

    static func text(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }
}
