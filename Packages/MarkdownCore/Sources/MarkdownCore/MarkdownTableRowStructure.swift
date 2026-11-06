import Foundation

/// One GFM pipe-table row: its unescaped pipes and its cells, in absolute UTF-16 offsets.
///
/// The table helper (`TableEditing`: Tab/Enter/Format Table) and Experimental WYSIWYG
/// table presentation both read cells through this type, so a cell selected by Tab is the
/// same range the editor presents as cell content (`docs/table-wysiwyg-gates.md` T1).
public struct MarkdownTableRowStructure: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable {
        case none
        case left
        case center
        case right
    }

    public struct Cell: Equatable, Sendable {
        /// Everything between the cell's boundaries (pipes or line edges).
        public let rawRange: NSRange
        /// The cell's content without surrounding spaces and tabs. A cell of only spaces keeps
        /// its first space as content, so the caret has a place to rest in an empty cell.
        public let contentRange: NSRange
        /// The raw cell text with surrounding whitespace trimmed.
        public let trimmedText: String

        public init(rawRange: NSRange, contentRange: NSRange, trimmedText: String) {
            self.rawRange = rawRange
            self.contentRange = contentRange
            self.trimmedText = trimmedText
        }

        /// Whether this cell is a delimiter-row cell such as `---`, `:--`, `:-:` or `--:`.
        public var isDelimiter: Bool {
            MarkdownTableRowStructure.isDelimiterCell(trimmedText)
        }

        public var alignment: Alignment {
            MarkdownTableRowStructure.alignment(ofDelimiterCell: trimmedText)
        }
    }

    /// The row's line, without its line terminator.
    public let lineRange: NSRange
    /// Offsets of the row's unescaped `|` characters, in ascending order.
    public let pipeOffsets: [Int]
    public let hasLeadingPipe: Bool
    public let hasTrailingPipe: Bool
    public let cells: [Cell]

    /// Parses `line` (without its terminator), which starts at `lineStart` in the document.
    /// Returns nil when the line has no unescaped pipe.
    public init?(line: String, lineStart: Int) {
        let storage = line as NSString
        let pipes = Self.unescapedPipePositions(in: storage)
        guard let firstPipe = pipes.first, let lastPipe = pipes.last else { return nil }

        // Outer pipes are optional. Virtual boundaries keep the edge cells and their
        // original UTF-16 source ranges when either pipe is omitted.
        var boundaries = pipes
        let leading = Self.isWhitespace(storage.substring(to: firstPipe))
        let trailing = Self.isWhitespace(storage.substring(from: lastPipe + 1))
        if !leading {
            boundaries.insert(-1, at: 0)
        }
        if !trailing {
            boundaries.append(storage.length)
        }
        guard boundaries.count >= 2 else { return nil }

        var cells: [Cell] = []
        cells.reserveCapacity(boundaries.count - 1)
        for index in 0 ..< boundaries.count - 1 {
            let start = boundaries[index] + 1
            let end = boundaries[index + 1]
            let rawRange = NSRange(location: start, length: max(0, end - start))
            let rawText = storage.substring(with: rawRange)
            let content = Self.trimmedContentRange(rawRange, in: storage)
            cells.append(Cell(
                rawRange: NSRange(location: rawRange.location + lineStart, length: rawRange.length),
                contentRange: NSRange(location: content.location + lineStart, length: content.length),
                trimmedText: MarkdownTextEditingSupport.trimSpaces(rawText)
            ))
        }

        lineRange = NSRange(location: lineStart, length: storage.length)
        pipeOffsets = pipes.map { $0 + lineStart }
        hasLeadingPipe = leading
        hasTrailingPipe = trailing
        self.cells = cells
    }

    /// Whether every cell is a delimiter cell, as in the row under a table's header.
    public var isDelimiterRow: Bool {
        !cells.isEmpty && cells.allSatisfy(\.isDelimiter)
    }

    static func isDelimiterCell(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("-") && trimmed.allSatisfy { character in
            character == "-" || character == ":" || character == " "
        }
    }

    static func alignment(ofDelimiterCell text: String) -> Alignment {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch (trimmed.hasPrefix(":"), trimmed.hasSuffix(":")) {
        case (true, true):
            return .center
        case (true, false):
            return .left
        case (false, true):
            return .right
        case (false, false):
            return .none
        }
    }

    private static func unescapedPipePositions(in storage: NSString) -> [Int] {
        var positions: [Int] = []
        var backslashCount = 0
        for index in 0 ..< storage.length {
            let unit = storage.character(at: index)
            if unit == 124, backslashCount.isMultiple(of: 2) {
                positions.append(index)
            }
            backslashCount = unit == 92 ? backslashCount + 1 : 0
        }
        return positions
    }

    private static func trimmedContentRange(_ range: NSRange, in storage: NSString) -> NSRange {
        var start = range.location
        var end = range.location + range.length
        while start < end, isSpace(storage.character(at: start)) {
            start += 1
        }
        while end > start, isSpace(storage.character(at: end - 1)) {
            end -= 1
        }
        if start == end, range.length > 0 {
            start = range.location
            end = range.location + 1
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func isWhitespace(_ string: String) -> Bool {
        string.allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 32 || unit == 9
    }
}
