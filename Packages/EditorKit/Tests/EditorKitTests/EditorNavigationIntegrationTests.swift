import AppKit
@testable import EditorKit
import STTextView
import SwiftUI
import XCTest

@MainActor
final class EditorNavigationIntegrationTests: XCTestCase {
    private let documentA = EditorDocumentIdentity(rawValue: "document-a")
    private let documentB = EditorDocumentIdentity(rawValue: "document-b")

    func testSameDocumentSelectsScrollsAndFocusesInWindowWithoutUndoOrTextMutation() throws {
        let source = (0 ... 300)
            .map { $0 == 280 ? "line \($0) exact 🧪 needle" : "line \($0) filler" }
            .joined(separator: "\n")
        let target = (source as NSString).range(of: "exact 🧪 needle")
        let model = NavigationModel(text: source, selection: NSRange(location: 0, length: 0))
        let fixture = try makeWindowedFixture(model: model, source: source, height: 100)
        fixture.textView.textSelection = NSRange(location: 0, length: 0)
        fixture.textView.undoManager?.removeAllActions()
        fixture.window.makeFirstResponder(nil)
        let initialOrigin = fixture.scrollView.contentView.bounds.origin
        let sourceBytes = Data(source.utf8)

        let request = EditorNavigationRequest(
            id: 1,
            documentIdentity: documentA,
            selection: target
        )
        fixture.coordinator.observeNavigationCommand(.navigate(request))
        fixture.coordinator.applyPendingNavigationIfPossible(in: fixture.textView)

        XCTAssertEqual(fixture.textView.selectedRange(), target)
        XCTAssertEqual(model.selection, target)
        XCTAssertTrue(fixture.window.firstResponder === fixture.textView)
        XCTAssertGreaterThan(fixture.scrollView.contentView.bounds.origin.y, initialOrigin.y)
        XCTAssertEqual(Data(Self.text(in: fixture.textView).utf8), sourceBytes)
        XCTAssertFalse(fixture.textView.undoManager?.canUndo == true)
        XCTAssertFalse(fixture.textView.undoManager?.canRedo == true)
        XCTAssertEqual(fixture.coordinator.navigationState.lastHandledRequestID, 1)
    }

    func testCrossDocumentReuseWaitsForExactTargetTextInstallation() throws {
        let sourceA = "Document A keeps its selection"
        let sourceB = "Document B contains the exact target"
        let originalSelection = NSRange(location: 3, length: 4)
        let target = (sourceB as NSString).range(of: "exact target")
        let model = NavigationModel(text: sourceA, selection: originalSelection)
        let fixture = try makeWindowedFixture(model: model, source: sourceA)
        fixture.textView.textSelection = originalSelection

        model.text = sourceB
        let request = EditorNavigationRequest(id: 2, documentIdentity: documentB, selection: target)
        let candidate = fixture.coordinator.prepareDocumentTransition(
            text: fixture.textBinding,
            selection: fixture.selectionBinding,
            documentIdentity: documentB,
            navigationCommand: .navigate(request),
            in: fixture.textView
        )

        XCTAssertEqual(
            fixture.coordinator.applyPendingNavigationIfPossible(in: fixture.textView),
            .pending(.documentMismatch)
        )
        XCTAssertEqual(fixture.coordinator.currentDocumentIdentity, documentA)
        XCTAssertEqual(fixture.textView.selectedRange(), originalSelection)

        install(sourceB, in: fixture)
        fixture.coordinator.finishDocumentTransition(candidate, in: fixture.textView)
        fixture.coordinator.applyPendingNavigationIfPossible(in: fixture.textView)

        XCTAssertEqual(Self.text(in: fixture.textView), sourceB)
        XCTAssertEqual(fixture.textView.selectedRange(), target)
        XCTAssertEqual(fixture.coordinator.navigationState.lastHandledRequestID, 2)
    }

