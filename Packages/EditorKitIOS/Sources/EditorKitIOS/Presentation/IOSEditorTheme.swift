import SyntaxKit
import UIKit

public struct IOSEditorTheme: Equatable {
    public enum Palette: String, CaseIterable, Identifiable, Equatable {
        case plainsong
        case graphite

        public var id: String {
            rawValue
        }
    }

    public let identifier: String
    public let background: UIColor
    public let baseFont: UIFont
    public let baseColor: UIColor
    public let palette: Palette

    public init(
        identifier: String,
        background: UIColor,
        baseFont: UIFont,
        baseColor: UIColor,
        palette: Palette = .plainsong
    ) {
        self.identifier = identifier
        self.background = background
        self.baseFont = baseFont
        self.baseColor = baseColor
        self.palette = palette
    }

    func gutterColor(current: Bool) -> UIColor {
        if current { return baseColor }
        return palette == .graphite ? .tertiaryLabel : .secondaryLabel
    }

    var gutterBandColor: UIColor {
        .quaternarySystemFill
    }

    public static let light = IOSEditorTheme(
        identifier: "default-light",
        background: .systemBackground,
        baseFont: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        baseColor: .label
    )

    public static let dark = IOSEditorTheme(
        identifier: "default-dark",
        background: .black,
        baseFont: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        baseColor: .white
    )

    func color(for kind: MarkdownSyntaxToken.Kind) -> UIColor {
        switch palette {
        case .plainsong:
            plainsongColor(for: kind)
        case .graphite:
            graphiteColor(for: kind)
        }
    }

    private func plainsongColor(for kind: MarkdownSyntaxToken.Kind) -> UIColor {
        switch kind {
        case .headingMarker, .headingText:
            .systemBlue
        case .strong:
            baseColor
        case .emphasis:
            .secondaryLabel
        case .inlineCode, .codeBlock, .codeFenceMarker, .codeFenceInfo:
            .systemOrange
        case .linkText, .linkDestination:
            .systemBlue
        case .listMarker, .quoteMarker:
            .systemIndigo
        case .frontmatter, .frontmatterKey:
            .systemPurple
        default:
            baseColor
        }
    }

    /// Quieter than Plainsong: accent headings, indigo code, brown frontmatter.
    private func graphiteColor(for kind: MarkdownSyntaxToken.Kind) -> UIColor {
        switch kind {
        case .headingMarker, .headingText:
            .tintColor
        case .strong:
            baseColor
        case .emphasis:
            .secondaryLabel
        case .inlineCode, .codeBlock, .codeFenceMarker, .codeFenceInfo:
            .systemIndigo
        case .linkText, .linkDestination:
            .link
        case .listMarker, .quoteMarker:
            .systemGray
        case .frontmatter, .frontmatterKey:
            .systemBrown
        default:
            baseColor
        }
    }

    func font(for kind: MarkdownSyntaxToken.Kind) -> UIFont {
        switch kind {
        case .headingText, .headingMarker, .strong:
            font(traits: .traitBold)
        case .emphasis:
            font(traits: .traitItalic)
        case .inlineCode, .codeBlock, .codeFenceMarker, .codeFenceInfo, .mdxSource:
            baseFont
        default:
            baseFont
        }
    }

    private func font(traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits) else {
            return baseFont
        }
        return UIFont(descriptor: descriptor, size: baseFont.pointSize)
    }

    /// Source colors at a user-chosen face, size, and palette. 13 pt system
    /// Plainsong keeps the shared light and dark themes.
    public static func reading(
        appearance: UIUserInterfaceStyle,
        pointSize: CGFloat,
        fontName: String = IOSEditorFont.system,
        palette: Palette = .plainsong
    ) -> IOSEditorTheme {
        let size = min(24, max(10, pointSize.rounded()))
        let font = IOSEditorFont.font(named: fontName, size: size)
        if abs(size - 13) < 0.5, palette == .plainsong, IOSEditorFont.isSystem(fontName) {
            return appearance == .dark ? .dark : .light
        }
        let dark = appearance == .dark
        let paletteName = palette == .graphite ? "graphite" : "default"
        return IOSEditorTheme(
            identifier: "\(paletteName)-\(dark ? "dark" : "light")-\(Int(size))-\(IOSEditorFont.resolved(fontName))",
            background: dark ? .black : .systemBackground,
            baseFont: font,
            baseColor: dark ? .white : .label,
            palette: palette
        )
    }
}
