import Foundation
import MarkdownCore

/// One GFM pipe table found by tree-sitter in the WYSIWYG parse range, with the decision
/// whether Experimental WYSIWYG may present it (`docs/table-wysiwyg-gates.md` §1, T1).
///
/// Cell boundaries come from MarkdownCore `MarkdownTableRowStructure`, the definition the
/// table helper (`TableEditing`) uses, so a presented cell is exactly the range Tab selects.
/// A raw table carries no rows: nothing about it is presented.
public struct WYSIWYGTableRegion: Equatable, Sendable {
    /// Why a table stays raw text. The checks run in this order and the first one wins.
    public enum RawReason: Equatable, Sendable {
        /// Inside a block quote or list item.
        case nested
        /// More than `maximumRowCount` rows, `maximumColumnCount` columns or
        /// `maximumSourceLength` UTF-16 units of source.
        case overCaps
        /// The parse range was cut at its expansion cap where the table starts or ends, so
        /// the table may continue outside it.
        case truncated
        /// The source contains U+0009, which would jump a presentation tab stop.
        case containsTab
        /// A row the tree-sitter grammar reports has no unescaped pipe, or its pipes are not
        /// the ones `MarkdownTableRowStructure` finds.
        case structureMismatch
        /// Rows disagree on having a leading pipe.
        case inconsistentLeadingPipe
        /// A row has more cells than the header; GFM drops the extra cells, and hiding them
        /// would hide source text.
        case extraCells
        /// No leading pipe and a centered or right-aligned first column: no character can
        /// carry the tab in front of the first cell.
        case unanchoredFirstColumn
    }

    /// Where the grammar found the table relative to the document and the parse range.
    public enum Placement: Equatable, Sendable {
        /// At top level, and wholly inside the parse range.
        case complete
        /// Inside a block quote or list item.
        case nested
        /// At top level, starting or ending at a cut of the parse range.
        case truncated
    }

    public static let maximumRowCount = 500
    public static let maximumColumnCount = 32
    public static let maximumSourceLength = 32 * 1024

    /// From the first row's line start to the last row's end, without the last terminator.
    public let sourceRange: NSRange
    /// Header, delimiter row, then body rows, in document order. Empty when raw.
    public let rows: [MarkdownTableRowStructure]
    /// One per column, from the delimiter row. Empty when raw.
    public let alignments: [MarkdownTableRowStructure.Alignment]
    public let rawReason: RawReason?

    public init(
        sourceRange: NSRange,
        rows: [MarkdownTableRowStructure],
        alignments: [MarkdownTableRowStructure.Alignment],
        rawReason: RawReason?
    ) {
        self.sourceRange = sourceRange
        self.rows = rows
        self.alignments = alignments
        self.rawReason = rawReason
    }

    public static func raw(_ reason: RawReason, sourceRange: NSRange) -> WYSIWYGTableRegion {
        WYSIWYGTableRegion(sourceRange: sourceRange, rows: [], alignments: [], rawReason: reason)
    }

    public var isEligible: Bool {
        rawReason == nil
    }

    public var columnCount: Int {
        alignments.count
    }

    /// Everything in a row's line that is not cell content: leading spaces, pipes, cell
    /// padding and a trailing pipe. The delimiter row is structure throughout.
    public func structuralRanges(ofRow index: Int) -> [NSRange] {
        let row = rows[index]
        guard index != 1 else { return row.lineRange.length > 0 ? [row.lineRange] : [] }
        var ranges: [NSRange] = []
        var cursor = row.lineRange.location
        for cell in row.cells {
            if cell.contentRange.location > cursor {
                ranges.append(NSRange(location: cursor, length: cell.contentRange.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(cell.contentRange))
        }
        if NSMaxRange(row.lineRange) > cursor {
            ranges.append(NSRange(location: cursor, length: NSMaxRange(row.lineRange) - cursor))
        }
        return ranges
    }

    /// Decides every §1 rule except the width check, which needs the editor's fonts.
    /// `rows` are the grammar's rows in order, nil where a line has no unescaped pipe;
    /// `parsedPipeOffsets` holds, per row, the absolute offsets of the grammar's `|` nodes.
    static func make(
        sourceRange: NSRange,
        sourceText: String,
        rows parsedRows: [MarkdownTableRowStructure?],
        parsedPipeOffsets: [[Int]],
        placement: Placement
    ) -> WYSIWYGTableRegion {
        if placement == .nested {
            return .raw(.nested, sourceRange: sourceRange)
        }
        if parsedRows.count > maximumRowCount || sourceRange.length > maximumSourceLength {
            return .raw(.overCaps, sourceRange: sourceRange)
        }
        if placement == .truncated {
            return .raw(.truncated, sourceRange: sourceRange)
        }
        if sourceText.utf16.contains(0x0009) {
            return .raw(.containsTab, sourceRange: sourceRange)
        }
        let rows = parsedRows.compactMap { $0 }
        guard rows.count >= 2,
              rows.count == parsedRows.count,
              parsedPipeOffsets.count == rows.count,
              zip(rows, parsedPipeOffsets).allSatisfy({ $0.pipeOffsets == $1 }),
              rows[1].isDelimiterRow,
              rows[1].cells.count == rows[0].cells.count
        else {
            return .raw(.structureMismatch, sourceRange: sourceRange)
        }
        let header = rows[0]
        guard header.cells.count <= maximumColumnCount else {
            return .raw(.overCaps, sourceRange: sourceRange)
        }
        if rows.contains(where: { $0.hasLeadingPipe != header.hasLeadingPipe }) {
            return .raw(.inconsistentLeadingPipe, sourceRange: sourceRange)
        }
        if rows.contains(where: { $0.cells.count > header.cells.count }) {
            return .raw(.extraCells, sourceRange: sourceRange)
        }
        let alignments = rows[1].cells.map(\.alignment)
        if !header.hasLeadingPipe, alignments[0] == .center || alignments[0] == .right {
            return .raw(.unanchoredFirstColumn, sourceRange: sourceRange)
        }
        return WYSIWYGTableRegion(sourceRange: sourceRange, rows: rows, alignments: alignments, rawReason: nil)
    }
}
