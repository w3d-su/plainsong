import AppKit
@testable import EditorKit
import STTextView
import XCTest

/// Real WYSIWYG clicks on the second and later visual lines of a wrapped paragraph: a line
/// with a folded link, a line with folded bold, and the line of an image thumbnail. Each
/// click must place the caret at the clicked character on that line.
@MainActor
final class WYSIWYGWrappedLinePointerTests: XCTestCase {
    private static let filler = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda "
        + "mu nu xi omicron pi rho "
    private static let source = "# Wrapped\n\n"
        + filler + "see [the folded link](./target.md) "
        + filler + "and **bold words** "
        + filler + "then ![thumb](./image.png) end.\n\nNext paragraph.\n"

    func testClicksOnWrappedVisualLinesLandOnTheClickedCharacter() throws {
        let source = Self.source
        let storage = source as NSString
        let editor = try WYSIWYGPointerClickTestSupport.makeEditor(source, size: NSSize(width: 640, height: 360))
        defer { editor.window.close() }
        try WYSIWYGPointerClickTestSupport.scroll(editor, toFraction: 0, source: source)
        let image = storage.range(of: "![thumb](./image.png)")
        WYSIWYGPointerClickTestSupport.placeImageThumbnails(
            editor,
            in: storage.paragraphRange(for: image),
            source: source
        )

        let link = storage.range(of: "folded link")
        let bold = storage.range(of: "bold words")
        let targets: [(name: String, offset: Int)] = [
            ("folded link", link.location + 3),
            ("bold", bold.location + 2),
            ("thumbnail line", image.location - 3),
            ("first line", storage.range(of: "gamma").location + 1),
        ]
        let imageLine = try visualLine(containing: image.location, in: editor.textView)
        XCTAssertGreaterThanOrEqual(imageLine, 2)
        XCTAssertEqual(try visualLine(containing: image.location - 3, in: editor.textView), imageLine)
        XCTAssertGreaterThanOrEqual(try visualLine(containing: link.location, in: editor.textView), 1)
        XCTAssertGreaterThanOrEqual(try visualLine(containing: bold.location, in: editor.textView), 2)

        for target in targets {
            let point = try XCTUnwrap(
                WYSIWYGPointerClickTestSupport.visiblePoint(ofCharacterAt: target.offset, in: editor),
                target.name
            )
            let caret = try WYSIWYGPointerClickTestSupport.click(at: point, in: editor)
            // The midpoint of a character resolves to the caret before or after it.
            XCTAssertTrue(
                (target.offset ... target.offset + 1).contains(caret),
                "\(target.name): clicked \(target.offset), caret \(caret)"
            )
        }
    }

    /// The zero-based visual line of the paragraph's layout fragment that holds `offset`.
    private func visualLine(containing offset: Int, in textView: STTextView) throws -> Int {
        let contentManager = textView.textContentManager
        let location = try XCTUnwrap(contentManager.location(contentManager.documentRange.location, offsetBy: offset))
        var result: Int?
        textView.textLayoutManager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
            let start = contentManager.offset(
                from: contentManager.documentRange.location,
                to: fragment.rangeInElement.location
            )
            result = fragment.textLineFragments.firstIndex { line in
                NSLocationInRange(offset - start, line.characterRange)
            }
            return false
        }
        return try XCTUnwrap(result, "no visual line holds \(offset)")
    }
}
