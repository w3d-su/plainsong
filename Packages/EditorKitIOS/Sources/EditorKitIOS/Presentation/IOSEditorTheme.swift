import SyntaxKit
import UIKit

@MainActor
public struct IOSEditorTheme: Equatable {
    public let identifier: String
    public let background: UIColor
    public let baseFont: UIFont
    public let baseColor: UIColor

    public init(identifier: String, background: UIColor, baseFont: UIFont, baseColor: UIColor) {
        self.identifier = identifier
        self.background = background
        self.baseFont = baseFont
        self.baseColor = baseColor
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
}
