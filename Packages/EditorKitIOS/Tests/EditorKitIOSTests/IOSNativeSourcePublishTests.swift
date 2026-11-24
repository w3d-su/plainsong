@testable import EditorKitIOS
import MarkdownCore
import UIKit
import XCTest

/// agent.md §12: the editor publishes native UTF-8 source, never the bridged
/// `NSTextStorage` string, so downstream `==` and `ExactSourceText` stay on the byte path.
@MainActor
final class IOSNativeSourcePublishTests: XCTestCase {
    func testTypingPublishesNativeUTF8Text() {
        let harness = IOSEditorHarness(text: "")
        harness.textView.insertText("繁體輸入 😀")
        XCTAssertEqual(harness.session.text, "繁體輸入 😀")
        XCTAssertTrue(isNative(harness.session.text))
        XCTAssertNotNil(ExactSourceText.nativeUTF8Matches(harness.session.text, "繁體輸入 😀"))
    }

    func testAuthorizedEditPublishesNativeUTF8Text() throws {
        let harness = IOSEditorHarness(text: "alpha")
        let bold = MarkdownEditResult(
            replacementRange: NSRange(location: 0, length: 5),
            replacementString: "**alpha**",
            newSelection: NSRange(location: 9, length: 0)
        )
        guard case .applied = try harness.controller.apply(harness.edit(bold, name: "Bold")) else {
            return XCTFail("edit was refused")
        }
        XCTAssertEqual(harness.session.text, "**alpha**")
        XCTAssertTrue(isNative(harness.session.text))
    }

    /// A lone surrogate has no exact native form; the published text keeps it.
    func testUnpairedSurrogateIsPublishedExactly() {
        let harness = IOSEditorHarness(text: "")
        let lone = String(utf16CodeUnits: [0x61, 0xD83D], count: 2)
        harness.controller.isReconciling = true
        harness.textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: lone)
        harness.controller.isReconciling = false
        harness.controller.publishCurrentText()
        XCTAssertEqual((harness.session.text as NSString).length, 2)
        XCTAssertEqual((harness.session.text as NSString).character(at: 1), 0xD83D)
    }

    private func isNative(_ text: String) -> Bool {
        text.utf8.withContiguousStorageIfAvailable { _ in true } ?? false
    }
}
