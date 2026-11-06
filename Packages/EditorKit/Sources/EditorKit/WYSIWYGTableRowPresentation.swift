import AppKit

/// Attribute carried by the raw backing range of one table row that is presented as aligned
/// columns (`docs/table-wysiwyg-gates.md`, mechanism A).
///
/// Only the projected `NSTextParagraph` changes: pipes that start a cell become `\t`, every
/// other structural character (spaces around cell content, a trailing pipe) becomes U+200B,
/// and the paragraph gets tab stops at the table's column positions. All three are one UTF-16
/// unit, so every raw offset survives; the backing string never changes.
final class WYSIWYGTableRowPresentationMarker: NSObject {
    static let attribute = NSAttributedString.Key("app.plainsong.wysiwyg.tableRowPresentation")
    /// Set on the projected paragraph of a collapsed delimiter row. It has no text to number,
    /// so the line-number gutter skips it.
    static let collapsedRowAttribute = NSAttributedString.Key("app.plainsong.wysiwyg.tableCollapsedRow")

    enum Kind: Equatable {
        case header
        case delimiter
        case body
    }

    let generation: UInt64
    /// The row's line without its terminator.
    let rowRange: NSRange
    let kind: Kind
    /// Cell content ranges, absolute, ascending. Empty for the delimiter row.
    let contentRanges: [NSRange]
    /// Absolute offsets of the pipes that project to `\t` (the pipe in front of each cell).
    let tabOffsets: [Int]
    let paragraphStyle: NSParagraphStyle

    init(
        generation: UInt64,
        rowRange: NSRange,
        kind: Kind,
        contentRanges: [NSRange],
        tabOffsets: [Int],
        paragraphStyle: NSParagraphStyle
    ) {
        self.generation = generation
        self.rowRange = rowRange
        self.kind = kind
        self.contentRanges = contentRanges
        self.tabOffsets = tabOffsets
        self.paragraphStyle = paragraphStyle
        super.init()
    }

    /// Structural runs (everything in the row outside cell content), absolute, ascending.
    var structuralRanges: [NSRange] {
        guard kind != .delimiter else { return [rowRange] }
        var runs: [NSRange] = []
        var cursor = rowRange.location
        for content in contentRanges {
            if content.location > cursor {
                runs.append(NSRange(location: cursor, length: content.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(content))
        }
        if NSMaxRange(rowRange) > cursor {
            runs.append(NSRange(location: cursor, length: NSMaxRange(rowRange) - cursor))
        }
        return runs
    }

    /// Projects this row into `paragraph`, where the row starts at `rowLocation`.
    func project(into paragraph: NSMutableAttributedString, rowLocation: Int) {
        let delta = rowLocation - rowRange.location
        let tabs = Set(tabOffsets)
        let trailingStart = contentRanges.last.map(NSMaxRange) ?? NSMaxRange(rowRange)
        for run in structuralRanges {
            // After the last cell, U+200B reports x = 0 in TextKit's layout (so the last
            // cell's segment frame ends before it starts). Spaces there hang past the line
            // end like any trailing whitespace: invisible and correctly positioned.
            let trailing = kind != .delimiter && run.location >= trailingStart
            let units: [unichar] = (run.location ..< NSMaxRange(run)).map { offset in
                tabs.contains(offset) ? 0x0009 : trailing && offset == NSMaxRange(run) - 1 ? 0x0020 : 0x200B
            }
            paragraph.mutableString.replaceCharacters(
                in: run.offset(by: delta),
                with: String(utf16CodeUnits: units, count: units.count)
            )
        }

        if kind == .header {
            for content in contentRanges where content.length > 0 {
                Self.embolden(paragraph, in: content.offset(by: delta))
            }
        }

        let whole = NSRange(location: 0, length: paragraph.length)
        paragraph.addAttribute(.paragraphStyle, value: paragraphStyle, range: whole)
        if kind == .delimiter {
            paragraph.addAttribute(Self.collapsedRowAttribute, value: true, range: whole)
        }
    }

    /// Converts every font run in `range` to its bold variant (header cells).
    static func embolden(_ attributed: NSMutableAttributedString, in range: NSRange) {
        attributed.enumerateAttribute(.font, in: range) { value, run, _ in
            guard let font = value as? NSFont else { return }
            attributed.addAttribute(
                .font,
                value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask),
                range: run
            )
        }
    }
}

/// Where a collapsed caret may rest in a presented table row: never on hidden structure.
enum WYSIWYGTableRowCaretSnap {
    /// Returns `offset` unchanged inside cell content (edges included) or outside the row.
    /// Between cells, `.nearest` uses the projected tab as the divider: TextKit returns the
    /// tab's own offset for a click in its left half and the next offset for its right half.
    static func snap(
        offset: Int,
        rowRange: NSRange,
        contentRanges: [NSRange],
        tabOffsets: [Int],
        preferring direction: WYSIWYGCaretSnap.Direction
    ) -> Int {
        let rowStart = rowRange.location
        let rowEnd = NSMaxRange(rowRange)
        guard offset >= rowStart, offset <= rowEnd,
              let first = contentRanges.first, let last = contentRanges.last
        else {
            return offset
        }
        if contentRanges.contains(where: { offset >= $0.location && offset <= NSMaxRange($0) }) {
            return offset
        }

        if offset < first.location {
            // Leading run (line start, spaces, the first pipe). The line start stays
            // reachable by keyboard so Left can leave the row.
            if direction == .backward {
                return rowStart
            }
            return first.location
        }

        if offset > NSMaxRange(last) {
            // Trailing run (spaces, a trailing pipe). The line end stays reachable by keyboard
            // so Right can leave the row.
            if direction == .forward {
                return rowEnd
            }
            return NSMaxRange(last)
        }

        return snapBetweenCells(
            offset: offset,
            contentRanges: contentRanges,
            tabOffsets: tabOffsets,
            direction: direction
        )
    }

    private static func snapBetweenCells(
        offset: Int,
        contentRanges: [NSRange],
        tabOffsets: [Int],
        direction: WYSIWYGCaretSnap.Direction
    ) -> Int {
        for index in 0 ..< contentRanges.count - 1 {
            let before = contentRanges[index]
            let after = contentRanges[index + 1]
            guard offset > NSMaxRange(before), offset < after.location else { continue }
            switch direction {
            case .forward:
                return after.location
            case .backward:
                return NSMaxRange(before)
            case .nearest:
                let divider = tabOffsets.first { $0 >= NSMaxRange(before) && $0 < after.location }
                    ?? NSMaxRange(before)
                return offset <= divider ? NSMaxRange(before) : after.location
            }
        }
        return offset
    }
}
