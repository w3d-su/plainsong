import Foundation
import MarkdownCore
import SwiftTreeSitter

/// The WYSIWYG parse range grown to whole tables (`docs/table-wysiwyg-gates.md` T1).
public struct WYSIWYGTableParseRange: Equatable, Sendable {
    public let range: NSRange
    /// Where the range was cut at the expansion cap instead of at a blank line or the
    /// document edge: the start offset of the range, and the end of its last line's content.
    /// A table that starts or ends at a cut may continue past it, so it stays raw.
    public let leadingCut: Int?
    public let trailingCut: Int?

    public init(range: NSRange, leadingCut: Int? = nil, trailingCut: Int? = nil) {
        self.range = range
        self.leadingCut = leadingCut
        self.trailingCut = trailingCut
    }
}

public extension MarkdownSyntaxParser {
    /// Grows a line-aligned visible highlight range so a table it starts or ends inside is
    /// parsed whole: column widths depend on every row, so scrolling must never change which
    /// rows a parse sees.
    ///
    /// An edge line that is not blank lies in a block of non-blank lines. When that block
    /// holds a delimiter-shaped line (only spaces, tabs, `|`, `:` and `-`, with at least one
    /// `|` and one `-`), the range grows to the block's edge on that side. Each scan stops
    /// after `WYSIWYGTableRegion.maximumSourceLength` UTF-16 units away from the edge line;
    /// a table larger than that is over the caps and stays raw anyway. Fence and frontmatter
    /// context is restored afterwards, so the range never starts inside fenced code.
    static func tableParseRange(in source: String, expanding range: NSRange) -> WYSIWYGTableParseRange {
        let text = source as NSString
        guard range.length > 0, NSMaxRange(range) <= text.length else {
            return WYSIWYGTableParseRange(range: range)
        }
        let lines = MarkdownTableLineScanner(text: text)
        var start = range.location
        var end = NSMaxRange(range)
        var leadingCut: Int?
        var trailingCut: Int?

        let firstLine = lines.lineStart(containing: range.location)
        if let block = lines.tableBlock(containing: firstLine) {
            if block.start < start {
                start = block.start
            }
            leadingCut = block.startIsCut ? block.start : nil
        }
        let lastLine = lines.lineStart(containing: NSMaxRange(range) - 1)
        if let block = lines.tableBlock(containing: lastLine) {
            let blockEnd = lines.nextLineStart(afterContentsEnd: block.contentsEnd)
            if blockEnd > end {
                end = blockEnd
            }
            trailingCut = block.endIsCut ? block.contentsEnd : nil
        }

        let grown = NSRange(location: start, length: end - start)
        guard grown != range else {
            return WYSIWYGTableParseRange(range: range, leadingCut: leadingCut, trailingCut: trailingCut)
        }
        let context = MarkdownFenceScanner.contextRange(in: source, expanding: grown).clamped(toLength: text.length)
        return WYSIWYGTableParseRange(
            range: context,
            leadingCut: leadingCut == context.location ? leadingCut : nil,
            trailingCut: trailingCut.flatMap { cut in
                lines.nextLineStart(afterContentsEnd: cut) == NSMaxRange(context) ? cut : nil
            }
        )
    }
}

extension MarkdownSyntaxParser {
    /// Collects every `pipe_table` under `node` as a region in document coordinates.
    func appendTableRegions(
        from node: Node,
        fragment: NSString,
        parseRange: WYSIWYGTableParseRange,
        isNested: Bool = false,
        to regions: inout [WYSIWYGTableRegion]
    ) {
        switch node.nodeType {
        case "pipe_table":
            regions.append(tableRegion(from: node, fragment: fragment, parseRange: parseRange, isNested: isNested))
            return
        case "paragraph", "inline", "fenced_code_block", "indented_code_block", "minus_metadata", "plus_metadata",
             "html_block":
            return
        default:
            break
        }
        let childIsNested = isNested || !(node.nodeType == "document" || node.nodeType == "section")
        for index in 0 ..< node.childCount {
            guard let child = node.child(at: index) else { continue }
            appendTableRegions(
                from: child,
                fragment: fragment,
                parseRange: parseRange,
                isNested: childIsNested,
                to: &regions
            )
        }
    }

