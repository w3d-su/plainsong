@testable import EditorKitIOS
import MarkdownCore
import UIKit
import XCTest

final class IOSHighlightSchedulerTests: XCTestCase {
    @MainActor
    func testBlockedParseThenEditsRunsOnlyTheLatestRequest() async {
        let debounce = IOSDebounceGate()
        let syntax = IOSGatedTokenizer()
        let harness = IOSEditorHarness(
            text: "one",
            tokenizer: syntax,
            debounce: debounce,
            syntax: syntax,
            viewport: NSRange(location: 0, length: 64)
        )
        await iosWaitUntil("initial debounce") { debounce.waiting == 1 }
        debounce.releaseNext()
        await iosWaitUntil("initial parked") { await syntax.gate.pendingCount() == 1 }
        harness.placeCaret(at: iosUTF16("one"))
        harness.textView.insertText("A")
        harness.textView.insertText("B")
        harness.textView.insertText("C")
        let parked = await syntax.gate.pendingCount()
        let inFlight = await syntax.gate.maximumInFlight()
        XCTAssertEqual(parked, 1)
        XCTAssertEqual(inFlight, 1)
        XCTAssertEqual(debounce.waiting, 3)
        await syntax.gate.resumeFirst(kind: .strong)
        await Task.yield()
        XCTAssertNil(harness.syntaxToken(at: 0))
        debounce.releaseNext()
        debounce.releaseNext()
        debounce.releaseNext()
        await iosWaitUntil("latest parked") { await syntax.gate.pendingCount() == 1 }
        let latest = await syntax.gate.request(at: 1)
        XCTAssertEqual(latest?.source, "oneABC")
        let inFlightBeforeApply = await syntax.gate.maximumInFlight()
        XCTAssertEqual(inFlightBeforeApply, 1)
        await syntax.gate.resumeFirst(kind: .inlineCode)
        await iosWaitUntil("latest applied") { harness.syntaxToken(at: 0) == "inlineCode" }
        XCTAssertEqual(harness.textView.textStorage.string, "oneABC")
        let inFlightAfterApply = await syntax.gate.maximumInFlight()
        XCTAssertEqual(inFlightAfterApply, 1)
    }

    @MainActor
    func testHideReappearAndUnmountDropLateResults() async {
        let debounce = IOSDebounceGate()
        let syntax = IOSGatedTokenizer()
        let harness = IOSEditorHarness(
            text: "visible",
            tokenizer: syntax,
            debounce: debounce,
            syntax: syntax,
            viewport: NSRange(location: 0, length: 16)
        )
        await iosWaitUntil("debounce") { debounce.waiting == 1 }
        debounce.releaseNext()
        await iosWaitUntil("parked") { await syntax.gate.pendingCount() == 1 }
        harness.controller.setContentVisible(false)
        await syntax.gate.resumeFirst(kind: .emphasis)
        await Task.yield()
        XCTAssertNotEqual(harness.syntaxToken(at: 0), "emphasis")

        harness.controller.setContentVisible(true)
        await iosWaitUntil("shown debounce") { debounce.waiting >= 1 }
        debounce.releaseNext()
        await iosWaitUntil("shown parked") { await syntax.gate.pendingCount() == 1 }
        await syntax.gate.resumeFirst(kind: .inlineCode)
        await iosWaitUntil("shown token") { harness.syntaxToken(at: 0) == "inlineCode" }

        harness.controller.noteViewportChanged()
        await iosWaitUntil("unmount debounce") { debounce.waiting >= 1 }
        debounce.releaseNext()
        await iosWaitUntil("unmount parked") { await syntax.gate.pendingCount() == 1 }
        harness.controller.invalidateHost()
        await syntax.gate.resumeFirst(kind: .quoteMarker)
        await Task.yield()
        XCTAssertNotEqual(harness.syntaxToken(at: 0), "quoteMarker")
        XCTAssertNil(harness.controller.captureSnapshot())
    }

    @MainActor
    func testReconciliationFloorRejectsAnAlreadyProducedResult() async {
        let debounce = IOSDebounceGate()
        let syntax = IOSGatedTokenizer()
        let harness = IOSEditorHarness(
            text: "aaaaWWWaaaa",
            tokenizer: syntax,
            debounce: debounce,
            syntax: syntax,
            viewport: NSRange(location: 0, length: 32)
        )
        await iosWaitUntil("debounce") { debounce.waiting == 1 }
        debounce.releaseNext()
        await iosWaitUntil("parked") { await syntax.gate.pendingCount() == 1 }
        let proposal = IOSDocumentReloadProposal(
            operationID: UUID(),
            capturedRevision: IOSDocumentRevision(documentID: harness.identity, version: harness.session.version),
            accessGeneration: 1,
            text: "aaaaXXXaaaa",
            fileURL: URL(fileURLWithPath: "/tmp/note.md"),
            fileKind: .markdown,
            statistics: TextStatistics(text: "aaaaXXXaaaa")
        )
        let outcome = harness.controller.installExternalReload(proposal)
        guard case .installed = outcome else {
            return XCTFail("reload did not install: \(outcome)")
        }
        await syntax.gate.resumeFirst(kind: .strong)
        await Task.yield()
        XCTAssertNotEqual(harness.syntaxToken(at: 4), "strong")
        await iosWaitUntil("reload debounce") { debounce.waiting >= 1 }
        debounce.releaseNext()
        await iosWaitUntil("reload parked") { await syntax.gate.pendingCount() == 1 }
        let reloaded = await syntax.gate.request(at: 1)
        XCTAssertEqual(reloaded?.source, "aaaaXXXaaaa")
        await syntax.gate.resumeFirst(kind: .inlineCode)
        await iosWaitUntil("reloaded token") { harness.syntaxToken(at: 4) == "inlineCode" }
        XCTAssertEqual(harness.textView.textStorage.string, "aaaaXXXaaaa")
    }
}
