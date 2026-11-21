import AppKit
@testable import EditorKit
import XCTest

@MainActor
final class EditorSelectionColorObserverLifecycleTests: XCTestCase {
    func testCustomSelectionColorIsObservedAgainAfterReturningToAWindow() throws {
        let frame = NSRect(x: 0, y: 0, width: 320, height: 160)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.text = "selection color"
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        window.contentView = scrollView
        textView.editorSelectionColor = .systemOrange
        XCTAssertNotNil(textView.editorSelectionColorObserver)

        // A tab or split change detaches the editor and attaches the same view again.
        window.contentView = NSView(frame: frame)
        XCTAssertNil(textView.window)
        XCTAssertNil(textView.editorSelectionColorObserver, "a detached editor must not keep its observer")

        window.contentView = scrollView
        XCTAssertNotNil(textView.window)
        XCTAssertNotNil(
            textView.editorSelectionColorObserver,
            "the custom selection color must keep repainting after the editor returns to a window"
        )
        XCTAssertTrue(textView.enforcesCustomSelectionColor)
    }
}