    func testRequestBeforeTargetTextInstallationRemainsPending() throws {
        let placeholder = "placeholder"
        let targetSource = "prefix 待安装 target suffix"
        let target = (targetSource as NSString).range(of: "待安装 target")
        let model = NavigationModel(text: placeholder, selection: NSRange(location: 0, length: 0))
        let fixture = try makeWindowedFixture(model: model, source: placeholder)
        model.text = targetSource
        let request = EditorNavigationRequest(id: 3, documentIdentity: documentA, selection: target)
        fixture.coordinator.observeNavigationCommand(.navigate(request))

        XCTAssertEqual(
            fixture.coordinator.applyPendingNavigationIfPossible(in: fixture.textView),
            .pending(.documentTextNotInstalled)
        )
        XCTAssertEqual(fixture.textView.selectedRange(), NSRange(location: 0, length: 0))

        install(targetSource, in: fixture)
        fixture.coordinator.applyPendingNavigationIfPossible(in: fixture.textView)

        XCTAssertEqual(fixture.textView.selectedRange(), target)
        XCTAssertEqual(fixture.coordinator.navigationState.lastHandledRequestID, 3)
    }

    func testWrongDocumentRequestNeverChangesLiveSelection() throws {
        let source = "current document text"
        let originalSelection = NSRange(location: 2, length: 5)
        let model = NavigationModel(text: source, selection: originalSelection)
        let fixture = try makeWindowedFixture(model: model, source: source)
        fixture.textView.textSelection = originalSelection
        let request = EditorNavigationRequest(
            id: 4,
            documentIdentity: documentB,
            selection: NSRange(location: 0, length: 7)
        )
        fixture.coordinator.observeNavigationCommand(.navigate(request))

        XCTAssertEqual(
            fixture.coordinator.applyPendingNavigationIfPossible(in: fixture.textView),
            .pending(.documentMismatch)
        )
        XCTAssertEqual(fixture.textView.selectedRange(), originalSelection)
        XCTAssertEqual(model.selection, originalSelection)
        XCTAssertNil(fixture.coordinator.navigationState.lastHandledRequestID)
    }

    func testCJKEmojiAndCombiningMarkFixturesSelectExactRawUTF16Ranges() throws {
        let source = "prefix 中文 🧪 e\u{301} suffix"
        let fixtures = ["中文", "🧪", "\u{301}"]
        let model = NavigationModel(text: source, selection: NSRange(location: 0, length: 0))
        let fixture = try makeWindowedFixture(model: model, source: source)

        for (index, substring) in fixtures.enumerated() {
            let exactRange = (source as NSString).range(of: substring)
            let request = EditorNavigationRequest(
                id: UInt64(index + 20),
                documentIdentity: documentA,
                selection: exactRange
            )
            fixture.coordinator.observeNavigationCommand(.navigate(request))
            fixture.coordinator.applyPendingNavigationIfPossible(in: fixture.textView)

            XCTAssertEqual(fixture.textView.selectedRange(), exactRange)
            XCTAssertEqual(model.selection, exactRange)
        }
    }

    func testCanonicalEquivalentRawTextDefersUntilExactUTF16SequenceIsInstalled() throws {
        let boundSource = "a\u{301}\u{327}"
        let liveSource = "a\u{327}\u{301}"
        let originalSelection = NSRange(location: 0, length: 0)
        let target = NSRange(location: 1, length: 1)
        let model = NavigationModel(text: boundSource, selection: originalSelection)
        let fixture = try makeWindowedFixture(model: model, source: boundSource)
        fixture.coordinator.isUpdating = true
        fixture.textView.text = liveSource
        fixture.textView.textSelection = originalSelection
        fixture.coordinator.isUpdating = false
        fixture.window.makeFirstResponder(nil)
        let request = EditorNavigationRequest(
            id: 40,
            documentIdentity: documentA,
            selection: target
        )
        fixture.coordinator.observeNavigationCommand(.navigate(request))

        XCTAssertEqual(
            fixture.coordinator.applyPendingNavigationIfPossible(in: fixture.textView),
            .pending(.documentTextNotInstalled)
        )
        XCTAssertEqual(fixture.textView.selectedRange(), originalSelection)
        XCTAssertFalse(fixture.window.firstResponder === fixture.textView)
        XCTAssertNil(fixture.coordinator.navigationState.lastHandledRequestID)
        XCTAssertEqual(Array(Self.text(in: fixture.textView).utf16), Array(liveSource.utf16))
        XCTAssertEqual(
            Array((Self.text(in: fixture.textView) as NSString).substring(with: target).utf16),
            [0x0327]
        )

        install(boundSource, in: fixture)
        fixture.coordinator.applyPendingNavigationIfPossible(in: fixture.textView)

        XCTAssertEqual(Array(Self.text(in: fixture.textView).utf16), Array(boundSource.utf16))
        XCTAssertEqual(
            Array((Self.text(in: fixture.textView) as NSString).substring(with: target).utf16),
            [0x0301]
        )
        XCTAssertEqual(fixture.textView.selectedRange(), target)
        XCTAssertTrue(fixture.window.firstResponder === fixture.textView)
        XCTAssertEqual(fixture.coordinator.navigationState.lastHandledRequestID, 40)
    }

