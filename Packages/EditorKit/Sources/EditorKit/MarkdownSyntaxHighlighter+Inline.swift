import AppKit
import Foundation

extension MarkdownSyntaxHighlighter {
    func applyHeadings(
        in attributed: NSMutableAttributedString,
        text: NSString,
        excluding excludedRanges: [NSRange]
    ) {
        applyMatches(
            regex: MarkdownRegex.heading,
            in: text,
            excluding: excludedRanges
        ) { match in
            let markerRange = match.range(at: 1)
            let titleRange = match.range(at: 2)
            attributed.addAttribute(.foregroundColor, value: theme.mutedColor, range: markerRange)
            attributed.addAttribute(.font, value: boldFont(baseFont), range: markerRange)

            let level = min(max(markerRange.length, 1), 6)
            let size = baseFont.pointSize + CGFloat(7 - level)
            attributed.addAttributes(
                [
                    .font: NSFont.monospacedSystemFont(ofSize: size, weight: .bold),
                    .foregroundColor: theme.headingColor,
                ],
                range: titleRange
            )
        }
    }

    func applyListMarkers(
        in attributed: NSMutableAttributedString,
        text: NSString,
        excluding excludedRanges: [NSRange]
    ) {
        applyMatches(
            regex: MarkdownRegex.listMarker,
            in: text,
            excluding: excludedRanges
        ) { match in
            attributed.addAttributes(
                [
                    .foregroundColor: theme.listMarkerColor,
                    .font: boldFont(baseFont),
                ],
                range: match.range(at: 1)
            )
        }
    }

    func applyLinks(
        in attributed: NSMutableAttributedString,
        text: NSString,
        excluding excludedRanges: [NSRange]
    ) {
        applyMatches(
            regex: MarkdownRegex.link,
            in: text,
            excluding: excludedRanges
        ) { match in
            let linkAttributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: theme.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
            attributed.addAttributes(linkAttributes, range: match.range(at: 1))
            attributed.addAttributes([.foregroundColor: theme.mutedColor], range: match.range(at: 2))
        }
    }

    func applyBold(
        in attributed: NSMutableAttributedString,
        text: NSString,
        excluding excludedRanges: [NSRange]
    ) {
        applyMatches(
            regex: MarkdownRegex.bold,
            in: text,
            excluding: excludedRanges
        ) { match in
            let contentRange = match.firstValidRange(at: 1, 2)
            attributed.addAttribute(
                .font,
                value: boldFont(font(at: contentRange.location, in: attributed)),
                range: contentRange
            )
        }
    }

    func applyItalic(
        in attributed: NSMutableAttributedString,
        text: NSString,
        excluding excludedRanges: [NSRange]
    ) {
        applyMatches(
            regex: MarkdownRegex.italic,
            in: text,
            excluding: excludedRanges
        ) { match in
            let contentRange = match.firstValidRange(at: 1, 2)
            attributed.addAttribute(
                .font,
                value: italicFont(font(at: contentRange.location, in: attributed)),
                range: contentRange
            )
        }
    }

    func applyInlineCode(
        in attributed: NSMutableAttributedString,
        text: NSString,
        excluding excludedRanges: [NSRange]
    ) {
        applyMatches(
            regex: MarkdownRegex.inlineCode,
            in: text,
            excluding: excludedRanges
        ) { match in
            applyInlineCodeStyle(to: match.range(at: 1), in: attributed)
        }
    }

    func applyMDXSourceLines(
        in attributed: NSMutableAttributedString,
        text: NSString,
        excluding excludedRanges: [NSRange]
    ) {
        applyMatches(
            regex: MarkdownRegex.mdxImportExport,
            in: text,
            excluding: excludedRanges
        ) { match in
            attributed.addAttributes(
                [
                    .font: baseFont,
                    .foregroundColor: theme.codeColor,
                    .backgroundColor: theme.codeBackgroundColor,
                ],
                range: match.range
            )
        }

        applyMatches(
            regex: MarkdownRegex.mdxComponentOpen,
            in: text,
            excluding: excludedRanges
        ) { match in
            attributed.addAttributes(
                [
                    .font: baseFont,
                    .foregroundColor: theme.codeColor,
                ],
                range: match.range
            )
        }
    }

    func applyInlineCodeStyle(to range: NSRange, in attributed: NSMutableAttributedString) {
        attributed.addAttributes(
            [
                .font: baseFont,
                .foregroundColor: theme.codeColor,
                .backgroundColor: theme.codeBackgroundColor,
            ],
            range: range
        )
    }
}
