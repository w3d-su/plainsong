@testable import EditorKit
import Foundation
import MarkdownCore
import STTextView
import SwiftUI
import XCTest

@MainActor
final class EditingBehaviorsSupportTests: XCTestCase {
    func testPlainSingleCharacterTypingSkipsMarkdownEvaluation() {
        XCTAssertFalse(EditingBehaviorsSupport.needsMarkdownEvaluation(for: "a", fileKind: .markdown))
        XCTAssertFalse(EditingBehaviorsSupport.needsMarkdownEvaluation(for: "中", fileKind: .markdown))
        XCTAssertFalse(EditingBehaviorsSupport.needsMarkdownEvaluation(for: "<", fileKind: .markdown))
    }

    func testEditingTriggersRequireMarkdownEvaluation() {
        XCTAssertTrue(EditingBehaviorsSupport.needsMarkdownEvaluation(for: "\n", fileKind: .markdown))
        XCTAssertTrue(EditingBehaviorsSupport.needsMarkdownEvaluation(for: "\u{2028}", fileKind: .markdown))
        XCTAssertTrue(EditingBehaviorsSupport.needsMarkdownEvaluation(for: "\t", fileKind: .markdown))
        XCTAssertTrue(EditingBehaviorsSupport.needsMarkdownEvaluation(for: "\u{19}", fileKind: .markdown))
        XCTAssertTrue(EditingBehaviorsSupport.needsMarkdownEvaluation(for: "*", fileKind: .markdown))
        XCTAssertTrue(EditingBehaviorsSupport.needsMarkdownEvaluation(for: ")", fileKind: .markdown))
        XCTAssertTrue(EditingBehaviorsSupport.needsMarkdownEvaluation(for: "<", fileKind: .mdx))
    }

    func testCommandProxyRoutesPerformThroughAttachedHandler() {
        let textView = STTextView(frame: .zero)
        let proxy = EditorCommandProxy()
        var observedCommands: [MarkdownEditCommand] = []

        proxy.attach(to: textView, fileKind: .markdown) { command in
            observedCommands.append(command)
        }
        proxy.perform(.toggleCheckbox)
        proxy.detach(from: textView)
        proxy.perform(.formatTable)

        XCTAssertEqual(observedCommands, [.toggleCheckbox])
    }

    func testResponderActionUsesInvokedTextViewsCommandProxy() {
        let firstTextView = STTextView(frame: .zero)
        let secondTextView = STTextView(frame: .zero)
        let firstProxy = EditorCommandProxy()
        let secondProxy = EditorCommandProxy()
        var firstCommands: [MarkdownEditCommand] = []
        var secondCommands: [MarkdownEditCommand] = []

        firstProxy.attach(to: firstTextView, fileKind: .markdown) { command in
            firstCommands.append(command)
        }
        secondProxy.attach(to: secondTextView, fileKind: .markdown) { command in
            secondCommands.append(command)
        }

        firstTextView.plainsongFormatBold(nil)
        secondTextView.plainsongFormatBold(nil)

        XCTAssertEqual(firstCommands, [.format(.bold)])
        XCTAssertEqual(secondCommands, [.format(.bold)])
    }

    func testApplyCommandHonorsSharedEditingGuard() {
        let textView = STTextView(frame: .zero)
        textView.text = "word"
        textView.textSelection = NSRange(location: 0, length: 4)
        let editingGuard = EditingBehaviorGuard()
        editingGuard.isApplying = true

        EditingBehaviorsSupport.applyCommand(.format(.bold), to: textView, editingGuard: editingGuard)

        XCTAssertEqual(Self.text(in: textView), "word")
        XCTAssertTrue(editingGuard.isApplying)

        editingGuard.isApplying = false
        textView.textSelection = NSRange(location: 0, length: 4)
        EditingBehaviorsSupport.applyCommand(.format(.bold), to: textView, editingGuard: editingGuard)

        XCTAssertFalse(editingGuard.isApplying)
        XCTAssertEqual(Self.text(in: textView), "**word**")
    }

