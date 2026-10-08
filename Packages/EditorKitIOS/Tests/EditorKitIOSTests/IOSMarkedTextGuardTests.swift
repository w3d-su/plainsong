@testable import EditorKitIOS
import MarkdownCore
import UIKit
import XCTest

/// Synthetic `setMarkedText` guards. They do not accept Zhuyin or Pinyin on a device.
final class IOSMarkedTextGuardTests: XCTestCase {
    @MainActor
    func testFormatImageAndHighlightDoNotDisturbMarkedText() async throws {
        let debounce = IOSDebounceGate()
        let syntax = IOSGatedTokenizer()
        let harness = IOSEditorHarness(
            text: "hello",
            tokenizer: syntax,
            debounce: debounce,
            syntax: syntax,
            viewport: NSRange(location: 0, length: 16)
        )
        await iosWaitUntil("debounce") { debounce.waiting == 1 }
        debounce.releaseNext()
        await iosWaitUntil("parked") { await syntax.gate.pendingCount() == 1 }

        harness.textView.setMarkedText("ㄓ", selectedRange: NSRange(location: 0, length: 1))
        XCTAssertNotNil(harness.textView.markedTextRange)
        let markedText = harness.textView.textStorage.string
        let markedSelection = harness.textView.selectedRange
        let version = harness.session.version
        let canUndo = harness.textView.undoManager?.canUndo
        let format = MarkdownEditResult(
            replacementRange: NSRange(location: 0, length: 0),
            replacementString: "**",
            newSelection: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(try harness.controller.apply(harness.edit(format, name: "Bold")), .refused(.markedText))
        let image = MarkdownEditResult(
            replacementRange: NSRange(location: 0, length: 0),
            replacementString: "![](assets/a.png)",
            newSelection: NSRange(location: 1, length: 0)
        )
        XCTAssertEqual(try harness.controller.apply(harness.edit(image, name: "Insert Image")), .refused(.markedText))
        XCTAssertEqual(harness.textView.textStorage.string, markedText)
        XCTAssertEqual(harness.textView.selectedRange, markedSelection)
        XCTAssertEqual(harness.session.version, version)
        XCTAssertEqual(harness.textView.undoManager?.canUndo, canUndo)
        XCTAssertNotNil(harness.textView.markedTextRange)

        await syntax.gate.resumeFirst(kind: .strong)
        await Task.yield()
        XCTAssertNil(harness.syntaxToken(at: 0))
        XCTAssertNotNil(harness.textView.markedTextRange)

        harness.textView.unmarkText()
        XCTAssertNil(harness.textView.markedTextRange)
        let committed = harness.textView.textStorage.string
        var parked = false
        for _ in 0 ..< 6 {
            if await syntax.gate.pendingCount() > 0 {
                parked = true
                break
            }
            guard debounce.waiting > 0 else {
                await Task.yield()
                continue
            }
            debounce.releaseNext()
            await Task.yield()
        }
        XCTAssertTrue(parked)
        let latestIndex = await syntax.gate.requestCount() - 1
        let latest = await syntax.gate.request(at: latestIndex)
        XCTAssertEqual(latest?.source, committed)
        if await syntax.gate.pendingCount() > 0 {
            await syntax.gate.resumeFirst(kind: .inlineCode)
        }
        await iosWaitUntil("committed highlight") { harness.syntaxToken(at: 0) == "inlineCode" }
    }
}
