import AppKit

extension MarkdownSyntaxHighlighter {
    func font(at location: Int, in attributed: NSAttributedString) -> NSFont {
        attributed.attribute(.font, at: location, effectiveRange: nil) as? NSFont ?? baseFont
    }

    /// Font derivation goes through NSFontDescriptor, not NSFontManager:
    /// the highlighter runs on a background task and NSFontManager is not
    /// documented as thread-safe.
    ///
    /// Bold resolves through the weighted system API instead of descriptor traits:
    /// trait-merged descriptors on the private system monospaced face do not
    /// reliably cascade bold to CJK fallback fonts (PingFang), which left Chinese
    /// `**strong**` text visually regular while ASCII appeared bold. All editor
    /// fonts are currently the monospaced system family; revisit if custom editor
    /// fonts ship (agent.md §11).
    func boldFont(_ font: NSFont) -> NSFont {
        var bold = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
        if font.fontDescriptor.symbolicTraits.contains(.italic) {
            bold = fontByAddingTraits(.italic, to: bold)
        }
        return bold
    }

    func italicFont(_ font: NSFont) -> NSFont {
        fontByAddingTraits(.italic, to: font)
    }

    private func fontByAddingTraits(_ traits: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let mergedTraits = font.fontDescriptor.symbolicTraits.union(traits)
        let descriptor = font.fontDescriptor.withSymbolicTraits(mergedTraits)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}
