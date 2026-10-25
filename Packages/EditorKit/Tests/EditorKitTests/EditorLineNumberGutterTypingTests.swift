import AppKit
@testable import EditorKit
import STTextView
import SwiftUI
import XCTest

/// The gutter on the typing path: per-keystroke work must not depend on the document.
@MainActor
final class EditorLineNumberGutterTypingTests: XCTestCase {
    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testTypingKeepsNumbersCurrentWithoutRescanningTheDocument() throws {
        let source = (1 ... 3000).map { "line \($0) 中文🧪" }.joined(separator: "\n")
        let editor = try makeEditor(source: source)
        let middle = (source as NSString).range(of: "line 1500 ").location
        editor.textView.textSelection = NSRange(location: middle, length: 0)
        editor.textView.scrollRangeToVisible(editor.textView.selectedRange())
        _ = try draw(editor)
        let rebuilds = editor.textView.lineIndexCache.rebuildCount

        for _ in 0 ..< 3 {
            editor.textView.insertText("a\n", replacementRange: editor.textView.selectedRange())
        }
        editor.textView.deleteBackward(nil)
        editor.textView.undoManager?.undo()
        let labels = try draw(editor)

        XCTAssertEqual(editor.textView.lineIndexCache.rebuildCount, rebuilds, "typing edits the index in place")
        let text = try XCTUnwrap(MarkdownTextView.textStorage(of: editor.textView)?.string)
        let index = EditorScrollLineIndex(text: text)
        let caretLine = index.oneBasedLine(containingUTF16Offset: editor.textView.selectedRange().location)
        XCTAssertEqual(labels.filter(\.isCurrent).map(\.number), [caretLine])
        XCTAssertEqual(labels.map(\.number), Array(labels[0].number ..< labels[0].number + labels.count))
        // Against a fresh scan: each number sits on the first line of the paragraph that
        // starts at that line's offset.
        let contentManager = editor.textView.textContentManager
        for label in labels {
            let start = index.utf16Offset(forOneBasedLine: label.number)
            let location = try XCTUnwrap(contentManager.location(
                contentManager.documentRange.location,
                offsetBy: start
            ))
            let fragment = try XCTUnwrap(editor.textView.textLayoutManager.textLayoutFragment(for: location))
            XCTAssertEqual(
                contentManager
                    .offset(from: contentManager.documentRange.location, to: fragment.rangeInElement.location),
                start
            )
            let firstLine = try XCTUnwrap(fragment.textLineFragments.first)
            let baseline = fragment.layoutFragmentFrame.minY + firstLine.typographicBounds.minY + firstLine.glyphOrigin
                .y
            XCTAssertEqual(label.baseline, baseline, accuracy: 0.5, "line \(label.number)")
        }
    }

    func testDrawWorkDoesNotGrowWithTheDocumentOrTheTextAboveTheViewport() throws {
        let short = try typingCost(lineCount: 1500)
        let long = try typingCost(lineCount: 60000)

        XCTAssertEqual(short.rebuilds, 0)
        XCTAssertEqual(long.rebuilds, 0)
        // A draw visits the TextKit viewport only: the same fragments for both documents.
        XCTAssertEqual(long.visits, short.visits, accuracy: 3)
        XCTAssertLessThan(long.visits, 120)
        // Loose: timings are noisy on a loaded machine, but a scan of the 59,000 lines
        // above the viewport would cost a large multiple.
        XCTAssertLessThan(long.drawMilliseconds, max(short.drawMilliseconds * 4, 2), "\(short) \(long)")
    }

    func testMarkedTextDefersTheWidthChangeUntilCommitted() throws {
        let source = (1 ... 998).map { "line \($0)" }.joined(separator: "\n") + "\n段落"
        let editor = try makeEditor(source: source)
        let length = (source as NSString).length
        editor.textView.textSelection = NSRange(location: length, length: 0)
        _ = try draw(editor)
        let thickness = editor.gutter.thickness
        let containerWidth = editor.textView.textContainer.size.width
        XCTAssertEqual(editor.gutter.digits, 3)

        // A composition that adds a line takes the count to 1,000 (4 digits).
        editor.textView.setMarkedText(
            "ㄓ\nㄓ",
            selectedRange: NSRange(location: 3, length: 0),
            replacementRange: .notFound
        )
        XCTAssertTrue(editor.textView.hasMarkedText())
        editor.textView.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.gutter.thickness, thickness, "no re-wrap while composing")
        XCTAssertEqual(editor.textView.textContainer.size.width, containerWidth)
        let composing = try draw(editor)
        XCTAssertEqual(composing.last?.number, 1000, "numbers still follow the marked text")

