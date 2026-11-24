@testable import EditorKitIOS
import UIKit
import XCTest

@MainActor
final class IOSLineNumberCompositionTests: XCTestCase {
    /// Changing the text container inset relays out the text and resets the input
    /// session, so a gutter width change waits for the composition to end.
    func testGutterWidthChangeWaitsForMarkedText() {
        let harness = IOSEditorHarness(text: "hello")
        harness.placeCaret(at: 5)
        let inset = harness.textView.textContainerInset.left
        XCTAssertGreaterThan(harness.textView.lineNumberGutterWidth, 0)
        harness.textView.setMarkedText("ㄓ", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(harness.textView.markedTextRange)
        let composing = harness.textView.textStorage.string

        harness.controller.showsLineNumbers = false
        XCTAssertNotNil(harness.textView.markedTextRange)
        XCTAssertEqual(harness.textView.textStorage.string, composing)
        XCTAssertEqual(harness.textView.textContainerInset.left, inset)

        harness.textView.unmarkText()
        XCTAssertEqual(harness.textView.lineNumberGutterWidth, 0)
        XCTAssertLessThan(harness.textView.textContainerInset.left, inset)
    }
}
