import AppKit
@testable import BlogEditor
import XCTest

@MainActor
final class EditorScrollBridgeTests: XCTestCase {
    func testTextViewFinderSkipsNonEditableGutterTextViews() {
        let root = NSView()
        let gutterTextView = NSTextView()
        gutterTextView.isEditable = false
        gutterTextView.isSelectable = true
        let gutterScrollView = NSScrollView()
        gutterScrollView.documentView = gutterTextView

        let editorTextView = NSTextView()
        editorTextView.isEditable = true
        let editorScrollView = NSScrollView()
        editorScrollView.documentView = editorTextView

        root.addSubview(gutterScrollView)
        root.addSubview(editorScrollView)

        XCTAssertTrue(EditorScrollTextViewFinder.findTextView(in: root) === editorTextView)
    }
}
