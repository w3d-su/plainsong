import Foundation

/// Fenced-code, `$$`, and inline code/math delimiter pairing for the
/// `MathZones` scanner, plus the paragraph-boundary checks they share.
extension MathZones {
    // MARK: - fenced code / $$ delimiters

    func fenceOpening(in line: MarkdownLine, context ctx: MathLineContext) -> MathFence? {
        guard ctx.contentIndent <= 3 else { return nil }
        let storage = line.text as NSString
        let index = ctx.contentIndex
        guard index < storage.length else { return nil }

        let marker = storage.character(at: index)
        guard marker == 96 || marker == 126 else { return nil }
        var runEnd = index
        while runEnd < storage.length, storage.character(at: runEnd) == marker {
            runEnd += 1
        }
        let count = runEnd - index
        guard count >= 3 else { return nil }

        let info = storage.substring(from: runEnd).trimmingCharacters(in: .whitespaces)
        if marker == 96, info.contains("`") { return nil }
        let language = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first?.lowercased()
        return MathFence(
            marker: marker,
            count: count,
            isMath: language == "math",
            openLocation: line.range.location,
            contentStart: line.fullEndLocation,
            depth: ctx.containerDepth
        )
    }

    func isFenceClose(in line: MarkdownLine, context ctx: MathLineContext, fence: MathFence) -> Bool {
        guard ctx.contentIndent <= 3 else { return false }
        let storage = line.text as NSString
        let index = ctx.contentIndex
        guard index < storage.length else { return false }

        var runEnd = index
        while runEnd < storage.length, storage.character(at: runEnd) == fence.marker {
            runEnd += 1
        }
        guard runEnd - index >= fence.count else { return false }
        return storage.substring(from: runEnd).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `$$`-run of ≥ 2 followed by whitespace or end of line opens display
    /// math; anything after the run is the (discarded) meta. `$$x` stays inline.
    func mathFlowOpen(
        in line: MarkdownLine, context ctx: MathLineContext
    ) -> (location: Int, contentStart: Int, runLength: Int)? {
        guard ctx.contentIndent <= 3 else { return nil }
        let storage = line.text as NSString
        let index = ctx.contentIndex
        guard index < storage.length, storage.character(at: index) == 36 else { return nil }
        var runEnd = index
        while runEnd < storage.length, storage.character(at: runEnd) == 36 {
            runEnd += 1
        }
        guard runEnd - index >= 2 else { return nil }
        if runEnd < storage.length {
            let after = storage.character(at: runEnd)
            guard after == 32 || after == 9 else { return nil }
        }
        return (line.range.location, line.fullEndLocation, runEnd - index)
    }

    /// Closing `$$` needs a run at least as long as the opening run and only
    /// trailing whitespace.
    func isMathDelimiterClose(
        in line: MarkdownLine, context ctx: MathLineContext, minimumRun: Int
    ) -> Bool {
        guard ctx.contentIndent <= 3 else { return false }
        let storage = line.text as NSString
        let index = ctx.contentIndex
        guard index < storage.length else { return false }
        var runEnd = index
        while runEnd < storage.length, storage.character(at: runEnd) == 36 {
            runEnd += 1
        }
        guard runEnd - index >= minimumRun else { return false }
        return storage.substring(from: runEnd).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Whether a code or math run opened at `openLocal` would find its closer
    /// before the next paragraph or block boundary. An unpaired run is literal
    /// text; entering pending mode for it would hide later code and math.
    mutating func inlineDelimiterCloses(
        marker: unichar,
        width: Int,
        from localIndex: Int,
        on line: MarkdownLine,
        context ctx: MathLineContext,
        resolver: MathContainerResolver,
        fileKind: FileKind,
        cellBounded: Bool = false
    ) -> Bool {
        let origin = line.range.location + localIndex
        let spec = MathDelimiterSpec(marker: marker, width: width)
        let storage = line.text as NSString
        // Inside a table cell the closer has to be on this line, before the
        // next unescaped pipe. The next row is a different scope.
        if cellBounded {
            return delimiterRunCloses(
                marker: marker, width: width, in: storage, from: localIndex,
                stoppingAtUnescapedPipe: true
            ) != nil
        }
        if let horizon = delimiterHorizons[spec],
           horizon.coveredFrom <= origin, origin < horizon.stop
        {
            return false
        }

        if delimiterRunCloses(marker: marker, width: width, in: storage, from: localIndex) != nil {
            return true
        }
        // ATX headings and other leaf starters do not continue onto the next line.
        if isBlockStarterLine(in: line, context: ctx, allowsSetext: false) {
            recordDelimiterMiss(spec, from: origin, stop: line.fullEndLocation)
            return false
        }

        var probe = resolver
        var probeCursor = line.fullEndLocation
        var probeWasParagraph = !isBlockStarterLine(in: line, context: ctx, allowsSetext: false)
        var probePreviousContent: String? = probeWasParagraph ? strippedContent(in: line, context: ctx) : nil
        var probeDepth = ctx.containerDepth
        let document = text as NSString

        while probeCursor < document.length {
            let next = MarkdownTextEditingSupport.line(containing: probeCursor, in: text)
            let nextContext = probe.resolve(
                next,
                paragraphDepth: probeWasParagraph ? probeDepth : nil
            )
            let paragraphContinues = probeWasParagraph && nextContext.containerDepth == probeDepth
            let tableHeader = paragraphContinues ? probePreviousContent : nil
            if probe.didOpenContainer || interruptsInlineDelimiters(
                next,
                context: nextContext,
                paragraphContinues: paragraphContinues,
                tableHeader: tableHeader,
                fileKind: fileKind
            ) {
                recordDelimiterMiss(spec, from: origin, stop: next.range.location)
                return false
            }
            if delimiterRunCloses(
                marker: marker,
                width: width,
                in: next.text as NSString,
                from: nextContext.contentStart
            ) != nil {
                return true
            }
            probeWasParagraph = !isBlockStarterLine(
                in: next,
                context: nextContext,
                allowsSetext: paragraphContinues && nextContext.contentIndent <= 3
                    && !nextContext.isLazyContinuation,
                tableHeader: nextContext.isLazyContinuation ? nil : tableHeader
            )
            probePreviousContent = probeWasParagraph ? strippedContent(in: next, context: nextContext) : nil
            probeDepth = nextContext.containerDepth
            let nextCursor = next.fullEndLocation
            if nextCursor <= probeCursor { break }
            probeCursor = nextCursor
        }
        recordDelimiterMiss(spec, from: origin, stop: document.length)
        return false
    }

    func delimiterRunCloses(
        marker: unichar,
        width: Int,
        in storage: NSString,
        from start: Int,
        stoppingAtUnescapedPipe: Bool = false
    ) -> Int? {
        var index = start
        while index < storage.length {
            let unit = storage.character(at: index)
            if stoppingAtUnescapedPipe, unit == 124 {
                // Same parity rule as `tableCells` / `isEscaped`: `\|` stays
                // in the cell, `\\|` and `\\\\|` are boundaries.
                if !isEscaped(index, in: storage) { return nil }
                index += 1
                continue
            }
            guard unit == marker else {
                index += 1
                continue
            }
            var runEnd = index + 1
            while runEnd < storage.length, storage.character(at: runEnd) == marker {
                runEnd += 1
            }
            let run = runEnd - index
            // Code spans and inline math both close on an equal-length run.
            if run == width { return runEnd }
            index = runEnd
        }
        return nil
    }

    func interruptsInlineDelimiters(
        _ line: MarkdownLine,
        context ctx: MathLineContext,
        paragraphContinues: Bool,
        tableHeader: String?,
        fileKind: FileKind
    ) -> Bool {
        if ctx.isBlank { return true }
        if ctx.contentIndent >= 4, !paragraphContinues { return true }
        if fenceOpening(in: line, context: ctx) != nil { return true }
        if mathFlowOpen(in: line, context: ctx) != nil { return true }
        if fileKind == .markdown,
           let head = lineStartTagHead(in: line, context: ctx),
           htmlBlockEnd(
               for: head, in: line, context: ctx, canInterrupt: !paragraphContinues
           ) != nil
        {
            return true
        }
        return isBlockStarterLine(
            in: line,
            context: ctx,
            allowsSetext: paragraphContinues && ctx.contentIndent <= 3 && !ctx.isLazyContinuation,
            tableHeader: paragraphContinues && !ctx.isLazyContinuation ? tableHeader : nil
        )
    }

    mutating func recordDelimiterMiss(
        _ spec: MathDelimiterSpec,
        from origin: Int,
        stop: Int
    ) {
        guard origin < stop else { return }
        if var existing = delimiterHorizons[spec] {
            if origin < existing.coveredFrom {
                existing.coveredFrom = origin
                existing.stop = stop
                delimiterHorizons[spec] = existing
            }
        } else {
            delimiterHorizons[spec] = MathDelimiterHorizon(coveredFrom: origin, stop: stop)
        }
    }

    // MARK: - paragraph boundary detection

    /// Lines that start or continue a leaf block instead of paragraph text:
    /// headings, thematic breaks/setext underlines, and GFM delimiter rows
    /// whose cells match `tableHeader` (the previous paragraph line, or nil
    /// where no table can start). Four or more columns of indent make any of
    /// them paragraph continuation (or indented code) instead.
    func isBlockStarterLine(
        in line: MarkdownLine,
        context ctx: MathLineContext,
        allowsSetext: Bool,
        tableHeader: String? = nil
    ) -> Bool {
        guard ctx.contentIndent <= 3 else { return false }
        let content = strippedContent(in: line, context: ctx)
        let trimmed = Self.trimMarkdownWhitespace(content)
        guard let first = trimmed.first else { return false }
        if first == "#", isHeading(trimmed) { return true }
        if isRuleOrSetext(trimmed, allowsSetext: allowsSetext) { return true }
        return Self.isTableDelimiterRow(trimmed, header: tableHeader)
    }

    func isHeading(_ trimmed: String) -> Bool {
        var count = 0
        for char in trimmed {
            if char == "#" { count += 1 } else { break }
        }
        guard count >= 1, count <= 6 else { return false }
        let rest = trimmed.dropFirst(count)
        return rest.isEmpty || rest.first == " " || rest.first == "\t"
    }

    func isRuleOrSetext(_ trimmed: String, allowsSetext: Bool) -> Bool {
        let compact = trimmed.filter { $0 != " " && $0 != "\t" }
        guard let marker = compact.first, compact.allSatisfy({ $0 == marker }) else { return false }
        // A setext underline is one unbroken run (`= =` is paragraph text);
        // only a thematic break may contain inner spaces.
        let isUnbrokenRun = trimmed.allSatisfy { $0 == marker }
        switch marker {
        case "=":
            // Only a setext underline; otherwise (including lazy lines) text.
            return allowsSetext && isUnbrokenRun
        case "-":
            // `---` is a thematic break anywhere. Shorter runs are a setext
            // underline only under an open, non-lazy paragraph (`$a` / `- ` / `b`).
            if compact.count >= 3 { return true }
            return allowsSetext && isUnbrokenRun
        case "*", "_":
            return compact.count >= 3
        default:
            return false
        }
    }
}
