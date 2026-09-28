import Foundation

/// GFM table delimiter rows, as the preview's `micromark-extension-gfm-table`
/// reads them. A delimiter row turns the line above it into a table header —
/// even mid-paragraph — only when both rows have the same number of cells.
/// Otherwise both lines stay paragraph text, and code spans or inline math
/// continue across them.
///
/// Once the table is open, each row and each cell is its own inline scope:
/// an unescaped pipe or the end of the row cuts `$` / code-span pairing.
/// `\|` stays inside the cell. Pipes in an ordinary paragraph are not cells.
extension MathZones {
    struct TableRowPlan {
        /// `$` and code spans must not pair across an unescaped pipe or a row end.
        var boundsCells: Bool
        /// This line is a body row of a table that is already open.
        var continues: Bool
        /// Cell count when this line is the delimiter row that opens a table.
        var openedColumns: Int?
    }

    /// True when `row` (container-stripped, ASCII-trimmed) is a delimiter row
    /// whose cell count matches `header`, the previous paragraph line.
    static func isTableDelimiterRow(_ row: String, header: String?) -> Bool {
        guard let header, let cells = delimiterCellCount(row) else { return false }
        let trimmedHeader = trimMarkdownWhitespace(header)
        guard !trimmedHeader.isEmpty else { return false }
        return cells == tableCellCount(trimmedHeader)
    }

