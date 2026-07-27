import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// Proves the F0 spike's responder-chain delivery path (sendAction → focused editor).
/// Synthetic events are **not** F0 evidence; owner physical keyboard under ABC/Zhuyin is.
@MainActor
final class EditorFindSpikeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        EditorFindSpike.reset()
    }

    override func tearDown() {
        EditorFindSpike.reset()
        super.tearDown()
    }

    func testShowFindSelectorRecordsFireOnFocusedEditor() throws {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let scrollView = MarkdownSTTextView.scrollableTextView(frame: frame)
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownSTTextView)
        textView.text = "spike"
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(textView))
        XCTAssertTrue(window.firstResponder === textView)

        XCTAssertEqual(EditorFindSpike.fireCount, 0)
        // Direct selector delivery (same method the responder chain invokes).
        textView.plainsongShowFind(nil)
        XCTAssertEqual(EditorFindSpike.fireCount, 1)
        XCTAssertNotNil(EditorFindSpike.lastFireDate)

        // sendAction with explicit target (menu path uses to: nil in production;
        // unit tests without a full NSApp activation may not walk the key window).
        XCTAssertTrue(
            NSApp.sendAction(#selector(STTextView.plainsongShowFind(_:)), to: textView, from: nil)
        )
        XCTAssertEqual(EditorFindSpike.fireCount, 2)
    }

    func testShowFindNoOpsWithoutFocusedEditorResponder() {
        XCTAssertEqual(EditorFindSpike.fireCount, 0)
        // No first-responder editor: sendAction(to: nil) finds no target; count stays 0.
        _ = NSApp.sendAction(#selector(STTextView.plainsongShowFind(_:)), to: nil, from: nil)
        XCTAssertEqual(EditorFindSpike.fireCount, 0)
    }
}
