import AppKit
import Foundation

extension MarkdownSyntaxHighlighter {
    func applyMatches(
        regex: NSRegularExpression,
        in text: NSString,
        excluding excludedRanges: [NSRange],
        body: (NSTextCheckingResult) -> Void
    ) {
        let fullRange = NSRange(location: 0, length: text.length)
        regex.enumerateMatches(in: text as String, range: fullRange) { match, _, _ in
            guard
                let match,
                !excludedRanges.contains(where: { $0.intersects(match.range) })
            else {
                return
            }

            body(match)
        }
    }

    func openingFence(in line: String, lineRange: NSRange) -> Fence? {
        let nsLine = line as NSString
        let matchRange = NSRange(location: 0, length: nsLine.length)
        guard let match = MarkdownRegex.openingFence.firstMatch(in: line, range: matchRange) else {
            return nil
        }

        let markerRange = match.range(at: 1)
        let marker = nsLine.substring(with: markerRange)
        let languageRange = match.range(at: 2)
        let resolvedLanguageRange = languageRange.location == NSNotFound
            ? NSRange(location: lineRange.location, length: 0)
            : NSRange(location: lineRange.location + languageRange.location, length: languageRange.length)

        return Fence(
            markerCharacter: marker.first.map(String.init) ?? "`",
            markerLength: marker.count,
            range: lineRange,
            languageRange: resolvedLanguageRange
        )
    }

    func isClosingFence(_ line: String, for fence: Fence) -> Bool {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLine.hasPrefix(String(repeating: fence.markerCharacter, count: fence.markerLength)) else {
            return false
        }

        return trimmedLine.allSatisfy { String($0) == fence.markerCharacter }
    }

    func font(at location: Int, in attributed: NSAttributedString) -> NSFont {
        attributed.attribute(.font, at: location, effectiveRange: nil) as? NSFont ?? baseFont
    }

    func boldFont(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    func italicFont(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }
}

enum MarkdownRegex {
    static let frontmatter = make(#"(?s)\A---[ \t]*\r?\n.*?\r?\n---[ \t]*(?=\r?\n|\z)"#)
    static let openingFence = make(#"^[ \t]{0,3}(`{3,}|~{3,})[ \t]*([A-Za-z0-9_+.#-]+)?"#)
    static let heading = make(#"(?m)^(#{1,6})[ \t]+(.+?)\s*$"#)
    static let listMarker = make(#"(?m)^([ \t]*(?:[-+*][ \t]+\[[ xX]\]|\d+[.)]|[-+*]))[ \t]+"#)
    static let link = make(#"\[([^\]\r\n]+)\]\(([^\)\r\n]+)\)"#)
    static let bold = make(#"(?<!\*)\*\*([^\*\r\n]+)\*\*(?!\*)|(?<!_)__([^_\r\n]+)__(?!_)"#)
    static let italic = make(#"(?<!\*)\*([^\*\r\n]+)\*(?!\*)|(?<!_)_([^_\r\n]+)_(?!_)"#)
    static let inlineCode = make(#"`([^`\r\n]+)`"#)
    static let mdxImportExport = make(#"(?m)^[ \t]*(?:import|export)\b.*$"#)
    static let mdxComponentOpen = make(#"(?m)^[ \t]*<[A-Z][^\r\n>]*(?:/>|>)"#)

    private static func make(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("Invalid markdown regex pattern: \(pattern)")
        }
    }
}

struct Fence {
    var markerCharacter: String
    var markerLength: Int
    var range: NSRange
    var languageRange: NSRange
}

extension NSTextCheckingResult {
    func firstValidRange(at indexes: Int...) -> NSRange {
        for index in indexes {
            let range = range(at: index)
            if range.location != NSNotFound {
                return range
            }
        }
        return range
    }
}

extension NSRange {
    func intersects(_ other: NSRange) -> Bool {
        NSIntersectionRange(self, other).length > 0
    }
}