    /// Cells of a delimiter row: `:?-+:?` separated by pipes, with optional
    /// edge pipes. A row without a pipe needs a colon; bare dashes are a
    /// setext underline or thematic break instead.
    static func delimiterCellCount(_ row: String) -> Int? {
        guard row.contains("-"),
              row.allSatisfy({ $0 == "|" || $0 == ":" || $0 == "-" || $0 == " " || $0 == "\t" })
        else { return nil }
        if !row.contains("|"), !row.contains(":") { return nil }
        let cells = tableCells(row)
        for cell in cells {
            let content = trimMarkdownWhitespace(cell)
            var body = Substring(content)
            if body.first == ":" { body = body.dropFirst() }
            if body.last == ":" { body = body.dropLast() }
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }
        }
        return cells.isEmpty ? nil : cells.count
    }

    static func tableCellCount(_ row: String) -> Int {
        max(1, tableCells(row).count)
    }

    /// A `|` is escaped only when an odd number of `\` immediately precedes
    /// it. An even run pairs into literal backslashes, so the pipe is a cell
    /// boundary. Closer lookahead and the pending-span scan use this same rule.
    static func pipeIsEscaped(backslashCount: Int) -> Bool {
        backslashCount % 2 == 1
    }

    /// Splits on unescaped pipes — including pipes inside code spans, as GFM
    /// does — and drops the empty cells outside leading/trailing edge pipes.
    static func tableCells(_ row: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var backslashes = 0
        for character in row {
            if character == "\\" {
                current.append(character)
                backslashes += 1
                continue
            }
            if character == "|", !pipeIsEscaped(backslashCount: backslashes) {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
            backslashes = 0
        }
        cells.append(current)
        if cells.count > 1, trimMarkdownWhitespace(cells[0]).isEmpty, row.first == "|" {
            cells.removeFirst()
        }
        if cells.count > 1, trimMarkdownWhitespace(cells[cells.count - 1]).isEmpty, row.last == "|" {
            cells.removeLast()
        }
        return cells
    }

    /// Paragraph text after fences, display math, indented code, and HTML
    /// blocks have been ruled out. A matching delimiter row opens a table;
    /// later body rows keep their own cells.
    mutating func finishParagraphLine(
        _ line: MarkdownLine,
        context ctx: MathLineContext,
        fileKind: FileKind,
        resolver: MathContainerResolver,
        inline: inout MathInlineScanState,
        previous: ParagraphScanState
    ) -> ParagraphScanState {
        let paragraphContinues = previous.wasParagraph && ctx.containerDepth == previous.paragraphDepth
        let delimiterHeader = paragraphContinues && !resolver.didOpenContainer && !ctx.isLazyContinuation
            ? previous.content : nil
        let isBlockStarter = isBlockStarterLine(
            in: line,
            context: ctx,
            allowsSetext: paragraphContinues && ctx.contentIndent <= 3 && !resolver.didOpenContainer
                && !ctx.isLazyContinuation,
            tableHeader: delimiterHeader
        )
        let tablePlan = tableRowPlan(
            previous: previous,
            line: line,
            context: ctx,
            resolver: resolver,
            isBlockStarter: isBlockStarter,
            delimiterHeader: delimiterHeader,
            fileKind: fileKind
        )
        // A table row is not the paragraph that preceded it. Drop a pending
        // span here so it cannot close inside this row's cells.
        if isBlockStarter || tablePlan.boundsCells {
            inline.resetDelimiters()
        }
        let events = scanInline(
            line, context: ctx, fileKind: fileKind, resolver: resolver,
            state: &inline, cellBounded: tablePlan.boundsCells
        )
        if fileKind == .mdx {
            applyContainerEvents(events, in: line, context: ctx)
        }
        let openedTable = tablePlan.openedColumns != nil
        return ParagraphScanState(
            wasParagraph: tablePlan.continues ? false : !isBlockStarter,
            paragraphDepth: ctx.containerDepth,
            content: (isBlockStarter || tablePlan.continues) ? nil : strippedContent(in: line, context: ctx),
            tableColumns: tablePlan.continues ? previous.tableColumns : tablePlan.openedColumns,
            tableDepth: tablePlan.continues ? previous.tableDepth : (openedTable ? ctx.containerDepth : nil)
        )
    }

    /// Header, delimiter, or body. Body rows keep going through later
    /// non-blank lines until a blank line, a lazy line, a new container, or
    /// an interrupting block. GFM does not require a body row to repeat the
    /// header's pipe count.
    func tableRowPlan(
        previous: ParagraphScanState,
        line: MarkdownLine,
        context ctx: MathLineContext,
        resolver: MathContainerResolver,
        isBlockStarter: Bool,
        delimiterHeader: String?,
        fileKind: FileKind
    ) -> TableRowPlan {
        if continuesOpenTable(
            previous, line: line, context: ctx,
            didOpenContainer: resolver.didOpenContainer, fileKind: fileKind
        ) {
            return TableRowPlan(boundsCells: true, continues: true, openedColumns: nil)
        }
        let opened = isBlockStarter
            ? delimiterColumnCount(in: line, context: ctx, header: delimiterHeader) : nil
        let header = !isBlockStarter && isTableHeaderLine(line, context: ctx, resolver: resolver)
        return TableRowPlan(boundsCells: header, continues: false, openedColumns: opened)
    }

    func continuesOpenTable(
        _ previous: ParagraphScanState,
        line: MarkdownLine,
        context ctx: MathLineContext,
        didOpenContainer: Bool,
        fileKind: FileKind
    ) -> Bool {
        guard previous.tableColumns != nil, previous.tableDepth == ctx.containerDepth,
              !ctx.isBlank, !ctx.isLazyContinuation, !didOpenContainer, ctx.contentIndent < 4
        else { return false }
        if fenceOpening(in: line, context: ctx) != nil { return false }
        if isBlockStarterLine(in: line, context: ctx, allowsSetext: false) { return false }
        if fileKind == .markdown,
           let head = lineStartTagHead(in: line, context: ctx),
           htmlBlockEnd(for: head, in: line, context: ctx, canInterrupt: true) != nil
        {
            return false
        }
        return true
    }

    /// The line above a matching delimiter row. Its pipes are already cells,
    /// even though the delimiter itself is the next line.
    func isTableHeaderLine(
        _ line: MarkdownLine,
        context ctx: MathLineContext,
        resolver: MathContainerResolver
    ) -> Bool {
        guard !ctx.isBlank, !ctx.isLazyContinuation, ctx.contentIndent <= 3 else { return false }
        let header = strippedContent(in: line, context: ctx)
        guard !Self.trimMarkdownWhitespace(header).isEmpty else { return false }
        let nextCursor = line.fullEndLocation
        guard nextCursor < (text as NSString).length else { return false }
        let next = MarkdownTextEditingSupport.line(containing: nextCursor, in: text)
        var probe = resolver
        let nextContext = probe.resolve(next, paragraphDepth: ctx.containerDepth)
        guard !probe.didOpenContainer, !nextContext.isLazyContinuation,
              nextContext.containerDepth == ctx.containerDepth,
              nextContext.contentIndent <= 3, !nextContext.isBlank
        else { return false }
        let row = Self.trimMarkdownWhitespace(strippedContent(in: next, context: nextContext))
        return Self.isTableDelimiterRow(row, header: header)
    }

    func delimiterColumnCount(
        in line: MarkdownLine, context ctx: MathLineContext, header: String?
    ) -> Int? {
        guard let header else { return nil }
        let row = Self.trimMarkdownWhitespace(strippedContent(in: line, context: ctx))
        guard Self.isTableDelimiterRow(row, header: header) else { return nil }
        return Self.delimiterCellCount(row)
    }
}
