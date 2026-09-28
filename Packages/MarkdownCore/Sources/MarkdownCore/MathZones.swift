import Foundation

/// Line-scanned regions where `$`/`$$` are formulas versus where they would not
/// parse as math at all. Math zones keep their editable inner range; frontmatter,
/// non-math fences, indented code, inline code, HTML tags, and MDX expressions
/// are exclusion zones. HTML/JSX container zones additionally disable
/// display-math insertion anywhere inside them, even across blank lines.
struct MathDelimiterSpec: Hashable {
    var marker: UInt16
    var width: Int
}

struct MathDelimiterHorizon {
    /// Absolute UTF-16 offset of the first search that failed.
    var coveredFrom: Int
    /// Absolute offset where that search stopped. Later starts in
    /// `[coveredFrom, stop)` fail for the same delimiter without rescanning.
    var stop: Int
}

struct MathZones {
    let text: String
    /// Markdown HTML tags stay ASCII. JSX identifiers and fragments are MDX-only.
    let fileKind: FileKind
    /// Inline spans (code, tags, expressions): a caret at the span end is
    /// already outside, so end-exclusive containment applies.
    var excludedZones: [NSRange] = []
    /// Block regions (fences, indented code, frontmatter, `.md` HTML blocks,
    /// spans flushed unclosed to EOF): the closing line is part of the region,
    /// so a caret at the region end still counts as inside.
    var excludedBlockZones: [NSRange] = []
    var mathZones: [(outer: NSRange, inner: NSRange, endInclusive: Bool)] = []
    var containerZones: [NSRange] = []
    var containerStack: [(name: String, openLocation: Int)] = []
    /// Scratch for one scan. Unclosed `$` / backtick runs are literal, and a
    /// failed look-ahead covers the rest of that paragraph for the same run.
    var delimiterHorizons: [MathDelimiterSpec: MathDelimiterHorizon] = [:]

    init(text: String, fileKind: FileKind) {
        self.text = text
        self.fileKind = fileKind
        scan(fileKind: fileKind)
    }

    func editableMathInnerRange(containing selection: NSRange) -> NSRange? {
        for zone in mathZones where contains(zone.outer, selection, endInclusive: zone.endInclusive) {
            return zone.inner
        }
        return nil
    }

    /// True where math delimiters would not parse as math (code, frontmatter,
    /// MDX expressions, tag interiors) or the selection only partially overlaps
    /// an existing formula.
    func blocksMathCommand(_ selection: NSRange) -> Bool {
        for zone in mathZones
            where intersects(zone.outer, selection)
            && !contains(zone.outer, selection, endInclusive: zone.endInclusive)
        {
            return true
        }
        for zone in excludedZones where intersects(zone, selection) || zone.location == selection.location {
            return true
        }
        for zone in excludedBlockZones where coversCaretOrIntersects(zone, selection) {
            return true
        }
        return false
    }

    /// Display math additionally refuses lists, quotes, tables, and HTML/JSX
    /// containers — anywhere inside them, including blank-separated
    /// continuations. Hand-written math there still previews; only automatic
    /// insertion is limited to plain top-level paragraphs and blank lines.
    func blocksDisplayMathCommand(_ selection: NSRange) -> Bool {
        if blocksMathCommand(selection) { return true }
        for zone in containerZones where coversCaretOrIntersects(zone, selection) {
            return true
        }
        return !isPlainTopLevelParagraph(selection)
    }

    /// Block zones are closed regions: a caret at the zone end is still on the
    /// closing delimiter line (or inside an unclosed zone at EOF). Inline zones
    /// keep half-open containment instead so a caret right after the closing
    /// character stays editable.
    private func coversCaretOrIntersects(_ zone: NSRange, _ selection: NSRange) -> Bool {
        if selection.length == 0 {
            return zone.location <= selection.location && selection.location <= NSMaxRange(zone)
        }
        return intersects(zone, selection)
    }

