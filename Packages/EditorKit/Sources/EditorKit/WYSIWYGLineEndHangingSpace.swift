import AppKit
import CoreText

/// Keeps line-end folds measurable in the WYSIWYG paragraph projection.
///
/// TextKit 2 places a U+200B (and every other zero-width format character tried: U+2060,
/// U+200C, U+FEFF) that ends a line at x = 0, so the segment frame of the content before a
/// folded closing delimiter or an image collapses, and selection, caret and IME rects land
/// at the line start. A trailing space hangs past the line end instead and keeps every
/// offset in place. TextKit measures a range ending in trailing whitespace from the
/// whitespace's unkerned advance, so the space gets a near-zero font as well as a kern that
/// cancels what remains (`docs/decisions/2026-11-06-wysiwyg-line-end-fold-hanging-space.md`).
enum WYSIWYGLineEndHangingSpace {
    /// Point size of the hanging space: its advance is about 0.0006 em, under 0.01 pt.
    static let fontSize: CGFloat = 0.01

    /// Replaces the last unit of each projected run that ends a line in `paragraph` with a
    /// hanging space. Only projected U+200B units change; one UTF-16 unit becomes one, so
    /// the paragraph keeps every raw offset. `projectedRanges` are paragraph-relative.
    static func apply(to paragraph: NSMutableAttributedString, projectedRanges: [NSRange]) {
        guard !projectedRanges.isEmpty else { return }
        let string = paragraph.mutableString
        let length = string.length
        var hangingOffsets: Set<Int> = []
        for range in projectedRanges where range.length > 0 {
            let end = NSMaxRange(range)
            guard end <= length,
                  end == length || isLineTerminator(string.character(at: end)),
                  string.character(at: end - 1) == zeroWidthSpace
            else {
                continue
            }
            hangingOffsets.insert(end - 1)
        }

        for offset in hangingOffsets {
            let unit = NSRange(location: offset, length: 1)
            let font = paragraph.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
                ?? MarkdownSyntaxHighlighter.defaultFont
            let hangingFont = NSFont(descriptor: font.fontDescriptor, size: fontSize) ?? font
            string.replaceCharacters(in: unit, with: " ")
            paragraph.addAttributes(
                [.font: hangingFont, .kern: -spaceAdvance(of: hangingFont)],
                range: unit
            )
        }
    }

    private static let zeroWidthSpace: unichar = 0x200B

    /// The terminators `NSString.paragraphRange(for:)` and TextKit line layout break on.
    private static func isLineTerminator(_ unit: unichar) -> Bool {
        switch unit {
        case 0x000A, 0x000D, 0x0085, 0x2028, 0x2029:
            true
        default:
            false
        }
    }

    private static func spaceAdvance(of font: NSFont) -> CGFloat {
        var character: UniChar = 0x0020
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else {
            return 0
        }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return advance.width
    }
}
