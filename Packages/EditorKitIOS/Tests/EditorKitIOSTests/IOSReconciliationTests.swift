@testable import EditorKitIOS
import MarkdownCore
import SwiftUI
import SyntaxKit
import UIKit
import XCTest

final class IOSReconciliationTests: XCTestCase {
    @MainActor
    func testSameSourceKeepsPresentationAndDifferentMiddleReparsesWithoutTyping() async {
        let debounce = IOSDebounceGate()
        let syntax = IOSGatedTokenizer()
        let original = "aaaaWWWaaaa"
        let harness = IOSEditorHarness(
            text: original,
            tokenizer: syntax,
            debounce: debounce,
            syntax: syntax,
            viewport: NSRange(location: 0, length: 32)
        )
        let covered = NSRange(location: 0, length: iosUTF16(original))
        XCTAssertTrue(IOSHighlightPresenter.apply(
            tokens: [MarkdownSyntaxToken(kind: .strong, range: NSRange(location: 4, length: 3))],
            coveredRange: covered,
            expectedFragment: original,
            theme: .light,
            to: harness.textView
        ))
        XCTAssertEqual(harness.syntaxToken(at: 4), "strong")
        await iosWaitUntil("attach debounce") { debounce.waiting == 1 }
        let same = proposal(harness, text: original)
        guard case let .installed(revision) = harness.controller.installExternalReload(same) else {
            return XCTFail("same-source reload was not installed")
        }
        XCTAssertEqual(revision.version, harness.session.version)
        XCTAssertEqual(harness.syntaxToken(at: 4), "strong")
        XCTAssertEqual(harness.session.version, 0)
        await Task.yield()
        XCTAssertEqual(debounce.waiting, 1)

        let changed = "aaaaXXXaaaa"
        XCTAssertEqual(iosUTF16(changed), iosUTF16(original))
        guard case .installed = harness.controller.installExternalReload(proposal(harness, text: changed)) else {
            return XCTFail("changed reload was not installed")
        }
        XCTAssertNil(harness.syntaxToken(at: 4))
        XCTAssertEqual(harness.session.text, changed)
        XCTAssertEqual(harness.textView.textStorage.string, changed)
        await iosWaitUntil("reparse debounce") { debounce.waiting >= 2 }
        while debounce.waiting > 1 {
            debounce.releaseNext()
            await Task.yield()
        }
        debounce.releaseNext()
        await iosWaitUntil("reparse parked") { await syntax.gate.pendingCount() >= 1 }
        while await syntax.gate.pendingCount() > 1 {
            await syntax.gate.resumeFirst(kind: .emphasis)
        }
        let parked = await syntax.gate.request(at: (syntax.gate.requestCount()) - 1)
        XCTAssertEqual(parked?.source, changed)
        await syntax.gate.resumeFirst(kind: .inlineCode)
        await iosWaitUntil("repainted") { harness.syntaxToken(at: 4) == "inlineCode" }
        XCTAssertFalse(harness.textView.undoManager?.canUndo ?? false)
    }

    @MainActor
    func testComposingReloadIsDeferredAndHideKeepsUndo() {
        let harness = IOSEditorHarness(text: "compose")
        XCTAssertTrue(IOSHighlightPresenter.apply(
            tokens: [MarkdownSyntaxToken(kind: .strong, range: NSRange(location: 0, length: 7))],
            coveredRange: NSRange(location: 0, length: 7),
            expectedFragment: "compose",
            theme: .light,
            to: harness.textView
        ))
        harness.textView.setMarkedText("ㄓ", selectedRange: NSRange(location: 0, length: 1))
        XCTAssertNotNil(harness.textView.markedTextRange)
        let composingText = harness.textView.textStorage.string
        let composingVersion = harness.session.version
        let deferred = harness.controller.installExternalReload(proposal(harness, text: "other"))
        XCTAssertEqual(deferred, .deferred)
        XCTAssertEqual(harness.textView.textStorage.string, composingText)
        XCTAssertNotEqual(harness.textView.textStorage.string, "other")
        XCTAssertEqual(harness.session.version, composingVersion)
        harness.textView.unmarkText()

        let editor = IOSEditorHarness(text: "undo-me")
        editor.placeCaret(at: iosUTF16("undo-me"))
        editor.textView.insertText("!")
        XCTAssertTrue(editor.textView.undoManager?.canUndo ?? false)
        let edited = editor.textView.textStorage.string
        let selection = editor.textView.selectedRange
        editor.controller.setContentVisible(false)
        XCTAssertEqual(editor.textView.textStorage.string, edited)
        XCTAssertEqual(editor.textView.selectedRange, selection)
        XCTAssertTrue(editor.textView.undoManager?.canUndo ?? false)
        editor.controller.setContentVisible(true)
        editor.controller.undo()
        XCTAssertEqual(editor.textView.textStorage.string, "undo-me")
        editor.controller.redo()
        XCTAssertEqual(editor.textView.textStorage.string, edited)
    }

    @MainActor
    func testSwiftUIUpdateDoesNotResetTheNativeBuffer() {
        let harness = IOSEditorHarness(text: "stable")
        harness.placeCaret(at: 6)
        harness.textView.insertText("!")
        let text = harness.textView.textStorage.string
        let model = Tick()
        let hosting = UIHostingController(rootView: ReloadHost(controller: harness.controller, tick: model))
        harness.window.rootViewController = hosting
        hosting.view.frame = harness.window.bounds
        hosting.view.layoutIfNeeded()
        model.tick += 1
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        XCTAssertEqual(harness.textView.textStorage.string, text)
        XCTAssertTrue(harness.textView.undoManager?.canUndo ?? false)
        XCTAssertNotNil(harness.controller.captureSnapshot())
    }

    @MainActor
    private func proposal(_ harness: IOSEditorHarness, text: String) -> IOSDocumentReloadProposal {
        IOSDocumentReloadProposal(
            operationID: UUID(),
            capturedRevision: IOSDocumentRevision(
                documentID: harness.identity,
                version: harness.session.version
            ),
            accessGeneration: 1,
            text: text,
            fileURL: URL(fileURLWithPath: "/tmp/note.md"),
            fileKind: .markdown,
            statistics: TextStatistics(text: text)
        )
    }
}

private final class Tick: ObservableObject {
    @Published var tick = 0
}

private struct ReloadHost: View {
    let controller: IOSSourceEditorController
    @ObservedObject var tick: Tick

    var body: some View {
        IOSMarkdownEditorRepresentable(controller: controller)
            .opacity(tick.tick == 0 ? 1 : 0.99)
    }
}
