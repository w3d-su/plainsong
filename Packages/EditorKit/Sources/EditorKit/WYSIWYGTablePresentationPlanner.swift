import AppKit
import CoreText
import MarkdownCore

/// Builds the row markers for one table: measures every column across every row, places tab
/// stops, and decides eligibility (`docs/table-wysiwyg-gates.md` §1, T2). A nil result
/// leaves the table raw.
@MainActor
enum WYSIWYGTablePresentationPlanner {
    /// Space on each side of a cell's content, in points.
    static let cellPadding: CGFloat = 8

    /// What a table is laid out against: the editor's font, paragraph style and line width.
    struct Context {
        let baseFont: NSFont
        let baseParagraphStyle: NSParagraphStyle
        let availableWidth: CGFloat
        let generation: UInt64
    }

    /// The table's column geometry, shared by every row.
    struct Columns {
        let widths: [CGFloat]
        let contentLefts: [CGFloat]
        let alignments: [MarkdownTableRowStructure.Alignment]
        let hasLeadingPipe: Bool
        /// Line width the table needs, without the hanging trailing space.
        let totalWidth: CGFloat
    }

    /// `rows` are the header, the delimiter row, then body rows, in document order.
    static func markers(
        rows: [MarkdownTableRowStructure],
        in text: NSAttributedString,
        context: Context
    ) -> [WYSIWYGTableRowPresentationMarker]? {
        guard isEligible(rows, in: text.string as NSString) else { return nil }

        // Measure every cell once; the delimiter row has no content.
        let cellWidths: [[CGFloat]] = rows.enumerated().map { rowIndex, row in
            rowIndex == 1 ? [] : row.cells.map { cell in
                presentedWidth(of: cell.contentRange, in: text, baseFont: context.baseFont, isHeader: rowIndex == 0)
            }
        }
        let columns = columns(rows: rows, cellWidths: cellWidths, baseFont: context.baseFont)
        guard columns.totalWidth <= context.availableWidth else { return nil }
        let collapsedStyle = collapsedRowStyle(base: context.baseParagraphStyle, font: context.baseFont)

        return rows.enumerated().map { rowIndex, row in
            let kind: WYSIWYGTableRowPresentationMarker.Kind = switch rowIndex {
            case 0: .header
            case 1: .delimiter
            default: .body
            }
            return WYSIWYGTableRowPresentationMarker(
                generation: context.generation,
                rowRange: row.lineRange,
                kind: kind,
                contentRanges: kind == .delimiter ? [] : row.cells.map(\.contentRange),
                tabOffsets: kind == .delimiter ? [] : tabOffsets(of: row),
                paragraphStyle: kind == .delimiter
                    ? collapsedStyle
                    : rowStyle(base: context.baseParagraphStyle, cellWidths: cellWidths[rowIndex], columns: columns)
            )
        }
    }

    /// A column is as wide as its widest cell, at least one em.
    static func columns(rows: [MarkdownTableRowStructure], cellWidths: [[CGFloat]], baseFont: NSFont) -> Columns {
        let header = rows[0]
        var widths = [CGFloat](repeating: baseFont.pointSize, count: header.cells.count)
        for row in cellWidths {
            for (column, width) in row.enumerated() {
                widths[column] = max(widths[column], width)
            }
        }
        var contentLefts: [CGFloat] = []
        var cursor: CGFloat = 0
        for column in widths.indices {
            let leftPadding = column == 0 && !header.hasLeadingPipe ? 0 : cellPadding
            contentLefts.append(cursor + leftPadding)
            cursor = contentLefts[column] + widths[column] + cellPadding
        }
        return Columns(
            widths: widths,
            contentLefts: contentLefts,
            alignments: rows[1].cells.map(\.alignment),
            hasLeadingPipe: header.hasLeadingPipe,
            totalWidth: cursor
        )
    }

