import AppKit
import MarkdownCore

/// Non-user-facing T0 mechanism spike (`docs/table-wysiwyg-gates.md` T0). No App or public
/// presentation case reaches it. Tables are found by a line scan here; T1 replaces the scan
/// with tree-sitter `pipe_table` nodes and folds the result into the visible-range plan.
extension MarkdownSTTextView {
    private static var tableT0SpikeGeneration: UInt64 = 0

    @discardableResult
    func setWYSIWYGTableT0SpikeEnabled(_ isEnabled: Bool) -> Bool {
        guard isEnabled else {
            removeAllWYSIWYGTableRowPresentationMarkers()
            return true
        }
        guard setWYSIWYGZeroWidthFoldingEnabled(true),
              let textStorage = (textContentManager as? NSTextContentStorage)?.textStorage
        else {
            return false
        }

        Self.tableT0SpikeGeneration &+= 1
        let generation = Self.tableT0SpikeGeneration
        let availableWidth = textContainer.size.width - 2 * textContainer.lineFragmentPadding
        let markers = WYSIWYGTableT0SpikeScanner.tables(in: textStorage.string as NSString).flatMap { rows in
            let rowStart = rows[0].lineRange.location
            let paragraphStyle = rowStart < textStorage.length
                ? textStorage.attribute(.paragraphStyle, at: rowStart, effectiveRange: nil) as? NSParagraphStyle
                : nil
            return WYSIWYGTablePresentationPlanner.markers(
                rows: rows,
                in: textStorage,
                context: WYSIWYGTablePresentationPlanner.Context(
                    baseFont: font,
                    baseParagraphStyle: paragraphStyle ?? defaultParagraphStyle,
                    availableWidth: availableWidth,
                    generation: generation
                )
            ) ?? []
        }
        applyWYSIWYGTableRowPresentationMarkers(markers, generation: generation)
        return true
    }
}

/// Line-scan table finder for the T0 spike only: a header row, a delimiter row with the
/// same cell count, then every following line that has a pipe and is not blank.
enum WYSIWYGTableT0SpikeScanner {
    static func tables(in text: NSString) -> [[MarkdownTableRowStructure]] {
        var lines: [MarkdownTableRowStructure?] = []
        var location = 0
        while location < text.length {
            var lineEnd = 0
            var contentsEnd = 0
            text.getLineStart(
                nil,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            let line = text.substring(with: NSRange(location: location, length: contentsEnd - location))
            lines.append(line.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil
                : MarkdownTableRowStructure(line: line, lineStart: location))
            location = lineEnd
        }

        var tables: [[MarkdownTableRowStructure]] = []
        var index = 0
        while index + 1 < lines.count {
            guard let header = lines[index], let delimiter = lines[index + 1],
                  delimiter.isDelimiterRow, delimiter.cells.count == header.cells.count
            else {
                index += 1
                continue
            }
            var rows = [header, delimiter]
            index += 2
            while index < lines.count, let row = lines[index] {
                rows.append(row)
                index += 1
            }
            tables.append(rows)
        }
        return tables
    }
}
