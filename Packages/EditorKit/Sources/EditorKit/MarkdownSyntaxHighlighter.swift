import AppKit
import Foundation
import MarkdownCore

/// Parser-backed source styling for Markdown and MDX source mode.
///
/// This remains a facade: callers depend on String + FileKind -> AttributedString,
/// while tree-sitter parsing and theme mapping stay local to EditorKit.
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
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: baseFont,
                .foregroundColor: theme.textColor,
            ]
        )

        guard let parser = try? MarkdownSyntaxParser() else {
            return AttributedString(attributed)
        }

        for token in parser.tokens(in: text, fileKind: fileKind) {
            apply(token, to: attributed)
        }

        return AttributedString(attributed)
    }
}

private extension MarkdownSyntaxHighlighter {
    func apply(_ token: MarkdownSyntaxToken, to attributed: NSMutableAttributedString) {
        guard NSMaxRange(token.range) <= attributed.length else {
            return
        }

        if applyBlockToken(token, to: attributed) {
            return
        }

        if applyInlineToken(token, to: attributed) {
            return
        }

        applyMDXToken(token, to: attributed)
    }

    func applyBlockToken(_ token: MarkdownSyntaxToken, to attributed: NSMutableAttributedString) -> Bool {
        if applyMetadataToken(token, to: attributed) {
            return true
        }

        if applyHeadingToken(token, to: attributed) {
            return true
        }

        if applyCodeBlockToken(token, to: attributed) {
            return true
        }

        if token.kind == .listMarker {
            attributed.addAttributes(
                [
                    .foregroundColor: theme.listMarkerColor,
                    .font: boldFont(baseFont),
                ],
                range: token.range
            )
            return true
        }

        if applyTableToken(token, to: attributed) {
            return true
        }

        return false
    }

    func applyTableToken(_ token: MarkdownSyntaxToken, to attributed: NSMutableAttributedString) -> Bool {
        switch token.kind {
        case .tableHeader:
            attributed.addAttribute(.font, value: boldFont(baseFont), range: token.range)
            return true

        case .tableDelimiter, .tablePipe:
            attributed.addAttribute(.foregroundColor, value: theme.mutedColor, range: token.range)
            return true

        default:
            return false
        }
    }

    func applyMetadataToken(_ token: MarkdownSyntaxToken, to attributed: NSMutableAttributedString) -> Bool {
        switch token.kind {
        case .frontmatter:
            attributed.addAttributes(
                [
                    .foregroundColor: theme.frontmatterColor,
                    .backgroundColor: theme.frontmatterBackgroundColor,
                    .font: baseFont,
                ],
                range: token.range
            )
            return true

        case .frontmatterKey:
            attributed.addAttributes(
                [
                    .foregroundColor: theme.frontmatterColor,
                    .font: boldFont(baseFont),
                ],
                range: token.range
            )
            return true

        default:
            return false
        }
    }

    func applyHeadingToken(_ token: MarkdownSyntaxToken, to attributed: NSMutableAttributedString) -> Bool {
        switch token.kind {
        case .headingMarker:
            attributed.addAttributes(
                [
                    .foregroundColor: theme.mutedColor,
                    .font: boldFont(baseFont),
                ],
                range: token.range
            )
            return true

        case let .headingText(level):
            let size = baseFont.pointSize + CGFloat(7 - min(max(level, 1), 6))
            attributed.addAttributes(
                [
                    .font: NSFont.monospacedSystemFont(ofSize: size, weight: .bold),
                    .foregroundColor: theme.headingColor,
                ],
                range: token.range
            )
            return true

        default:
            return false
        }
    }

    func applyCodeBlockToken(_ token: MarkdownSyntaxToken, to attributed: NSMutableAttributedString) -> Bool {
        switch token.kind {
        case .codeBlock:
            attributed.addAttributes(
                [
                    .font: baseFont,
                    .foregroundColor: theme.codeColor,
                    .backgroundColor: theme.codeBackgroundColor,
                ],
                range: token.range
            )
            return true

        case .codeFenceMarker:
            attributed.addAttributes(
                [
                    .foregroundColor: theme.mutedColor,
                    .font: baseFont,
                ],
                range: token.range
            )
            return true

        case .codeFenceInfo:
            attributed.addAttributes(
                [
                    .foregroundColor: theme.codeColor,
                    .font: boldFont(baseFont),
                ],
                range: token.range
            )
            return true

        default:
            return false
        }
    }

    func applyInlineToken(_ token: MarkdownSyntaxToken, to attributed: NSMutableAttributedString) -> Bool {
        switch token.kind {
        case .inlineCode:
            attributed.addAttributes(
                [
                    .font: baseFont,
                    .foregroundColor: theme.codeColor,
                    .backgroundColor: theme.codeBackgroundColor,
                ],
                range: token.range
            )
            return true

        case .strong:
            attributed.addAttribute(
                .font,
                value: boldFont(font(at: token.range.location, in: attributed)),
                range: token.range
            )
            return true

        case .emphasis:
            attributed.addAttribute(
                .font,
                value: italicFont(font(at: token.range.location, in: attributed)),
                range: token.range
            )
            return true

        case .linkText:
            attributed.addAttributes(
                [
                    .foregroundColor: theme.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ],
                range: token.range
            )
            return true

        case .linkDestination:
            attributed.addAttribute(.foregroundColor, value: theme.mutedColor, range: token.range)
            return true

        default:
            return false
        }
    }

    func applyMDXToken(_ token: MarkdownSyntaxToken, to attributed: NSMutableAttributedString) {
        switch token.kind {
        case .mdxSource:
            attributed.addAttributes(
                [
                    .font: baseFont,
                    .foregroundColor: theme.codeColor,
                    .backgroundColor: theme.codeBackgroundColor,
                ],
                range: token.range
            )
        default:
            return
        }
    }
}
