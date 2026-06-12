import AppKit
import Foundation
import MarkdownCore

/// Lightweight source styling for M1.
///
/// This is intentionally a facade: callers depend on String + FileKind -> AttributedString,
/// so a Neon/tree-sitter implementation can replace the scanner without changing App code.
public struct MarkdownSyntaxHighlighter {
    public static var defaultFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    let theme: MarkdownSyntaxTheme
    let baseFont: NSFont

    public init(
        theme: MarkdownSyntaxTheme = .standard,
        baseFont: NSFont = MarkdownSyntaxHighlighter.defaultFont
    ) {
        self.theme = theme
        self.baseFont = baseFont
    }

    public func highlight(_ text: String, fileKind: FileKind) -> AttributedString {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: baseFont,
                .foregroundColor: theme.textColor,
            ]
        )

        guard fullRange.length > 0 else {
            return AttributedString(attributed)
        }

        let frontmatterRanges = applyFrontmatter(in: attributed, text: nsText)
        let fencedCodeRanges = applyFencedCodeBlocks(in: attributed, text: nsText)
        let excludedRanges = frontmatterRanges + fencedCodeRanges

        if fileKind == .mdx {
            applyMDXSourceLines(in: attributed, text: nsText, excluding: excludedRanges)
        }

        applyHeadings(in: attributed, text: nsText, excluding: excludedRanges)
        applyListMarkers(in: attributed, text: nsText, excluding: excludedRanges)
        applyLinks(in: attributed, text: nsText, excluding: excludedRanges)
        applyBold(in: attributed, text: nsText, excluding: excludedRanges)
        applyItalic(in: attributed, text: nsText, excluding: excludedRanges)
        applyInlineCode(in: attributed, text: nsText, excluding: excludedRanges)

        return AttributedString(attributed)
    }
}