    private func tableRegion(
        from table: Node,
        fragment: NSString,
        parseRange: WYSIWYGTableParseRange,
        isNested: Bool
    ) -> WYSIWYGTableRegion {
        let base = parseRange.range.location
        let lines = MarkdownTableLineScanner(text: fragment)
        var rows: [MarkdownTableRowStructure?] = []
        var pipeOffsets: [[Int]] = []
        var firstLineStart: Int?
        var lastContentsEnd = 0
        for index in 0 ..< table.childCount {
            guard let row = table.child(at: index),
                  ["pipe_table_header", "pipe_table_delimiter_row", "pipe_table_row"].contains(row.nodeType)
            else {
                continue
            }
            let lineStart = lines.lineStart(containing: nsRange(for: row).location)
            let contentsEnd = lines.contentsEnd(ofLineStartingAt: lineStart)
            firstLineStart = firstLineStart ?? lineStart
            lastContentsEnd = contentsEnd
            let line = fragment.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
            rows.append(MarkdownTableRowStructure(line: line, lineStart: base + lineStart))
            pipeOffsets.append((0 ..< row.childCount).compactMap { pipeIndex in
                guard let pipe = row.child(at: pipeIndex), pipe.nodeType == "|" else { return nil }
                return nsRange(for: pipe, offset: base).location
            })
        }

        let localStart = firstLineStart ?? nsRange(for: table).location
        let sourceRange = NSRange(location: base + localStart, length: max(0, lastContentsEnd - localStart))
        return WYSIWYGTableRegion.make(
            sourceRange: sourceRange,
            sourceText: fragment.substring(with: NSRange(location: localStart, length: sourceRange.length)),
            rows: rows,
            parsedPipeOffsets: pipeOffsets,
            placement: placement(of: sourceRange, in: parseRange, isNested: isNested)
        )
    }

    private func placement(
        of sourceRange: NSRange,
        in parseRange: WYSIWYGTableParseRange,
        isNested: Bool
    ) -> WYSIWYGTableRegion.Placement {
        if isNested {
            return .nested
        }
        if sourceRange.location == parseRange.leadingCut || NSMaxRange(sourceRange) == parseRange.trailingCut {
            return .truncated
        }
        return .complete
    }
}

/// Line arithmetic over UTF-16 text where only `\n`, `\r` and `\r\n` end a line, as in the
/// tree-sitter Markdown grammar (`NSString.lineRange` also breaks at U+2028 and U+0085).
struct MarkdownTableLineScanner {
    struct Block {
        let start: Int
        let contentsEnd: Int
        let startIsCut: Bool
        let endIsCut: Bool
    }

    let text: NSString

    func lineStart(containing offset: Int) -> Int {
        var index = min(max(offset, 0), text.length)
        while index > 0 {
            let unit = text.character(at: index - 1)
            if unit == 10 || unit == 13 {
                break
            }
            index -= 1
        }
        return index
    }

    func contentsEnd(ofLineStartingAt start: Int) -> Int {
        var index = start
        while index < text.length {
            let unit = text.character(at: index)
            if unit == 10 || unit == 13 {
                break
            }
            index += 1
        }
        return index
    }

    func nextLineStart(afterContentsEnd end: Int) -> Int {
        guard end < text.length else { return end }
        if text.character(at: end) == 13, end + 1 < text.length, text.character(at: end + 1) == 10 {
            return end + 2
        }
        return end + 1
    }

    func previousLineStart(before start: Int) -> Int? {
        guard start > 0 else { return nil }
        var terminatorStart = start - 1
        if text.character(at: terminatorStart) == 10, terminatorStart > 0,
           text.character(at: terminatorStart - 1) == 13
        {
            terminatorStart -= 1
        }
        return lineStart(containing: terminatorStart)
    }

    /// The block of non-blank lines around the line starting at `lineStart`, when that line
    /// is not blank and the block holds a delimiter-shaped line; each direction stops after
    /// `WYSIWYGTableRegion.maximumSourceLength` units away from that line.
    func tableBlock(containing lineStart: Int) -> Block? {
        let limit = WYSIWYGTableRegion.maximumSourceLength
        let edgeEnd = contentsEnd(ofLineStartingAt: lineStart)
        guard !isBlank(lineStart, edgeEnd) else { return nil }
        var hasDelimiter = isDelimiterShaped(lineStart, edgeEnd)

        var start = lineStart
        var startIsCut = false
        while let previous = previousLineStart(before: start) {
            let previousEnd = contentsEnd(ofLineStartingAt: previous)
            guard !isBlank(previous, previousEnd) else { break }
            guard lineStart - previous <= limit else {
                startIsCut = true
                break
            }
            hasDelimiter = hasDelimiter || isDelimiterShaped(previous, previousEnd)
            start = previous
        }

        var end = edgeEnd
        var endIsCut = false
        while end < text.length {
            let next = nextLineStart(afterContentsEnd: end)
            guard next < text.length else { break }
            let nextEnd = contentsEnd(ofLineStartingAt: next)
            guard !isBlank(next, nextEnd) else { break }
            guard nextEnd - edgeEnd <= limit else {
                endIsCut = true
                break
            }
            hasDelimiter = hasDelimiter || isDelimiterShaped(next, nextEnd)
            end = nextEnd
        }
        return hasDelimiter ? Block(start: start, contentsEnd: end, startIsCut: startIsCut, endIsCut: endIsCut) : nil
    }

    private func isBlank(_ start: Int, _ end: Int) -> Bool {
        (start ..< end).allSatisfy { index in
            let unit = text.character(at: index)
            return unit == 32 || unit == 9
        }
    }

    private func isDelimiterShaped(_ start: Int, _ end: Int) -> Bool {
        var hasPipe = false
        var hasDash = false
        for index in start ..< end {
            switch text.character(at: index) {
            case 124: hasPipe = true
            case 45: hasDash = true
            case 32, 9, 58: continue
            default: return false
            }
        }
        return hasPipe && hasDash
    }
}
