import AppKit

extension MarkdownSyntaxHighlighter {
    func font(at location: Int, in attributed: NSAttributedString) -> NSFont {
        attributed.attribute(.font, at: location, effectiveRange: nil) as? NSFont ?? baseFont
    }

    /// Font derivation goes through NSFontDescriptor, not NSFontManager:
    /// the highlighter runs on a background task and NSFontManager is not
    /// documented as thread-safe.
    ///
    /// The system monospaced face resolves bold through the weighted system API instead
    /// of descriptor traits: trait-merged descriptors on that private face do not reliably
    /// cascade bold to CJK fallback fonts (PingFang), which left Chinese `**strong**` text
    /// visually regular while ASCII appeared bold. A font chosen in Settings keeps its own
    /// family when that family has a bold face; one without (Monaco) falls back to the
    /// system bold so emphasis stays visible.
    func boldFont(_ font: NSFont, size: CGFloat? = nil) -> NSFont {
        let size = size ?? font.pointSize
        let isItalic = font.fontDescriptor.symbolicTraits.contains(.italic)
        if let familyBold = Self.familyBoldFont(for: font, size: size, italic: isItalic) {
            return familyBold
        }
        var bold = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        if isItalic {
            bold = fontByAddingTraits(.italic, to: bold)
        }
        return bold
    }

    private static func familyBoldFont(for font: NSFont, size: CGFloat, italic: Bool) -> NSFont? {
        // System faces have private, dot-prefixed names.
        guard !font.fontName.hasPrefix("."), let family = font.familyName else {
            return nil
        }
        var traits: NSFontDescriptor.SymbolicTraits = [.bold]
        if italic {
            traits.insert(.italic)
        }
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family]).withSymbolicTraits(traits)
        guard let candidate = NSFont(descriptor: descriptor, size: size),
              candidate.familyName == family,
              candidate.fontDescriptor.symbolicTraits.contains(.bold)
        else {
            return nil
        }
        return candidate
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
