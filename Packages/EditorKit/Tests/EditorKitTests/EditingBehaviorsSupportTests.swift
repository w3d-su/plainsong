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
        var isApplyingEdit = true

        EditingBehaviorsSupport.applyCommand(.format(.bold), to: textView, isApplyingEdit: &isApplyingEdit)

        XCTAssertEqual(Self.text(in: textView), "word")
        XCTAssertTrue(isApplyingEdit)

        isApplyingEdit = false
        textView.textSelection = NSRange(location: 0, length: 4)
        EditingBehaviorsSupport.applyCommand(.format(.bold), to: textView, isApplyingEdit: &isApplyingEdit)

        XCTAssertFalse(isApplyingEdit)
        XCTAssertEqual(Self.text(in: textView), "**word**")
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
        var isApplyingEdit = false

        let shouldAllowNativeInput = EditingBehaviorsSupport.handleProposedChange(
            in: textView,
            affectedRange: affectedRange,
            replacementString: "(",
            fileKind: .markdown,
            isApplyingEdit: &isApplyingEdit
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
        var isApplyingEdit = false

        XCTAssertTrue(EditingBehaviorsSupport.handleProposedChange(
            in: textView,
            affectedRange: affectedRange,
            replacementString: "a",
            fileKind: .markdown,
            isApplyingEdit: &isApplyingEdit
        ))

        var maxLatencyMilliseconds = 0.0
        for _ in 0 ..< 200 {
            let start = CFAbsoluteTimeGetCurrent()
            let shouldAllowNativeInput = EditingBehaviorsSupport.handleProposedChange(
                in: textView,
                affectedRange: affectedRange,
                replacementString: "a",
                fileKind: .markdown,
                isApplyingEdit: &isApplyingEdit
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
