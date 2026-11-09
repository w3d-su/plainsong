import Foundation

enum TableEditing {
    static func format(in text: String, selection: NSRange) -> MarkdownEditResult? {
        guard let block = TableBlock(containing: selection.location, in: text) else { return nil }

        let formatted = block.formattedText()
        guard formatted != block.text else { return nil }

        return MarkdownTextEditingSupport.replacement(
            range: block.range,
            string: formatted,
            selection: NSRange(
                location: min(selection.location,
                              block.range.location + MarkdownTextEditingSupport.utf16Length(formatted)),
                length: 0
            )
        )
    }

    static func handleTab(in text: String, selection: NSRange, backwards: Bool) -> MarkdownEditResult? {
        guard let block = TableBlock(containing: selection.location, in: text) else { return nil }
        let cells = block.navigableCells()
        let currentIndex = cells.firstIndex { cell in
            cell.contentRange.contains(selection.location)
        } ?? cells.lastIndex { cell in
            cell.rowRange.contains(selection.location) && selection.location >= cell.contentRange.location
        } ?? cells.lastIndex { cell in
            cell.contentRange.location <= selection.location
        }
        guard let currentIndex else {
            return nil
        }

        let targetIndex = backwards ? currentIndex - 1 : currentIndex + 1
        guard cells.indices.contains(targetIndex) else { return nil }

        let target = cells[targetIndex]
        return MarkdownTextEditingSupport.replacement(
            range: NSRange(location: selection.location, length: 0),
            string: "",
            selection: target.contentRange
        )
    }

    static func handleEnter(in text: String, selection: NSRange) -> MarkdownEditResult? {
        guard selection.length == 0,
              let block = TableBlock(containing: selection.location, in: text) else { return nil }
        guard let row = block.rows
            .first(where: { $0.line.range.contains(selection.location) || selection.location == $0.line.endLocation }),
            !row.isSeparator,
            row.isAtEnd(selection.location)
        else {
            return nil
        }

        let cellCount = max(row.cells.count, block.columnCount)
        guard cellCount > 0 else { return nil }

        let newline = MarkdownTextEditingSupport.insertedLineTerminator(on: row.line, in: text)
        let rowText = "|" + Array(repeating: "  ", count: cellCount).joined(separator: "|") + "|"
        let replacement = "\(newline)\(rowText)"
        return MarkdownTextEditingSupport.replacement(
            range: selection,
            string: replacement,
            // The first cell's second space, between its padding spaces.
            selection: NSRange(
                location: selection.location + MarkdownTextEditingSupport.utf16Length(newline) + 2,
                length: 1
            )
        )
    }
}

private struct TableBlock {
    let rows: [TableRow]
    /// Each row's own source terminator; the last row's is excluded from `range`.
    let terminators: [String]
    let range: NSRange
    let text: String

    var columnCount: Int {
        rows.map(\.cells.count).max() ?? 0
    }

    init?(containing location: Int, in text: String) {
        let currentLine = MarkdownTextEditingSupport.line(containing: location, in: text)
        guard currentLine.text.contains("|") else { return nil }

        var firstLine = currentLine
        while let previous = MarkdownTextEditingSupport.line(before: firstLine, in: text),
              previous.text.contains("|")
        {
            firstLine = previous
        }

        var collected: [TableRow] = []
        var cursor = firstLine.range.location
        while cursor <= (text as NSString).length {
            let line = MarkdownTextEditingSupport.line(containing: cursor, in: text)
            guard line.text.contains("|"), let row = TableRow(line: line) else { break }
            collected.append(row)
            guard line.fullEndLocation > cursor, line.fullEndLocation < (text as NSString).length else { break }
            cursor = line.fullEndLocation
        }

        // GFM starts a table at its header row, the line directly above the first
        // delimiter row. Earlier lines that merely contain `|` are paragraph text: they
        // are neither part of the block nor a place the table helpers act from.
        guard let delimiterIndex = collected.firstIndex(where: \.isSeparator), delimiterIndex > 0 else {
            return nil
        }
        let tableRows = Array(collected[(delimiterIndex - 1)...])
        guard tableRows.count >= 2,
              let header = tableRows.first,
              let last = tableRows.last,
              currentLine.range.location >= header.line.range.location
        else {
            return nil
        }

        rows = tableRows
        terminators = tableRows.map { MarkdownTextEditingSupport.lineTerminator(after: $0.line, in: text) }
        let start = header.line.range.location
        range = NSRange(location: start, length: last.line.endLocation - start)
        self.text = MarkdownTextEditingSupport.substring(range, in: text)
    }

