import AppKit
import Foundation

extension MarkdownSyntaxHighlighter {
    func applyFrontmatter(
        in attributed: NSMutableAttributedString,
        text: NSString
    ) -> [NSRange] {
        guard
            let match = MarkdownRegex.frontmatter.firstMatch(
                in: text as String,
                range: NSRange(location: 0, length: text.length)
            )
        else {
            return []
        }

        let range = match.range
        attributed.addAttributes(
            [
                .foregroundColor: theme.frontmatterColor,
                .backgroundColor: theme.frontmatterBackgroundColor,
                .font: baseFont,
            ],
            range: range
        )
        return [range]
    }

    func applyFencedCodeBlocks(
        in attributed: NSMutableAttributedString,
        text: NSString
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = 0
        var openFence: Fence?

        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let line = text.substring(with: lineRange)

            if let fence = openFence {
                if isClosingFence(line, for: fence) {
                    let blockRange = NSRange(
                        location: fence.range.location,
                        length: NSMaxRange(lineRange) - fence.range.location
                    )
                    applyCodeBlockStyle(to: blockRange, in: attributed)
                    ranges.append(blockRange)
                    openFence = nil
                }
            } else if let fence = openingFence(in: line, lineRange: lineRange) {
                openFence = fence
                if fence.languageRange.length > 0 {
                    attributed.addAttributes(
                        [
                            .foregroundColor: theme.codeColor,
                            .font: boldFont(baseFont),
                        ],
                        range: fence.languageRange
                    )
                }
            }

            location = NSMaxRange(lineRange)
        }

        if let fence = openFence {
            let blockRange = NSRange(location: fence.range.location, length: text.length - fence.range.location)
            applyCodeBlockStyle(to: blockRange, in: attributed)
            ranges.append(blockRange)
        }

        return ranges
    }

    func applyCodeBlockStyle(to range: NSRange, in attributed: NSMutableAttributedString) {
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