    static func collapsedRowStyle(base: NSParagraphStyle, font: NSFont) -> NSParagraphStyle {
        let style = base.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        let height = collapsedRowHeight(for: font)
        style.tabStops = []
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        style.lineHeightMultiple = 0
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        return style
    }

    /// Height of the collapsed delimiter row: half a text line, room for the header rule.
    static func collapsedRowHeight(for font: NSFont) -> CGFloat {
        ((font.ascender - font.descender + font.leading) / 2).rounded(.up)
    }

    /// The §1 eligibility rules that need only the rows.
    static func isEligible(_ rows: [MarkdownTableRowStructure], in text: NSString) -> Bool {
        guard rows.count >= 2, rows[1].isDelimiterRow else { return false }
        let header = rows[0]
        let columnCount = header.cells.count
        guard rows[1].cells.count == columnCount else { return false }
        for row in rows {
            guard row.cells.count <= columnCount,
                  row.hasLeadingPipe == header.hasLeadingPipe,
                  text.substring(with: row.lineRange).utf16.contains(0x0009) == false
            else {
                return false
            }
        }
        if !header.hasLeadingPipe {
            // No character carries a tab in front of the first column, so it can only start
            // at the line's left edge.
            let firstAlignment = rows[1].cells[0].alignment
            guard firstAlignment == .none || firstAlignment == .left else { return false }
        }
        return true
    }

    /// The pipe in front of each cell. A virtual boundary (no leading pipe) carries no tab.
    static func tabOffsets(of row: MarkdownTableRowStructure) -> [Int] {
        row.cells.compactMap { cell in
            let boundary = cell.rawRange.location - 1
            return boundary >= row.lineRange.location ? boundary : nil
        }
    }

    /// Left-aligned tab stops only, one per cell, placed so each cell lands where its
    /// column's alignment puts it. Every row is its own paragraph, so a row can carry stops
    /// computed from its own cell widths, and every table exercises the one TextKit tab path
    /// T0 proved instead of three (center and right tabs also measure the zero-width and
    /// hanging characters that follow the cell).
    static func rowStyle(base: NSParagraphStyle, cellWidths: [CGFloat], columns: Columns) -> NSParagraphStyle {
        var stops: [NSTextTab] = []
        for (column, cellWidth) in cellWidths.enumerated() where column > 0 || columns.hasLeadingPipe {
            let slack = max(0, columns.widths[column] - cellWidth)
            let offset: CGFloat = switch columns.alignments[column] {
            case .none, .left: 0
            case .center: slack / 2
            case .right: slack
            }
            stops.append(NSTextTab(textAlignment: .left, location: columns.contentLefts[column] + offset))
        }
        let style = base.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.tabStops = stops
        return style
    }

    /// Width of a cell's content as the projection lays it out: folded inline delimiters are
    /// zero width and header cells are bold.
    static func presentedWidth(
        of range: NSRange,
        in text: NSAttributedString,
        baseFont: NSFont,
        isHeader: Bool
    ) -> CGFloat {
        guard range.length > 0, NSMaxRange(range) <= text.length,
              let content = text.attributedSubstring(from: range).mutableCopy() as? NSMutableAttributedString
        else {
            return 0
        }
        let whole = NSRange(location: 0, length: content.length)
        var fontless: [NSRange] = []
        var folded: [NSRange] = []
        content.enumerateAttributes(in: whole) { attributes, run, _ in
            if attributes[.font] == nil {
                fontless.append(run)
            }
            if WYSIWYGInlineFoldPresentation.containsFoldedDelimiterAttributes(attributes) {
                folded.append(run)
            }
        }
        for run in fontless {
            content.addAttribute(.font, value: baseFont, range: run)
        }
        for run in folded {
            content.mutableString.replaceCharacters(
                in: run,
                with: String(repeating: "\u{200B}", count: run.length)
            )
        }
        if isHeader {
            WYSIWYGTableRowPresentationMarker.embolden(content, in: whole)
        }
        let line = CTLineCreateWithAttributedString(content)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}
