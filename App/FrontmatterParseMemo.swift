import Foundation
import MarkdownCore

/// Reuses the inspector's frontmatter parse while only the document body changes.
///
/// `Frontmatter.parse` runs Yams over the block and copies the text after it, so calling it
/// from `body` on every change was O(document) plus a YAML parse per keystroke. The parse
/// result depends only on `determiningPrefix(of:)`; an unchanged prefix keeps the result.
@MainActor
final class FrontmatterParseMemo {
    private var prefix: String?
    private(set) var result = FrontmatterParseResult(block: nil)
    /// Number of `Frontmatter.parse` calls made (tests).
    private(set) var parseCount = 0

    /// Returns `true` when the result changed.
    @discardableResult
    func update(text: String) -> Bool {
        let determiningPrefix = Self.determiningPrefix(of: text)
        if let prefix, ExactSourceText.matches(prefix, determiningPrefix) {
            return false
        }
        prefix = determiningPrefix
        parseCount += 1
        let newResult = Frontmatter.parse(determiningPrefix)
        guard newResult != result else { return false }
        result = newResult
        return true
    }

    /// The shortest-safe prefix of `text` whose `Frontmatter.parse` equals that of `text`.
    ///
    /// - No opening `---` line: the empty string (no frontmatter).
    /// - An opening `---` line ended by LF or CRLF and a later `---` line ended by LF or CRLF:
    ///   the text through that closing `---`, without its line ending. The parser splits lines
    ///   on CR as well, so it can only close earlier, which is still inside this prefix.
    /// - Anything else (an unclosed block, a lone-CR opening): the whole text.
    nonisolated static func determiningPrefix(of text: String) -> String {
        let utf8 = text.utf8
        let dash = UInt8(ascii: "-")
        let lineFeed = UInt8(ascii: "\n")
        let carriageReturn = UInt8(ascii: "\r")

        guard utf8.starts(with: [dash, dash, dash]) else { return "" }
        var index = utf8.index(utf8.startIndex, offsetBy: 3)
        guard index < utf8.endIndex else { return text }
        switch utf8[index] {
        case lineFeed:
            break
        case carriageReturn:
            index = utf8.index(after: index)
            guard index < utf8.endIndex, utf8[index] == lineFeed else { return text }
        default:
            // `----…` or `---x`: not an opening delimiter line.
            return ""
        }

        var lineStart = utf8.index(after: index)
        while lineStart < utf8.endIndex {
            let lineEnd = utf8[lineStart...].firstIndex(of: lineFeed) ?? utf8.endIndex
            var contentEnd = lineEnd
            if contentEnd > lineStart, utf8[utf8.index(before: contentEnd)] == carriageReturn {
                contentEnd = utf8.index(before: contentEnd)
            }
            if lineEnd < utf8.endIndex,
               utf8[lineStart ..< contentEnd].elementsEqual([dash, dash, dash])
            {
                return String(text[..<contentEnd])
            }
            guard lineEnd < utf8.endIndex else { break }
            lineStart = utf8.index(after: lineEnd)
        }
        return text
    }
}