    func testMarkedTextDefersNavigationUntilCompositionEnds() throws {
        let source = "a中c"
        let target = (source as NSString).range(of: "中")
        let model = NavigationModel(text: source, selection: NSRange(location: 0, length: 0))
        let fixture = try makeWindowedFixture(model: model, source: source)
        fixture.textView.textSelection = target
        fixture.textView.setMarkedText(
            "中",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: target
        )
        XCTAssertTrue(fixture.textView.hasMarkedText())
        let request = EditorNavigationRequest(id: 5, documentIdentity: documentA, selection: target)
        fixture.coordinator.observeNavigationCommand(.navigate(request))

        XCTAssertEqual(
            fixture.coordinator.applyPendingNavigationIfPossible(in: fixture.textView),
            .pending(.markedText)
        )
        XCTAssertNil(fixture.coordinator.navigationState.lastHandledRequestID)

        fixture.textView.insertText("中", replacementRange: .notFound)
        fixture.coordinator.applyPendingNavigationIfPossible(in: fixture.textView)
        RunLoop.current.run(until: Date().addingTimeInterval(0.06))

        XCTAssertFalse(fixture.textView.hasMarkedText())
        XCTAssertEqual(Self.text(in: fixture.textView), source)
        XCTAssertEqual(fixture.textView.selectedRange(), target)
        XCTAssertEqual(fixture.coordinator.navigationState.lastHandledRequestID, 5)
    }

    func testOffWindowRequestCompletesAfterWindowAttachment() throws {
        let source = "off-window exact target"
        let target = (source as NSString).range(of: "exact target")
        let model = NavigationModel(text: source, selection: NSRange(location: 0, length: 0))
        let fixture = try makeDetachedFixture(model: model, source: source)
        let request = EditorNavigationRequest(id: 6, documentIdentity: documentA, selection: target)
        fixture.coordinator.observeNavigationCommand(.navigate(request))

        XCTAssertEqual(
            fixture.coordinator.applyPendingNavigationIfPossible(in: fixture.textView),
            .pending(.notAttached)
        )
        XCTAssertEqual(fixture.textView.selectedRange(), NSRange(location: 0, length: 0))

        let window = NSWindow(
            contentRect: fixture.scrollView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.makeKeyAndOrderFront(nil)
        window.contentView = fixture.scrollView
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))

        XCTAssertEqual(fixture.textView.selectedRange(), target)
        XCTAssertEqual(fixture.coordinator.navigationState.lastHandledRequestID, 6)
        XCTAssertTrue(window.firstResponder === fixture.textView)
    }

    func testExperimentalWYSIWYGNavigationRevealsMatchWithoutChangingSourceOrUndo() throws {
        let source = "Intro **folded match** tail\n"
        let target = (source as NSString).range(of: "folded match")
        let outsideSelection = NSRange(location: 0, length: 0)
        let model = NavigationModel(text: source, selection: outsideSelection)
        let fixture = try makeWindowedFixture(model: model, source: source)
        XCTAssertTrue(fixture.textView.setWYSIWYGZeroWidthFoldingEnabled(true))
        fixture.textView.textSelection = outsideSelection
        let folded = editorNavigationWYSIWYGPresentation(source, selection: outsideSelection, revision: 1)
        let foldedRegion = try XCTUnwrap(folded.foldPlan?.regions.first { $0.kind == .strong })
        XCTAssertFalse(foldedRegion.isRevealed)
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(folded, to: fixture.textView))
        fixture.textView.undoManager?.removeAllActions()
        let sourceBytes = Data(source.utf8)

        let request = EditorNavigationRequest(id: 7, documentIdentity: documentA, selection: target)
        fixture.coordinator.observeNavigationCommand(.navigate(request))
        fixture.coordinator.applyPendingNavigationIfPossible(in: fixture.textView)

        let revealed = editorNavigationWYSIWYGPresentation(source, selection: target, revision: 2)
        let revealedRegion = try XCTUnwrap(revealed.foldPlan?.regions.first { $0.kind == .strong })
        XCTAssertTrue(revealedRegion.isRevealed)
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(revealed, to: fixture.textView))
        XCTAssertEqual(fixture.textView.selectedRange(), target)
        XCTAssertEqual(Data(Self.text(in: fixture.textView).utf8), sourceBytes)
        XCTAssertFalse(fixture.textView.undoManager?.canUndo == true)
        XCTAssertFalse(fixture.textView.undoManager?.canRedo == true)
    }
}

