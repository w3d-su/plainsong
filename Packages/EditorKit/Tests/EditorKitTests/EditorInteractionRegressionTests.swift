import AppKit
@testable import EditorKit
import STTextView
import SwiftUI
import XCTest

@MainActor
final class EditorInteractionRegressionTests: XCTestCase {
    override func tearDown() {
        EditorFindControllerTestSupport.tearDownWindows()
        super.tearDown()
    }

    func testShiftDirectionReversalsShrinkAndCrossTheOriginalAnchor() throws {
        let (_, view, _) = try fixture(source: "abcdefg", wysiwyg: true)
        view.textSelection = NSRange(location: 3, length: 0)
        view.moveRightAndModifySelection(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 1))
        view.moveLeftAndModifySelection(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 0))
        view.moveLeftAndModifySelection(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 1))
        view.moveRightAndModifySelection(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 0))
        // Reassigning even the same range is a new selection intent, not our old anchor.
        view.textSelection = NSRange(location: 1, length: 2)
        view.moveRightAndModifySelection(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 3))
        view.moveLeftAndModifySelection(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 2))
        XCTAssertEqual(view.text, "abcdefg")
    }

    func testNativeWordAndCustomCharacterHandoffsKeepTheActiveEnd() throws {
        let (_, view, _) = try fixture(source: "one two three\nnext line", wysiwyg: true)
        view.textSelection = NSRange(location: 3, length: 0)
        view.moveWordRightAndModifySelection(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 4))
        view.moveLeftAndModifySelection(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 3))

        view.textSelection = NSRange(location: 7, length: 0)
        view.moveWordLeftAndModifySelection(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 3))
        view.moveRightAndModifySelection(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 5, length: 2))

        view.textSelection = NSRange(location: 7, length: 0)
        view.moveLeftAndModifySelection(nil)
        XCTAssertEqual(view.textLayoutManager.textSelections.last?.affinity, .upstream)
        view.moveWordRightAndModifySelection(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 7, length: 0))
    }

    func testNativeAndCustomMovementHandoffsMatchSourceInBothDirections() throws {
        let text = "one two three\nnext line\nlast paragraph"
        let (_, source, _) = try fixture(source: text, wysiwyg: false)
        let (_, wysiwyg, _) = try fixture(source: text, wysiwyg: true)
        let native: [(String, (MarkdownSTTextView) -> Void)] = [
            ("word left", { $0.moveWordLeftAndModifySelection(nil) }),
            ("word right", { $0.moveWordRightAndModifySelection(nil) }),
            ("up", { $0.moveUpAndModifySelection(nil) }),
            ("down", { $0.moveDownAndModifySelection(nil) }),
            ("paragraph start", { $0.moveToBeginningOfParagraphAndModifySelection(nil) }),
            ("paragraph end", { $0.moveToEndOfParagraphAndModifySelection(nil) }),
        ]
        let custom: [(String, (MarkdownSTTextView) -> Void)] = [
            ("left", { $0.moveLeftAndModifySelection(nil) }),
            ("right", { $0.moveRightAndModifySelection(nil) }),
        ]
        for start in [7, 18] {
            for (nativeName, nativeMove) in native {
                for (customName, customMove) in custom {
                    for nativeFirst in [true, false] {
                        for view in [source, wysiwyg] {
                            view.textSelection = NSRange(location: start, length: 0)
                        }
                        let steps = nativeFirst ? [nativeMove, customMove] : [customMove, nativeMove]
                        for step in steps {
                            step(source)
                            step(wysiwyg)
                            let context = "start=\(start), \(nativeName), \(customName), nativeFirst=\(nativeFirst)"
                            XCTAssertEqual(wysiwyg.selectedRange(), source.selectedRange(), context)
                            if source.selectedRange().length > 0 {
                                XCTAssertEqual(wysiwyg.textLayoutManager.textSelections.last?.affinity,
                                               source.textLayoutManager.textSelections.last?.affinity, context)
                            }
                        }
                        XCTAssertEqual(wysiwyg.text, text)
                    }
                }
            }
        }
    }

    func testMouseSelectionsHandOffToCharacterAndWordMovement() throws {
        let (window, view, _) = try fixture(source: "one two three\nnext line", wysiwyg: true)
        for dragging in [false, true] {
            for (start, end) in [(3, 7), (7, 3)] {
                try view.mouseDown(with: pointerEvent(view: view, window: window, offset: start))
                let event = try pointerEvent(view: view, window: window, offset: end,
                                             type: dragging ? .leftMouseDragged : .leftMouseDown,
                                             modifiers: dragging ? [] : [.shift])
                if dragging {
                    view.mouseDragged(with: event)
                    try view.mouseUp(with: pointerEvent(view: view, window: window, offset: end, type: .leftMouseUp))
                } else { view.mouseDown(with: event) }
                XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 4))
                if end < start { view.moveRightAndModifySelection(nil) } else { view.moveLeftAndModifySelection(nil) }
                XCTAssertEqual(view.selectedRange(), NSRange(location: end < start ? 4 : 3, length: 3))
                if end < start {
                    view.moveWordRightAndModifySelection(nil)
                } else {
                    view.moveWordLeftAndModifySelection(nil)
                }
                XCTAssertEqual(
                    view.selectedRange(),
                    NSRange(location: end < start ? 7 : 3, length: end < start ? 0 : 1)
                )
            }
        }
    }

    func testNativeSelectionHandsOffToShiftClickAndBackToNative() throws {
        let (window, view, _) = try fixture(source: "one two three\nnext line", wysiwyg: true)
        view.textSelection = NSRange(location: 7, length: 0)
        view.moveWordLeftAndModifySelection(nil)
        try view.mouseDown(with: pointerEvent(view: view, window: window, offset: 5, modifiers: [.shift]))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 5, length: 2))
        XCTAssertEqual(view.textLayoutManager.textSelections.last?.affinity, .upstream)
        view.moveWordRightAndModifySelection(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 7, length: 0))
    }

    private func pointerEvent(
        view: MarkdownSTTextView, window: NSWindow, offset: Int,
        type: NSEvent.EventType = .leftMouseDown, modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        let rect = view.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: window.convertPoint(fromScreen: CGPoint(x: rect.minX, y: rect.midY)),
            modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        if type == .leftMouseDragged {
            let cgEvent = try XCTUnwrap(event.cgEvent)
            cgEvent.setIntegerValueField(.mouseEventDeltaX, value: 1)
            return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        }
        return event
    }

    func testOrdinaryArrowsCollapseSelectionWithoutAnExtraCharacterStep() throws {
        let (_, view, _) = try fixture(source: "abcdefg", wysiwyg: true)
        view.textSelection = NSRange(location: 2, length: 3)
        view.moveLeft(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))
        view.moveLeft(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
        view.textSelection = NSRange(location: 2, length: 3)
        view.moveRight(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 5, length: 0))
        view.moveRight(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 6, length: 0))
    }

    func testShiftReversalPreservesComposedCharacterBoundaries() throws {
        let source = "a🧪e\u{301}中文"
        let (_, view, _) = try fixture(source: source, wysiwyg: true)
        view.textSelection = NSRange(location: 1, length: 0)
        view.moveRightAndModifySelection(nil)
        view.moveRightAndModifySelection(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 4))
        view.moveLeftAndModifySelection(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 2))
        view.moveLeftAndModifySelection(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
        XCTAssertEqual(view.text, source)
    }

    func testDoubleAndTripleClicksRetainNativeWordAndParagraphSelection() throws {
        let source = "simple word\nnext paragraph\n"
        for wysiwyg in [false, true] {
            let (window, view, _) = try fixture(source: source, wysiwyg: wysiwyg)
            for (clickCount, expected) in [(2, NSRange(location: 0, length: 6)), (
                3,
                NSRange(location: 0, length: 12)
            )] {
                view.textSelection = NSRange(location: 0, length: 0)
                let rect = view.firstRect(forCharacterRange: NSRange(location: 2, length: 1), actualRange: nil)
                XCTAssertGreaterThan(rect.width, 0)
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: window.convertPoint(fromScreen: CGPoint(x: rect.midX, y: rect.midY)),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: clickCount, pressure: 1
                ))
                // Native click sequences establish the caret on the first mouse-down.
                let firstClick = try XCTUnwrap(NSEvent.mouseEvent(
                    with: .leftMouseDown, location: event.locationInWindow, modifierFlags: [],
                    timestamp: event.timestamp, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                ))
                view.mouseDown(with: firstClick)
                view.mouseDown(with: event)
                XCTAssertEqual(view.selectedRange(), expected, "wysiwyg=\(wysiwyg), count=\(clickCount)")
                view.moveLeftAndModifySelection(nil)
                XCTAssertEqual(view.selectedRange(), NSRange(location: expected.location, length: expected.length - 1))
                view.moveWordRightAndModifySelection(nil)
                let wordEnd = clickCount == 2 ? 6 : 16
                XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: wordEnd))
                XCTAssertEqual(view.text, source)
            }
        }
    }

    func testSynchronousDocumentInstallationAndNavigationUseTheNewLineIndex() throws {
        var source = "a\nb"
        var selection: NSRange? = NSRange(location: 0, length: 0)
        let textBinding = Binding(get: { source }, set: { source = $0 })
        let selectionBinding = Binding(get: { selection }, set: { selection = $0 })
        let proxy = EditorScrollProxy()
        let documentA = EditorDocumentIdentity(rawValue: "a")
        let documentB = EditorDocumentIdentity(rawValue: "b")
        let representable = MarkdownTextView(
            text: textBinding, styledText: nil, selection: selectionBinding,
            showsLineNumbers: false, documentIdentity: documentA, scrollProxy: proxy
        )
        let (_, view, scrollView) = try fixture(source: source, wysiwyg: false)
        let coordinator = representable.makeCoordinator()
        view.textDelegate = coordinator
        representable.updateRepresentedTextView(scrollView, coordinator: coordinator)
        // Prime the old index, then do not yield between source installation and navigation.
        proxy.emitVisibleLine(containingUTF16Offset: 2, in: view)
        var intents: [EditorScrollIntent] = []
        proxy.onScrollIntent = { intents.append($0) }
        source = "abcdefgh\nX\nY\nZ"
        let target = NSRange(location: 13, length: 1)
        let updated = MarkdownTextView(
            text: textBinding, styledText: nil, selection: selectionBinding,
            showsLineNumbers: false, documentIdentity: documentB,
            navigationCommand: .navigate(EditorNavigationRequest(
                id: 1,
                documentIdentity: documentB,
                selection: target
            )),
            scrollProxy: proxy
        )
        updated.updateRepresentedTextView(scrollView, coordinator: coordinator)
        XCTAssertEqual(view.selectedRange(), target)
        XCTAssertTrue(intents.contains(.navigation(line: 4, documentIdentity: documentB)), "\(intents)")
        XCTAssertFalse(intents.contains(.navigation(line: 2, documentIdentity: documentB)))
    }
}

private extension EditorInteractionRegressionTests {
    func fixture(source: String, wysiwyg: Bool) throws -> (NSWindow, MarkdownSTTextView, NSScrollView) {
        let frame = NSRect(x: 0, y: 0, width: 560, height: 180)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let view = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        view.isEditable = true
        view.isSelectable = true
        view.showsLineNumbers = false
        view.font = MarkdownSyntaxHighlighter.defaultFont
        view.text = source
        view.textSelection = NSRange(location: 0, length: 0)
        if wysiwyg { XCTAssertTrue(view.setWYSIWYGZeroWidthFoldingEnabled(true)) }
        let window = EditorFindControllerTestSupport.registerWindowForTeardown(NSWindow(
            contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false
        ))
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        view.textLayoutManager.ensureLayout(for: view.textLayoutManager.documentRange)
        return (window, view, scrollView)
    }
}
