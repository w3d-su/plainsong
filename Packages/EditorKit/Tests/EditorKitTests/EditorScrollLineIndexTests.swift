@testable import EditorKit
import STTextView
import SwiftUI
import XCTest

final class EditorScrollLineIndexTests: XCTestCase {
    func testIncrementalEditsMatchAFullRebuild() {
        var generator = SeededGenerator(seed: 0x5EED)
        let pieces = ["", "a", "\n", "\n\n", "x\ny", "🧪", "中文\n", "\r\n", "line\nline\nline"]
        var text = String(repeating: "alpha\nbeta 🧪\n\ngamma\n", count: 20)
        var index = EditorScrollLineIndex(text: text)

        for step in 0 ..< 2000 {
            // Native replacements keep composed characters intact.
            var boundaries = [0]
            for character in text {
                boundaries.append(boundaries[boundaries.count - 1] + character.utf16.count)
            }
            let first = Int.random(in: 0 ..< boundaries.count, using: &generator)
            let last = min(boundaries.count - 1, first + Int.random(in: 0 ... 4, using: &generator))
            let range = NSRange(location: boundaries[first], length: boundaries[last] - boundaries[first])
            let replacement = pieces.randomElement(using: &generator)!

            XCTAssertTrue(index.replaceCharacters(in: range, with: replacement), "step \(step)")
            text = (text as NSString).replacingCharacters(in: range, with: replacement)
            XCTAssertEqual(index, EditorScrollLineIndex(text: text), "step \(step) range \(range)")
        }
    }

    func testBulkRebuildCrossesChunkBoundaries() {
        let text = String(repeating: "x", count: 16383) + "\n" + String(repeating: "y", count: 16384) + "\nz"
        let index = EditorScrollLineIndex(text: text)

        XCTAssertEqual(index.utf16Offset(forOneBasedLine: 2), 16384)
        XCTAssertEqual(index.utf16Offset(forOneBasedLine: 3), 32769)
        XCTAssertEqual(index.oneBasedLine(containingUTF16Offset: 16383), 1)
        XCTAssertEqual(index.oneBasedLine(containingUTF16Offset: 16384), 2)
        XCTAssertNotEqual(index, EditorScrollLineIndex(text: text + "\n"))
    }

    func testEditsThatCannotApplyLeaveTheIndexUnchanged() {
        var index = EditorScrollLineIndex(text: "one\ntwo")
        let original = index
        let large = String(repeating: "a", count: EditorScrollLineIndex.incrementalReplacementLimit + 1)

        XCTAssertFalse(index.replaceCharacters(in: NSRange(location: 0, length: 0), with: large))
        XCTAssertFalse(index.replaceCharacters(in: NSRange(location: 5, length: 3), with: ""))
        XCTAssertFalse(index.replaceCharacters(in: NSRange(location: NSNotFound, length: 0), with: ""))
        XCTAssertFalse(index.replaceCharacters(in: NSRange(location: -1, length: 1), with: ""))
        XCTAssertEqual(index, original)
    }

    @MainActor
    func testUnforwardedNativeEditsStillInvalidateTheIndex() {
        let textView = STTextView(frame: .zero)
        textView.text = "one\ntwo\nthree\n"
        let proxy = EditorScrollProxy()
        var emitted: [EditorScrollIntent] = []
        proxy.onScrollIntent = { emitted.append($0) }
        proxy.attach(to: textView)
        proxy.emitVisibleLine(containingUTF16Offset: 0, in: textView)

        // Same length, different line structure: only the change notification catches it.
        textView.replaceCharacters(in: NSRange(location: 0, length: 4), with: "o\nne")
        emitted.removeAll()
        proxy.emitVisibleLine(containingUTF16Offset: 2, in: textView)

        XCTAssertEqual(emitted, [.viewportChanged(line: 2)])
    }
}

@MainActor
final class EditorScrollLineIndexTypingTests: XCTestCase {
    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testTypingUpdatesTheScrollLineIndexWithoutRescanningTheDocument() throws {
        let source = (1 ... 400).map { "line \($0) 中文🧪" }.joined(separator: "\n")
        let (window, textView, coordinator) = try makeFixture(source: source)
        let proxy = EditorScrollProxy()
        var emitted: [EditorScrollIntent] = []
        proxy.onScrollIntent = { emitted.append($0) }
        coordinator.attachScrollProxy(proxy, to: textView)
        window.makeFirstResponder(textView)
        textView.textSelection = NSRange(location: (source as NSString).range(of: "line 3 ").location, length: 0)
        let rebuildsBeforeTyping = proxy.lineIndexRebuildCount
        XCTAssertGreaterThan(rebuildsBeforeTyping, 0)

        for _ in 0 ..< 5 {
            textView.insertText("a\n", replacementRange: textView.selectedRange())
        }
        textView.deleteBackward(nil)
        textView.undoManager?.undo()
        textView.undoManager?.redo()

        XCTAssertEqual(proxy.lineIndexRebuildCount, rebuildsBeforeTyping, "typing must edit the index in place")
        let text = MarkdownTextView.textStorage(of: textView)?.string ?? ""
        XCTAssertNotEqual(text, source)
        let caret = textView.selectedRange().location
        let document = EditorDocumentIdentity(rawValue: "document")
        emitted.removeAll()
        proxy.emitNavigationLine(containingUTF16Offset: caret, documentIdentity: document, in: textView)
        let expectedLine = EditorScrollLineIndex(text: text).oneBasedLine(containingUTF16Offset: caret)
        XCTAssertEqual(emitted, [.navigation(line: expectedLine, documentIdentity: document)])

        // Programmatic whole-document replacement goes through the same native path.
        coordinator.isUpdating = true
        textView.text = "x\ny\nz"
        coordinator.isUpdating = false
        emitted.removeAll()
        proxy.emitNavigationLine(containingUTF16Offset: 4, documentIdentity: document, in: textView)
        XCTAssertEqual(emitted, [.navigation(line: 3, documentIdentity: document)])
    }

    private func makeFixture(source: String) throws
        -> (NSWindow, MarkdownSTTextView, MarkdownTextViewCoordinator)
    {
        final class Model {
            var text: String
            var selection: NSRange?
            init(text: String) { self.text = text }
        }
        let model = Model(text: source)
        let frame = NSRect(x: 0, y: 0, width: 560, height: 240)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        textView.text = source
        textView.textSelection = NSRange(location: 0, length: 0)
        let text = Binding(get: { model.text }, set: { model.text = $0 })
        let selection = Binding(get: { model.selection }, set: { model.selection = $0 })
        let coordinator = MarkdownTextViewCoordinator(text: text, selection: selection)
        textView.textDelegate = coordinator
        coordinator.attachFocusHandler(to: textView)
        let candidate = coordinator.prepareDocumentTransition(
            text: text,
            selection: selection,
            documentIdentity: EditorDocumentIdentity(rawValue: "document"),
            navigationCommand: nil,
            in: textView
        )
        coordinator.finishDocumentTransition(candidate, in: textView)
        let window = EditorFindControllerTestSupport.registerWindowForTeardown(NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        ))
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        textView.layoutSubtreeIfNeeded()
        return (window, textView, coordinator)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