@MainActor
private extension EditorNavigationIntegrationTests {
    final class NavigationModel {
        var text: String
        var selection: NSRange?

        init(text: String, selection: NSRange?) {
            self.text = text
            self.selection = selection
        }
    }

    struct DetachedFixture {
        let scrollView: NSScrollView
        let textView: MarkdownSTTextView
        let coordinator: MarkdownTextViewCoordinator
        let textBinding: Binding<String>
        let selectionBinding: Binding<NSRange?>
    }

    struct WindowedFixture {
        let window: NSWindow
        let scrollView: NSScrollView
        let textView: MarkdownSTTextView
        let coordinator: MarkdownTextViewCoordinator
        let textBinding: Binding<String>
        let selectionBinding: Binding<NSRange?>
    }

    func makeWindowedFixture(
        model: NavigationModel,
        source: String,
        height: CGFloat = 240
    ) throws -> WindowedFixture {
        let detached = try makeDetachedFixture(model: model, source: source, height: height)
        let window = NSWindow(
            contentRect: detached.scrollView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = detached.scrollView
        window.makeKeyAndOrderFront(nil)
        detached.textView.layoutSubtreeIfNeeded()
        detached.textView.textLayoutManager.ensureLayout(for: detached.textView.textLayoutManager.documentRange)
        return WindowedFixture(
            window: window,
            scrollView: detached.scrollView,
            textView: detached.textView,
            coordinator: detached.coordinator,
            textBinding: detached.textBinding,
            selectionBinding: detached.selectionBinding
        )
    }

    func makeDetachedFixture(
        model: NavigationModel,
        source: String,
        height: CGFloat = 240
    ) throws -> DetachedFixture {
        let frame = NSRect(x: 0, y: 0, width: 560, height: height)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.isEditable = true
        textView.isSelectable = true
        textView.showsLineNumbers = false
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        textView.text = source
        textView.textSelection = NSRange(location: 0, length: 0)
        let textBinding = Binding(
            get: { model.text },
            set: { model.text = $0 }
        )
        let selectionBinding = Binding(
            get: { model.selection },
            set: { model.selection = $0 }
        )
        let coordinator = MarkdownTextViewCoordinator(
            text: textBinding,
            selection: selectionBinding
        )
        textView.textDelegate = coordinator
        coordinator.attachFocusHandler(to: textView)
        let candidate = coordinator.prepareDocumentTransition(
            text: textBinding,
            selection: selectionBinding,
            documentIdentity: documentA,
            navigationCommand: nil,
            in: textView
        )
        coordinator.finishDocumentTransition(candidate, in: textView)
        return DetachedFixture(
            scrollView: scrollView,
            textView: textView,
            coordinator: coordinator,
            textBinding: textBinding,
            selectionBinding: selectionBinding
        )
    }

    func install(
        _ source: String,
        in fixture: WindowedFixture
    ) {
        fixture.coordinator.isUpdating = true
        fixture.textView.text = source
        fixture.coordinator.isUpdating = false
        fixture.textView.layoutSubtreeIfNeeded()
        fixture.textView.textLayoutManager.ensureLayout(for: fixture.textView.textLayoutManager.documentRange)
    }

    static func text(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }
}