    func formattedText() -> String {
        let widths = columnWidths()
        var formatted = ""
        for (index, row) in rows.enumerated() {
            let cells = (0 ..< widths.count).map { column -> String in
                let cell = column < row.cells.count ? row.cells[column] : TableCell(raw: "")
                if row.isSeparator {
                    return separatorText(for: cell.alignment, width: widths[column])
                }
                return pad(cell.raw, toDisplayWidth: widths[column])
            }
            formatted += "| " + cells.joined(separator: " | ") + " |"
            if index < rows.count - 1 {
                // Rows keep their own terminators, so CRLF tables stay CRLF.
                formatted += terminators[index].isEmpty ? "\n" : terminators[index]
            }
        }
        return formatted
    }

    func navigableCells() -> [TableCellRange] {
        rows.flatMap { row in
            row.isSeparator ? [] : row.cellRanges
        }
    }

    private func columnWidths() -> [Int] {
        let count = columnCount
        return (0 ..< count).map { index in
            max(3, rows.filter { !$0.isSeparator }.map { row in
                guard index < row.cells.count else { return 0 }
                return displayWidth(of: row.cells[index].raw)
            }.max() ?? 0)
        }
    }

    private func pad(_ string: String, toDisplayWidth width: Int) -> String {
        let padding = max(0, width - displayWidth(of: string))
        return string + String(repeating: " ", count: padding)
    }

    private func displayWidth(of string: String) -> Int {
        string.unicodeScalars.reduce(0) { width, scalar in
            if scalar.properties.isEmojiPresentation || scalar.value >= 0x1100 {
                width + 2
            } else {
                width + 1
            }
        }
    }

    private func separatorText(for alignment: TableAlignment, width: Int) -> String {
        switch alignment {
        case .none:
            String(repeating: "-", count: width)
        case .left:
            ":" + String(repeating: "-", count: max(2, width - 1))
        case .right:
            String(repeating: "-", count: max(2, width - 1)) + ":"
        case .center:
            ":" + String(repeating: "-", count: max(1, width - 2)) + ":"
        }
    }
}

private struct TableRow {
    let line: MarkdownLine
    let cells: [TableCell]
    let cellRanges: [TableCellRange]

    var isSeparator: Bool {
        !cells.isEmpty && cells.allSatisfy(\.isSeparator)
    }

    init?(line: MarkdownLine) {
        // One definition of cell boundaries, shared with WYSIWYG table presentation.
        guard let structure = MarkdownTableRowStructure(line: line.text, lineStart: line.range.location) else {
            return nil
        }
        self.line = line
        cells = structure.cells.map { TableCell(raw: $0.trimmedText) }
        cellRanges = structure.cells.map { TableCellRange(rowRange: line.range, contentRange: $0.contentRange) }
    }

    func isAtEnd(_ location: Int) -> Bool {
        let storage = line.text as NSString
        var end = storage.length
        while end > 0 {
            let unit = storage.character(at: end - 1)
            if unit == 32 || unit == 9 {
                end -= 1
            } else {
                break
            }
        }
        return location == line.range.location + end
    }
}

private struct TableCell {
    let raw: String

    var isSeparator: Bool {
        MarkdownTableRowStructure.isDelimiterCell(raw)
    }

    var alignment: TableAlignment {
        switch MarkdownTableRowStructure.alignment(ofDelimiterCell: raw) {
        case .center:
            .center
        case .left:
            .left
        case .right:
            .right
        case .none:
            .none
        }
    }
}

private struct TableCellRange {
    let rowRange: NSRange
    let contentRange: NSRange
}

private enum TableAlignment {
    case none
    case left
    case right
    case center
}
