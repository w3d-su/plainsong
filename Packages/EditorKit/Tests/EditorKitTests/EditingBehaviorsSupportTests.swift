@testable import EditorKit
import Foundation
import MarkdownCore
import STTextView
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

    private static func text(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
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