    /// A caret counts as inside [start, end) — or [start, end] for block zones
    /// whose closing delimiter still owns the line end; a non-empty selection
    /// must be fully contained.
    func contains(_ outer: NSRange, _ inner: NSRange, endInclusive: Bool = false) -> Bool {
        if inner.length == 0 {
            if endInclusive {
                return outer.location <= inner.location && inner.location <= NSMaxRange(outer)
            }
            return outer.location <= inner.location && inner.location < NSMaxRange(outer)
        }
        return outer.location <= inner.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    func intersects(_ first: NSRange, _ second: NSRange) -> Bool {
        first.location < NSMaxRange(second) && second.location < NSMaxRange(first)
    }

    private func isPlainTopLevelParagraph(_ selection: NSRange) -> Bool {
        guard let bounds = paragraphBounds(overlapping: selection) else { return false }
        return !paragraphContainsContainerSyntax(bounds) && !isListContinuation(startingAt: bounds.first)
    }

    /// The touched paragraphs: the maximal non-blank run around both selection
    /// ends, so a caret mid-paragraph checks the whole paragraph.
    private func paragraphBounds(overlapping selection: NSRange) -> (first: MarkdownLine, last: MarkdownLine)? {
        guard var firstLine = MarkdownTextEditingSupport.lines(overlapping: selection, in: text).first,
              var lastLine = MarkdownTextEditingSupport.lines(overlapping: selection, in: text).last
        else { return nil }

        while firstLine.range.location > 0 {
            let previous = MarkdownTextEditingSupport.line(containing: firstLine.range.location - 1, in: text)
            guard !MarkdownTextEditingSupport.isBlank(previous.text) else { break }
            // A setext underline or an ATX heading ends that heading. The
            // following paragraph is not the same block, even though no blank
            // line separates them.
            if isSetextUnderline(previous) || isATXHeading(previous) { break }
            firstLine = previous
        }
        while lastLine.fullEndLocation < (text as NSString).length {
            let next = MarkdownTextEditingSupport.line(containing: lastLine.fullEndLocation, in: text)
            guard !MarkdownTextEditingSupport.isBlank(next.text) else { break }
            // An ATX heading interrupts the paragraph above it.
            if isATXHeading(next) { break }
            lastLine = next
        }
        return (firstLine, lastLine)
    }

    /// Container syntax plus headings: an ATX heading line, or a setext
    /// underline that turns the paragraph above it into a heading, is not a
    /// plain paragraph and must not be split by a `$$` block.
    private func paragraphContainsContainerSyntax(_ bounds: (first: MarkdownLine, last: MarkdownLine)) -> Bool {
        var hasTableSeparator = false
        var previousText: String?
        var cursor = bounds.first.range.location
        while cursor <= bounds.last.range.location {
            let line = MarkdownTextEditingSupport.line(containing: cursor, in: text)
            let trimmed = Self.trimMarkdownWhitespace(line.text)
            defer { previousText = line.text }
            if !trimmed.isEmpty {
                if MarkdownListItem(line.text) != nil { return true }
                if trimmed.hasPrefix(">") { return true }
                if tagToken(in: line) != nil { return true }
                if isATXHeading(line) { return true }
                if line.range.location > bounds.first.range.location, isSetextUnderline(line) { return true }
                if leadingWhitespaceColumns(in: line.text) <= 3,
                   Self.isTableDelimiterRow(trimmed, header: previousText)
                {
                    hasTableSeparator = true
                }
            }
            let next = line.fullEndLocation
            if next <= cursor { break }
            cursor = next
        }
        return hasTableSeparator
    }

    /// A blank-separated paragraph can still be a list-item continuation: an
    /// indented paragraph whose nearest non-blank line above is a list item is
    /// inside that item.
    private func isListContinuation(startingAt firstLine: MarkdownLine) -> Bool {
        var probe = firstLine.range.location
        while probe > 0 {
            let previous = MarkdownTextEditingSupport.line(containing: probe - 1, in: text)
            guard MarkdownTextEditingSupport.isBlank(previous.text) else { break }
            probe = previous.range.location
        }
        guard probe > 0 else { return false }
        let above = MarkdownTextEditingSupport.line(containing: probe - 1, in: text)
        return MarkdownListItem(above.text) != nil &&
            leadingWhitespaceColumns(in: firstLine.text) >= 2
    }

    /// Tab stops are every 4 columns, matching indented-code and list continuation.
    private func leadingWhitespaceColumns(in line: String) -> Int {
        let storage = line as NSString
        var index = 0
        var column = 0
        while index < storage.length {
            let unit = storage.character(at: index)
            if unit == 32 {
                index += 1
                column += 1
            } else if unit == 9 {
                column += 4 - (column % 4)
                index += 1
            } else {
                break
            }
        }
        return column
    }

    /// `-` / `=` underline immediately after a non-blank line. Indent of 4 or
    /// more is paragraph content, not a heading.
    private func isSetextUnderline(_ line: MarkdownLine) -> Bool {
        let storage = line.text as NSString
        var index = 0
        var column = 0
        while index < storage.length {
            let unit = storage.character(at: index)
            if unit == 32 {
                column += 1
                index += 1
            } else if unit == 9 {
                column += 4 - (column % 4)
                index += 1
            } else {
                break
            }
        }
        guard column <= 3, index < storage.length else { return false }
        // One unbroken `=`/`-` run with only trailing whitespace; `= =` is text.
        let run = Self.trimMarkdownWhitespace(storage.substring(from: index))
        guard let marker = run.first, marker == "-" || marker == "=",
              run.allSatisfy({ $0 == marker })
        else { return false }
        guard line.range.location > 0 else { return false }
        let before = MarkdownTextEditingSupport.line(containing: line.range.location - 1, in: text)
        return !MarkdownTextEditingSupport.isBlank(before.text)
    }

    /// `#`–`######` heading opener with at most three columns of indent; four
    /// or more is paragraph continuation or indented code, not a heading.
    private func isATXHeading(_ line: MarkdownLine) -> Bool {
        guard leadingWhitespaceColumns(in: line.text) <= 3 else { return false }
        let trimmed = Self.trimMarkdownWhitespace(line.text)
        return trimmed.first == "#" && isHeading(trimmed)
    }

    /// Markdown block syntax only treats ASCII space and tab as whitespace;
    /// NBSP or EM SPACE beside a marker makes the line ordinary text. The shared
    /// `trimSpaces` helper trims all Unicode whitespace, so it is not used here.
    static func trimMarkdownWhitespace(_ string: String) -> String {
        let scalars = string.unicodeScalars
        let isMarkdownSpace: (Unicode.Scalar) -> Bool = { $0 == " " || $0 == "\t" }
        guard let start = scalars.firstIndex(where: { !isMarkdownSpace($0) }),
              let end = scalars.lastIndex(where: { !isMarkdownSpace($0) })
        else { return "" }
        return String(scalars[start ... end])
    }
}