    func testAutoPairInsertionSurvivesSynchronousDelegateReentry() {
        let textView = STTextView(frame: .zero)
        let delegate = ReentrantEditingBehaviorDelegate(fileKind: .markdown)
        textView.textDelegate = delegate
        textView.text = ""
        textView.textSelection = NSRange(location: 0, length: 0)

        textView.insertText("(", replacementRange: textView.selectedRange())

        XCTAssertEqual(Self.text(in: textView), "()")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 0))
        XCTAssertFalse(delegate.editingGuard.isApplying)
    }

    func testMenuCommandSurvivesSynchronousDelegateReentry() {
        let textView = STTextView(frame: .zero)
        let delegate = ReentrantEditingBehaviorDelegate(fileKind: .markdown)
        textView.textDelegate = delegate
        textView.text = "word"
        textView.textSelection = NSRange(location: 0, length: 4)

        EditingBehaviorsSupport.applyCommand(.format(.bold), to: textView, editingGuard: delegate.editingGuard)

        XCTAssertEqual(Self.text(in: textView), "**word**")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 4))
        XCTAssertFalse(delegate.editingGuard.isApplying)
    }

    func testMarkedTextCompositionNoOpsThroughEditingBehaviorPath() throws {
        let textView = STTextView(frame: .zero)
        textView.text = ""
        textView.textSelection = NSRange(location: 0, length: 0)
        textView.setMarkedText(
            "ㄓ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())
        let textBeforeBehavior = Self.text(in: textView)
        let selectedRange = textView.selectedRange()
        let affectedRange = try XCTUnwrap(NSTextRange(selectedRange, in: textView.textContentManager))
        let editingGuard = EditingBehaviorGuard()

        let shouldAllowNativeInput = EditingBehaviorsSupport.handleProposedChange(
            in: textView,
            affectedRange: affectedRange,
            replacementString: "(",
            fileKind: .markdown,
            editingGuard: editingGuard
        )

        XCTAssertTrue(shouldAllowNativeInput)
        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertEqual(Self.text(in: textView), textBeforeBehavior)
    }

    func testURLPasteOverSelectionInsertsMarkdownLinkThroughPasteHandler() {
        let (textView, coordinator) = makeInterceptingTextView(
            text: "Read more",
            selection: NSRange(location: 0, length: 4)
        )
        defer { coordinator.detachPasteAndDragHandlers(from: textView) }
        let pasteboard = Self.uniquePasteboard()
        pasteboard.setString("https://example.com", forType: .string)

        XCTAssertEqual(textView.pasteHandler?(textView, pasteboard), true)

        XCTAssertEqual(Self.text(in: textView), "[Read](https://example.com) more")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 27, length: 0))
    }

    func testMultilineURLPasteFallsThroughToNativePaste() {
        let (textView, coordinator) = makeInterceptingTextView(
            text: "Read more",
            selection: NSRange(location: 0, length: 4)
        )
        defer { coordinator.detachPasteAndDragHandlers(from: textView) }
        let pasteboard = Self.uniquePasteboard()
        pasteboard.setString("https://example.com\nhttps://example.org", forType: .string)

        XCTAssertEqual(textView.pasteHandler?(textView, pasteboard), false)
        XCTAssertEqual(Self.text(in: textView), "Read more")
    }

    func testMarkedTextCompositionNoOpsThroughPasteHandler() {
        let (textView, coordinator) = makeInterceptingTextView(
            text: "Read more",
            selection: NSRange(location: 0, length: 4)
        )
        defer { coordinator.detachPasteAndDragHandlers(from: textView) }
        textView.setMarkedText(
            "ㄓ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let pasteboard = Self.uniquePasteboard()
        pasteboard.setString("https://example.com", forType: .string)

        XCTAssertEqual(textView.pasteHandler?(textView, pasteboard), false)
        XCTAssertTrue(textView.hasMarkedText())
    }

    func testClipboardImagePasteUsesAssetInserterAndMarkdownImageBuilder() async throws {
        let inserter: EditorImageAssetInserter = { assets in
            XCTAssertEqual(assets, [.data(Data([1, 2, 3]), suggestedFilename: "image.png")])
            return ["assets/image.png"]
        }
        let (textView, coordinator) = makeInterceptingTextView(
            text: "Before ",
            selection: NSRange(location: 7, length: 0),
            imageAssetInserter: inserter
        )
        defer { coordinator.detachPasteAndDragHandlers(from: textView) }
        let pasteboard = Self.uniquePasteboard()
        pasteboard.setData(Data([1, 2, 3]), forType: .png)

        XCTAssertEqual(textView.pasteHandler?(textView, pasteboard), true)

        try await waitForText(in: textView, toEqual: "Before ![](assets/image.png)")
    }

    func testImageFileDropUsesAssetInserterAndMarkdownImageBuilder() async throws {
        let droppedURL = URL(fileURLWithPath: "/tmp/hero.png")
        let inserter: EditorImageAssetInserter = { assets in
            XCTAssertEqual(assets, [.file(droppedURL)])
            return ["assets/hero.png"]
        }
        let (textView, coordinator) = makeInterceptingTextView(
            text: "Before ",
            selection: NSRange(location: 7, length: 0),
            imageAssetInserter: inserter
        )
        defer { coordinator.detachPasteAndDragHandlers(from: textView) }

        XCTAssertEqual(textView.imageFileDropHandler?(textView, [droppedURL]), true)

        try await waitForText(in: textView, toEqual: "Before ![](assets/hero.png)")
    }

    func testPlainTypingHotPathOnLargeFixtureStaysUnderFrameBudget() throws {
        let fixtureText = try String(contentsOf: Self.repoRoot.appending(path: "Fixtures/large-1mb.md"))
        let textView = STTextView(frame: .zero)
        textView.text = fixtureText
        textView.textSelection = NSRange(location: 0, length: 0)
        let affectedRange = try XCTUnwrap(NSTextRange(textView.selectedRange(), in: textView.textContentManager))
        let editingGuard = EditingBehaviorGuard()

        XCTAssertTrue(EditingBehaviorsSupport.handleProposedChange(
            in: textView,
            affectedRange: affectedRange,
            replacementString: "a",
            fileKind: .markdown,
            editingGuard: editingGuard
        ))

        var maxLatencyMilliseconds = 0.0
        for _ in 0 ..< 200 {
            let start = CFAbsoluteTimeGetCurrent()
            let shouldAllowNativeInput = EditingBehaviorsSupport.handleProposedChange(
                in: textView,
                affectedRange: affectedRange,
                replacementString: "a",
                fileKind: .markdown,
                editingGuard: editingGuard
            )
            maxLatencyMilliseconds = max(
                maxLatencyMilliseconds,
                (CFAbsoluteTimeGetCurrent() - start) * 1000
            )
            XCTAssertTrue(shouldAllowNativeInput)
        }

        print(String(format: "large-1mb.md plain typing hot path max: %.3f ms", maxLatencyMilliseconds))
        XCTAssertLessThan(maxLatencyMilliseconds, 16)
    }

    func testMarkdownTriggerHotPathOnLargeFixtureStaysUnderFrameBudget() throws {
        try assertLargeFixtureHotPath(
            replacementString: "\n",
            expectedNativeInput: true,
            iterations: 200
        )
        try assertLargeFixtureHotPath(
            replacementString: "(",
            expectedNativeInput: false,
            iterations: 50
        )
    }

    private func assertLargeFixtureHotPath(
        replacementString: String,
        expectedNativeInput: Bool,
        iterations: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fixtureText = try String(contentsOf: Self.repoRoot.appending(path: "Fixtures/large-1mb.md"))
        let textView = STTextView(frame: .zero)
        textView.text = fixtureText
        textView.textSelection = NSRange(location: 0, length: 0)
        let affectedRange = try XCTUnwrap(NSTextRange(textView.selectedRange(), in: textView.textContentManager))
        let editingGuard = EditingBehaviorGuard()

        var maxLatencyMilliseconds = 0.0
        for _ in 0 ..< iterations {
            let start = CFAbsoluteTimeGetCurrent()
            let shouldAllowNativeInput = EditingBehaviorsSupport.handleProposedChange(
                in: textView,
                affectedRange: affectedRange,
                replacementString: replacementString,
                fileKind: .markdown,
                editingGuard: editingGuard
            )
            maxLatencyMilliseconds = max(
                maxLatencyMilliseconds,
                (CFAbsoluteTimeGetCurrent() - start) * 1000
            )
            XCTAssertEqual(shouldAllowNativeInput, expectedNativeInput, file: file, line: line)
        }

        print(String(
            format: "large-1mb.md trigger '%@' hot path max: %.3f ms",
            replacementString == "\n" ? "\\n" : replacementString,
            maxLatencyMilliseconds
        ))
        XCTAssertLessThan(maxLatencyMilliseconds, 16, file: file, line: line)
    }

    private static func text(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }

    private func makeInterceptingTextView(
        text: String,
        selection: NSRange,
        imageAssetInserter: EditorImageAssetInserter? = nil
    ) -> (MarkdownSTTextView, MarkdownTextViewCoordinator) {
        let textView = MarkdownSTTextView(frame: .zero)
        let coordinator = MarkdownTextViewCoordinator(
            text: .constant(text),
            selection: .constant(selection)
        )
        textView.textDelegate = coordinator
        textView.text = text
        textView.textSelection = selection
        coordinator.updateImageAssetInserter(imageAssetInserter)
        coordinator.attachPasteAndDragHandlers(to: textView)
        return (textView, coordinator)
    }

    private static func uniquePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PlainsongTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func waitForText(in textView: STTextView, toEqual expected: String) async throws {
        for _ in 0 ..< 20 {
            if Self.text(in: textView) == expected {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(Self.text(in: textView), expected)
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

@MainActor
private final class ReentrantEditingBehaviorDelegate: @preconcurrency STTextViewDelegate {
    let fileKind: FileKind
    let editingGuard = EditingBehaviorGuard()

    init(fileKind: FileKind) {
        self.fileKind = fileKind
    }

    func textView(
        _ textView: STTextView,
        shouldChangeTextIn affectedCharRange: NSTextRange,
        replacementString: String?
    ) -> Bool {
        EditingBehaviorsSupport.handleProposedChange(
            in: textView,
            affectedRange: affectedCharRange,
            replacementString: replacementString,
            fileKind: fileKind,
            editingGuard: editingGuard
        )
    }
}
