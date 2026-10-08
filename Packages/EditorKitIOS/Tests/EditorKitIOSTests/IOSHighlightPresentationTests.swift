@testable import EditorKitIOS
import SyntaxKit
import UIKit
import XCTest

final class IOSHighlightPresentationTests: XCTestCase {
    @MainActor
    func testRepeatedHighlightKeepsSourceSelectionAndUndo() async {
        let debounce = IOSDebounceGate()
        let syntax = IOSGatedTokenizer()
        let harness = makeHarness(debounce: debounce, syntax: syntax)
        let selection = harness.textView.selectedRange
        let undoBefore = harness.textView.undoManager?.canUndo
        await paint(harness, syntax: syntax, debounce: debounce, kind: .strong)
        harness.controller.noteViewportChanged()
        await paint(harness, syntax: syntax, debounce: debounce, kind: .inlineCode)
        XCTAssertEqual(harness.syntaxToken(at: 0), "inlineCode")
        XCTAssertEqual(harness.textView.textStorage.string, "alpha beta")
        XCTAssertEqual(harness.session.text, "alpha beta")
        XCTAssertEqual(harness.session.version, 0)
        XCTAssertEqual(harness.textView.selectedRange, selection)
        XCTAssertEqual(harness.textView.undoManager?.canUndo, undoBefore)
    }

    @MainActor
    func testStaleThemeAndViewportResultsAreDiscarded() async {
        let debounce = IOSDebounceGate()
        let syntax = IOSGatedTokenizer()
        let harness = makeHarness(debounce: debounce, syntax: syntax)
        await paint(harness, syntax: syntax, debounce: debounce, kind: .strong)

        harness.controller.theme = .dark
        await releaseAndPark(debounce, syntax: syntax)
        harness.controller.theme = .light
        await syntax.gate.resumeFirst(kind: .inlineCode)
        await Task.yield()
        XCTAssertNotEqual(harness.syntaxToken(at: 0), "inlineCode")
        await releaseAndPark(debounce, syntax: syntax)
        await syntax.gate.resumeFirst(kind: .emphasis)
        await iosWaitUntil("theme result") { harness.syntaxToken(at: 0) == "emphasis" }
        XCTAssertEqual(harness.session.version, 0)
        XCTAssertNotEqual(harness.textView.undoManager?.canUndo, true)

        harness.textView.viewportOverride = NSRange(location: 6, length: 4)
        harness.controller.noteViewportChanged()
        await releaseAndPark(debounce, syntax: syntax)
        harness.textView.viewportOverride = NSRange(location: 0, length: 5)
        harness.controller.noteViewportChanged()
        await syntax.gate.resumeFirst(kind: .linkText)
        await Task.yield()
        XCTAssertNotEqual(harness.syntaxToken(at: 6), "linkText")
        await releaseAndPark(debounce, syntax: syntax)
        await syntax.gate.resumeFirst(kind: .quoteMarker)
        await iosWaitUntil("viewport result") { harness.syntaxToken(at: 0) == "quoteMarker" }
        XCTAssertEqual(harness.textView.textStorage.string, "alpha beta")
    }

    @MainActor
    private func makeHarness(debounce: IOSDebounceGate, syntax: IOSGatedTokenizer) -> IOSEditorHarness {
        IOSEditorHarness(
            text: "alpha beta",
            tokenizer: syntax,
            debounce: debounce,
            syntax: syntax,
            viewport: NSRange(location: 0, length: iosUTF16("alpha beta"))
        )
    }

    @MainActor
    private func paint(
        _ harness: IOSEditorHarness,
        syntax: IOSGatedTokenizer,
        debounce: IOSDebounceGate,
        kind: MarkdownSyntaxToken.Kind
    ) async {
        await releaseAndPark(debounce, syntax: syntax)
        await syntax.gate.resumeFirst(kind: kind)
        await iosWaitUntil("paint \(kind)") { harness.syntaxToken(at: 0) == IOSSyntaxAttribute.token(for: kind) }
    }

    @MainActor
    private func releaseAndPark(_ debounce: IOSDebounceGate, syntax: IOSGatedTokenizer) async {
        await iosWaitUntil("debounce") { debounce.waiting >= 1 }
        let before = await syntax.gate.pendingCount()
        debounce.releaseNext()
        await iosWaitUntil("parked") { await syntax.gate.pendingCount() == before + 1 }
    }
}
