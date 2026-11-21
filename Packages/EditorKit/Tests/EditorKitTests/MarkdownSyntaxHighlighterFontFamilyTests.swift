import AppKit
@testable import EditorKit
import XCTest

/// A font chosen in Settings must stay the font of emphasized text too.
final class MarkdownSyntaxHighlighterFontFamilyTests: XCTestCase {
    private let source = "# Title\n\nplain **strong** text\n\n- item\n"

    func testChosenFamilyWithABoldFaceIsKeptForHeadingsAndStrongText() throws {
        let menlo = try XCTUnwrap(NSFont(name: "Menlo", size: 13), "Menlo ships with macOS")
        let highlighted = highlight(with: menlo)

        for needle in ["#", "Title", "strong"] {
            let font = try font(of: needle, in: highlighted)
            XCTAssertEqual(font.familyName, "Menlo", "\(needle) left the chosen family")
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold), "\(needle) must be bold")
        }
        XCTAssertEqual(try font(of: "Title", in: highlighted).pointSize, 19)
        XCTAssertEqual(try font(of: "plain", in: highlighted).familyName, "Menlo")
    }

    func testFamilyWithoutABoldFaceFallsBackToAVisibleBold() throws {
        let monaco = try XCTUnwrap(NSFont(name: "Monaco", size: 13), "Monaco ships with macOS")
        let strong = try font(of: "strong", in: highlight(with: monaco))

        XCTAssertTrue(strong.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testSystemMonospacedBoldStillUsesTheWeightedSystemFont() throws {
        let strong = try font(of: "strong", in: highlight(with: MarkdownSyntaxHighlighter.defaultFont))

        XCTAssertEqual(strong, NSFont.monospacedSystemFont(ofSize: 13, weight: .bold))
    }

    private func highlight(with font: NSFont) -> NSAttributedString {
        NSAttributedString(MarkdownSyntaxHighlighter(baseFont: font).highlight(source, fileKind: .markdown))
    }

    private func font(of needle: String, in attributed: NSAttributedString) throws -> NSFont {
        let range = (attributed.string as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound)
        return try XCTUnwrap(attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
    }
}