        editor.textView.insertText("中\n文", replacementRange: .notFound)
        XCTAssertFalse(editor.textView.hasMarkedText())
        editor.textView.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.gutter.digits, 4)
        XCTAssertGreaterThan(editor.gutter.thickness, thickness)
        XCTAssertLessThan(editor.textView.textContainer.size.width, containerWidth)
    }

    func testDeletingBackBelowAThousandLinesKeepsTheWidth() throws {
        let source = (1 ... 999).map { "line \($0)" }.joined(separator: "\n")
        let editor = try makeEditor(source: source)
        editor.textView.textSelection = NSRange(location: (source as NSString).length, length: 0)
        editor.textView.insertText("\n", replacementRange: editor.textView.selectedRange())
        XCTAssertEqual(editor.gutter.digits, 4)
        let thickness = editor.gutter.thickness

        editor.textView.deleteBackward(nil)
        XCTAssertEqual(editor.textView.lineIndexCache.currentIndex().lineCount, 999)
        XCTAssertEqual(editor.gutter.thickness, thickness, "hysteresis: no re-wrap at 999/1000")
    }

    // MARK: - Helpers

    private struct Editor {
        let window: NSWindow
        let textView: MarkdownSTTextView
        let gutter: EditorLineNumberGutterView
        let coordinator: MarkdownTextViewCoordinator
    }

    private final class Model {
        var text: String
        var selection: NSRange?

        init(text: String) {
            self.text = text
        }
    }

    private struct TypingCost: CustomStringConvertible {
        let visits: Double
        let drawMilliseconds: Double
        let rebuilds: Int

        var description: String {
            "visits \(visits), draw \(drawMilliseconds) ms, rebuilds \(rebuilds)"
        }
    }

    private func typingCost(lineCount: Int) throws -> TypingCost {
        let source = (1 ... lineCount).map { "line \($0) with some prose to wrap" }.joined(separator: "\n")
        let editor = try makeEditor(source: source)
        let middle = (source as NSString).range(of: "line \(lineCount / 2) ").location
        editor.textView.textSelection = NSRange(location: middle, length: 0)
        editor.textView.scrollRangeToVisible(editor.textView.selectedRange())
        _ = try draw(editor)
        let rebuilds = editor.textView.lineIndexCache.rebuildCount
        var visits: [Double] = []
        var milliseconds: [Double] = []
        for _ in 0 ..< 9 {
            editor.textView.insertText("a", replacementRange: editor.textView.selectedRange())
            _ = try draw(editor)
            visits.append(Double(editor.gutter.lastDrawFragmentVisits))
            milliseconds.append(editor.gutter.lastDrawMilliseconds)
        }
        return TypingCost(
            visits: visits.sorted()[4],
            drawMilliseconds: milliseconds.sorted()[4],
            rebuilds: editor.textView.lineIndexCache.rebuildCount - rebuilds
        )
    }

    private func draw(_ editor: Editor) throws -> [EditorLineNumberGutterLayout.Label] {
        // A scroll that STTextView performs after its own layout pass (to reveal the caret)
        // is laid out by the next display cycle; tests have none, so lay out explicitly.
        editor.textView.needsLayout = true
        editor.textView.layoutSubtreeIfNeeded()
        let gutter = editor.gutter
        let rep = try XCTUnwrap(gutter.bitmapImageRepForCachingDisplay(in: gutter.bounds))
        gutter.cacheDisplay(in: gutter.bounds, to: rep)
        return gutter.lastDrawnLabels
    }

    /// The app's wiring: the coordinator forwards native edits to the shared line index.
    private func makeEditor(source: String) throws -> Editor {
        let model = Model(text: source)
        let frame = NSRect(x: 0, y: 0, width: 560, height: 360)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.isEditable = true
        textView.isSelectable = true
        textView.highlightSelectedLine = true
        textView.isHorizontallyResizable = false
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        let text = Binding(get: { model.text }, set: { model.text = $0 })
        let selection = Binding(get: { model.selection }, set: { model.selection = $0 })
        let coordinator = MarkdownTextViewCoordinator(text: text, selection: selection)
        textView.textDelegate = coordinator
        textView.text = source
        textView.textSelection = NSRange(location: 0, length: 0)
        coordinator.attachFocusHandler(to: textView)
        let candidate = coordinator.prepareDocumentTransition(
            text: text,
            selection: selection,
            documentIdentity: EditorDocumentIdentity(rawValue: "document"),
            navigationCommand: nil,
            in: textView
        )
        coordinator.finishDocumentTransition(candidate, in: textView)
        textView.setLineNumberGutterStyle(EditorLineNumberGutterView.Style(
            font: MarkdownSyntaxHighlighter.defaultFont,
            textColor: .secondaryLabelColor,
            currentLineTextColor: .labelColor
        ))
        let gutter = try XCTUnwrap(textView.lineNumberGutter)
        let window = EditorFindControllerTestSupport.registerWindowForTeardown(NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        ))
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        textView.layoutSubtreeIfNeeded()
        return Editor(window: window, textView: textView, gutter: gutter, coordinator: coordinator)
    }
}
