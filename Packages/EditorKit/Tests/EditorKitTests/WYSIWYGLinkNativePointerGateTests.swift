import AppKit
@testable import EditorKit
import STTextView
import XCTest

@MainActor
final class WYSIWYGLinkNativePointerGateTests: XCTestCase {
    func testL6RealPointerClicksOnFoldedLinkTextAndHiddenRunEdgesDoNotTrapCaret() throws {
        let source = "Before [linked text](https://example.com/a/long/destination) after"
        let content = source.nsRange(of: "linked text")
        let firstCharacter = NSRange(location: content.location, length: 1)
        let lastCharacter = NSRange(location: NSMaxRange(content) - 1, length: 1)

        for (target, fraction) in [
            (content, CGFloat(0.5)),
            (firstCharacter, CGFloat(0.05)),
            (lastCharacter, CGFloat(0.95)),
        ] {
            let fixture = try makeWindowedEditor(source: source)
            XCTAssertTrue(applyLinkPresentation(
                source,
                selection: NSRange(location: 0, length: 0),
                revision: 1,
                to: fixture.textView
            ))

            let caret = try pointerClick(on: target, in: fixture, fraction: fraction)
            let link = try linkRegion(source: source, caret: caret)
            XCTAssertTrue(link.isRevealed)
            XCTAssertNil(fixture.textView.wysiwygFoldedDelimiterRange(containingInterior: caret))
        }
    }

    func testL6RealPointerDragAcrossFoldedLinkCopiesExactRawMarkdown() throws {
        let source = "Before [linked text](https://example.com/a/long/destination) after"
        let fixture = try makeWindowedEditor(source: source)
        XCTAssertTrue(applyLinkPresentation(
            source,
            selection: NSRange(location: 0, length: 0),
            revision: 1,
            to: fixture.textView
        ))

        _ = try pointerClick(on: source.nsRange(of: "Before"), in: fixture, fraction: 0.2)
        _ = try pointerClick(
            on: source.nsRange(of: "after"),
            in: fixture,
            shift: true,
            fraction: 0.8
        )

        let selection = fixture.textView.selectedRange()
        let rawSelection = (source as NSString).substring(with: selection)
        XCTAssertTrue(rawSelection.contains("[linked text](https://example.com/a/long/destination)"))
        let pasteboard = uniquePasteboard()
        XCTAssertTrue(fixture.textView.writeSelection(to: pasteboard, types: [.string]))
        XCTAssertEqual(pasteboard.string(forType: .string), rawSelection)

        let presentation = linkPresentation(source, selection: selection, revision: 2)
        XCTAssertTrue(try presentation.onlyLinkRegion().isRevealed)
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(presentation, to: fixture.textView))
        XCTAssertEqual(fixture.textView.selectedRange(), selection)
    }
}

@MainActor
private extension WYSIWYGLinkNativePointerGateTests {
    struct WindowedEditor {
        let window: NSWindow
        let textView: MarkdownSTTextView
    }

    func makeWindowedEditor(source: String) throws -> WindowedEditor {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.isEditable = true
        textView.isSelectable = true
        textView.showsLineNumbers = false
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        textView.text = source
        XCTAssertTrue(textView.setWYSIWYGZeroWidthFoldingEnabled(true))

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        textView.layoutSubtreeIfNeeded()
        textView.textLayoutManager.ensureLayout(for: textView.textLayoutManager.documentRange)
        return WindowedEditor(window: window, textView: textView)
    }

    func pointerClick(
        on characterRange: NSRange,
        in fixture: WindowedEditor,
        shift: Bool = false,
        fraction: CGFloat = 0.5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Int {
        let screenRect = fixture.textView.firstRect(forCharacterRange: characterRange, actualRange: nil)
        XCTAssertGreaterThan(screenRect.width, 0, file: file, line: line)
        XCTAssertGreaterThan(screenRect.height, 0, file: file, line: line)
        let screenPoint = CGPoint(
            x: screenRect.minX + screenRect.width * fraction,
            y: screenRect.midY
        )
        let windowPoint = fixture.window.convertPoint(fromScreen: screenPoint)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: shift ? .shift : [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), file: file, line: line)

        fixture.textView.mouseDown(with: event)
        return fixture.textView.selectedRange().location
    }

    func linkRegion(source: String, caret: Int) throws -> WYSIWYGFoldRegion {
        try linkPresentation(
            source,
            selection: NSRange(location: caret, length: 0),
            revision: 99
        ).onlyLinkRegion()
    }

    func uniquePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PlainsongLinkPointerGate.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }
}

private extension HighlightedText {
    func onlyLinkRegion() throws -> WYSIWYGFoldRegion {
        let links = try XCTUnwrap(foldPlan).regions.filter { $0.kind == .link }
        XCTAssertEqual(links.count, 1)
        return try XCTUnwrap(links.first)
    }
}

private extension String {
    func nsRange(of substring: String) -> NSRange {
        let range = (self as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected to find '\(substring)'")
        return range
    }
}
