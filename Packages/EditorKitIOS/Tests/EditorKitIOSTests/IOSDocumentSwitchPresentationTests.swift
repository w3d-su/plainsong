@testable import EditorKitIOS
import MarkdownCore
import SyntaxKit
import UIKit
import XCTest

@MainActor
final class IOSDocumentSwitchPresentationTests: XCTestCase {
    /// `replaceCharacters(in:with:)` gives the new text the attributes of the first
    /// replaced character, so a heading at offset 0 used to restyle the whole next file.
    func testNextDocumentDoesNotInheritTheFirstCharacterSyntaxStyle() {
        let first = "# Heading\nbody"
        let harness = IOSEditorHarness(text: first)
        let covered = NSRange(location: 0, length: iosUTF16("# Heading"))
        XCTAssertTrue(IOSHighlightPresenter.apply(
            tokens: [MarkdownSyntaxToken(kind: .headingText(level: 1), range: covered)],
            coveredRange: covered,
            expectedFragment: "# Heading",
            theme: harness.controller.theme,
            to: harness.textView
        ))
        XCTAssertNotNil(harness.syntaxToken(at: 0))
        harness.placeCaret(at: 4)

        let next = String(repeating: "plain paragraph\n", count: 400)
        harness.controller.attach(IOSSourceEditorDocumentBinding(
            bindingID: UUID(),
            identity: IOSDocumentIdentity(rawValue: UUID()),
            session: DocumentSession(text: next, isDirty: false),
            accessGeneration: 1,
            canWrite: true
        ))

        let storage = harness.textView.textStorage
        XCTAssertEqual(storage.string, next)
        XCTAssertEqual(harness.textView.selectedRange, NSRange(location: 0, length: 0))
        var owned = 0
        storage.enumerateAttribute(
            IOSSyntaxAttribute.key,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            if value != nil {
                owned += range.length
            }
        }
        XCTAssertEqual(owned, 0)
        let base = harness.controller.theme.baseFont
        for offset in [0, storage.length / 2, storage.length - 1] {
            XCTAssertEqual(storage.attribute(.font, at: offset, effectiveRange: nil) as? UIFont, base)
        }
    }

    /// Before the first layout TextKit has no viewport. The fallback must not ask the
    /// tokenizer for, and then repaint, a whole 1 MB document.
    func testViewportBeforeLayoutIsBounded() {
        let controller = IOSSourceEditorController(syntaxTokenizer: nil, theme: .light)
        let text = String(repeating: "0123456789abcde\n", count: 4096)
        controller.attach(IOSSourceEditorDocumentBinding(
            bindingID: UUID(),
            identity: IOSDocumentIdentity(rawValue: UUID()),
            session: DocumentSession(text: text, isDirty: false),
            accessGeneration: 1,
            canWrite: true
        ))
        let range = IOSViewport.visibleUTF16Range(in: controller.textView)
        XCTAssertEqual(range.location, 0)
        XCTAssertLessThanOrEqual(range.length, IOSViewport.unlaidOutFallbackLength)
        XCTAssertGreaterThan(range.length, 0)
    }

    func testBoundedFallbackDoesNotSplitASurrogatePair() {
        let source = String(repeating: "a", count: 7) + "😀" + String(repeating: "b", count: 20)
        XCTAssertEqual(IOSViewport.fallbackRange(in: source as NSString, limit: 8), NSRange(location: 0, length: 7))
        XCTAssertEqual(IOSViewport.fallbackRange(in: source as NSString, limit: 9), NSRange(location: 0, length: 9))
        XCTAssertEqual(IOSViewport.fallbackRange(in: "abc", limit: 8), NSRange(location: 0, length: 3))
    }
}
