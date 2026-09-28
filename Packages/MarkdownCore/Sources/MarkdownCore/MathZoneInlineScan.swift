import Foundation

/// Inline-scan state carried across lines, matching how the preview parses:
/// a code span or `$`/`$$` pair may close on a later line of the same
/// paragraph, an unclosed `<Tag` keeps its attribute state across lines, and
/// an unclosed MDX `{…}` expression keeps full JavaScript lexical state
/// (strings, escapes, comments, template literals) so braces inside them do
/// not close the expression.
struct MathInlineScanState {
    enum Pending {
        case code(ticks: Int, open: Int)
        case math(width: Int, open: Int)
    }

    var pending: Pending?
    var tag: MathTagScanState?
    var expression: MathExpressionScanState?
    /// This line is a GFM table row: unescaped pipes end a cell.
    var cellBounded = false

    /// Paragraph-level delimiters die at blank lines and block boundaries;
    /// tag/expression states are lexical and persist.
    mutating func resetDelimiters() {
        pending = nil
    }
}

struct MathTagScanState {
    let open: Int
    let head: MathTagHead
    /// The tag's `<` was the first non-whitespace character and the line's
    /// indent was ≤ 3 columns, so a closer on a later line still opens a block.
    let openedAtBlockStart: Bool
    var quote: unichar?
    /// `{…}` expression inside attributes; shares the JS lexical machine.
    var attributeExpression: JSLexicalState?
}

struct MathTagHead {
    /// Lowercased for case-insensitive matching (container stack, tag lists).
    let name: String
    /// The name exactly as written — JSX components keep their case.
    let rawName: String
    let isClosing: Bool
    /// `<!…` / `<?…` — standalone markup, never a container.
    let isStandalone: Bool
    /// Tag name followed by whitespace, `/`, `>` or end of line, and — in MDX —
    /// a well-formed name (`Foo`, `Foo.Bar`, `ns:Foo`). Rejects autolinks
    /// (`<https://…>`) and similar `<word:` runs.
    let isContainerEligible: Bool
}

/// One completed `<…>` token, emitted while scanning so the block scanner can
/// maintain the container stack.
struct MathTagEvent {
    let head: MathTagHead
    let isSelfContained: Bool
    let range: NSRange
    let openedAtBlockStart: Bool
}

struct MathExpressionScanState {
    let open: Int
    var lexical: JSLexicalState
}

extension MathZones {
    /// Scan one line's stripped content for inline spans. Returns completed
    /// tag tokens; zones are appended to `excludedZones` / `mathZones` with
    /// absolute UTF-16 positions.
    mutating func scanInline(
        _ line: MarkdownLine,
        context ctx: MathLineContext,
        fileKind: FileKind,
        resolver: MathContainerResolver,
        state inline: inout MathInlineScanState,
        cellBounded: Bool = false
    ) -> [MathTagEvent] {
        let storage = line.text as NSString
        var events: [MathTagEvent] = []
        var index = ctx.contentStart
        inline.cellBounded = cellBounded
        inline.tag?.attributeExpression?.endOfLine()
        inline.expression?.lexical.endOfLine()

        while index < storage.length {
            if inline.tag != nil {
                (index, inline.tag) = scanTagContent(
                    in: storage, at: index, tag: inline.tag!, base: line.range.location,
                    events: &events
                )
                continue
            }
            if inline.expression != nil {
                (index, inline.expression) = scanExpressionContent(
                    in: storage, at: index, expression: inline.expression!, base: line.range.location
                )
                continue
            }
            if let pending = inline.pending {
                index = scanPendingDelimiter(in: storage, at: index, pending: pending,
                                             base: line.range.location, state: &inline)
                continue
            }
            index = scanTextUnit(
                in: storage, at: index, line: line, context: ctx, base: line.range.location,
                fileKind: fileKind, resolver: resolver, state: &inline
            )
        }
        return events
    }

    // MARK: - text units

    private mutating func scanTextUnit(
        in storage: NSString,
        at index: Int,
        line: MarkdownLine,
        context ctx: MathLineContext,
        base: Int,
        fileKind: FileKind,
        resolver: MathContainerResolver,
        state inline: inout MathInlineScanState
    ) -> Int {
        let unit = storage.character(at: index)
        switch unit {
        case 96 where !isEscaped(index, in: storage):
            let runEnd = backtickRunEnd(in: storage, from: index)
            let width = runEnd - index
            if inlineDelimiterCloses(
                marker: 96, width: width, from: runEnd, on: line, context: ctx,
                resolver: resolver, fileKind: fileKind, cellBounded: inline.cellBounded
            ) {
                inline.pending = .code(ticks: width, open: base + index)
            }
            return runEnd
        case 36 where !isEscaped(index, in: storage):
            var runEnd = index
            while runEnd < storage.length, storage.character(at: runEnd) == 36 {
                runEnd += 1
            }
            let width = runEnd - index
            if inlineDelimiterCloses(
                marker: 36, width: width, from: runEnd, on: line, context: ctx,
                resolver: resolver, fileKind: fileKind, cellBounded: inline.cellBounded
            ) {
                inline.pending = .math(width: width, open: base + index)
            }
            return runEnd
        case 60 where isTagStart(at: index, in: storage):
            if let head = tagHead(at: index, in: storage) {
                let atBlockStart = index == ctx.contentIndex && ctx.contentIndent <= 3
                inline.tag = MathTagScanState(
                    open: base + index,
                    head: head,
                    openedAtBlockStart: atBlockStart
                )
            }
            return index + 1
        case 123 where fileKind == .mdx:
            inline.expression = MathExpressionScanState(open: base + index, lexical: JSLexicalState())
            return index + 1
        default:
            return index + 1
        }
    }

    /// Inside a pending code/math span everything is literal except delimiter
    /// runs of the matching class — preview-consistent for spans that close
    /// on a later line (`\`code\nmore\``, `$a\nb$`).
    private mutating func scanPendingDelimiter(
        in storage: NSString, at index: Int, pending: MathInlineScanState.Pending,
        base: Int, state inline: inout MathInlineScanState
    ) -> Int {
        // A cell-bounded row can still be carrying a span that the closer
        // search allowed up to a pipe. The pipe ends that cell. Escape parity
        // matches `pipeIsEscaped` / `tableCells`.
        if inline.cellBounded, storage.character(at: index) == 124, !isEscaped(index, in: storage) {
            inline.pending = nil
            return index
        }
        switch pending {
        case let .code(ticks, open):
            guard storage.character(at: index) == 96 else { return index + 1 }
            let runEnd = backtickRunEnd(in: storage, from: index)
            if runEnd - index == ticks {
                excludedZones.append(NSRange(location: open, length: base + runEnd - open))
                inline.pending = nil
            }
            return runEnd
        case let .math(width, open):
            guard storage.character(at: index) == 36 else { return index + 1 }
            var runEnd = index
            while runEnd < storage.length, storage.character(at: runEnd) == 36 {
                runEnd += 1
            }
            // Inline math closes only on an equal-length run. Flow `$$` blocks
            // keep their own "at least as long as the opener" rule.
            let closes = runEnd - index == width
            if closes {
                mathZones.append((
                    outer: NSRange(location: open, length: base + runEnd - open),
                    inner: NSRange(location: open + width, length: base + index - open - width),
                    endInclusive: false
                ))
                inline.pending = nil
            }
            return runEnd
        }
    }

    // MARK: - tag interior

    private mutating func scanTagContent(
        in storage: NSString, at index: Int, tag: MathTagScanState, base: Int,
        events: inout [MathTagEvent]
    ) -> (Int, MathTagScanState?) {
        var tag = tag
        if var expression = tag.attributeExpression {
            let (next, finished) = expression.advance(in: storage, at: index)
            tag.attributeExpression = finished ? nil : expression
            return (next, tag)
        }
        let unit = storage.character(at: index)
        if let quote = tag.quote {
            if unit == 92 { return (index + 2, tag) }
            if unit == quote { tag.quote = nil }
            return (index + 1, tag)
        }
        switch unit {
        case 62:
            emitTag(tag, closeEnd: base + index + 1, events: &events)
            return (index + 1, nil)
        case 34, 39:
            tag.quote = unit
        case 123:
            tag.attributeExpression = JSLexicalState()
        default:
            break
        }
        return (index + 1, tag)
    }

    private mutating func emitTag(
        _ tag: MathTagScanState, closeEnd: Int, events: inout [MathTagEvent]
    ) {
        let range = NSRange(location: tag.open, length: closeEnd - tag.open)
        excludedZones.append(range)
        // HTML void-element inference is a CommonMark rule. MDX names are
        // JSX — an uppercase or namespaced name is a component, and even a
        // lowercase intrinsic with a closing tag has a body.
        let isSelfContained = tag.head.isStandalone ||
            tagClosesItself(in: range) ||
            (fileKind == .markdown && Self.voidTags.contains(tag.head.name))
        events.append(MathTagEvent(
            head: tag.head,
            isSelfContained: isSelfContained,
            range: range,
            openedAtBlockStart: tag.openedAtBlockStart
        ))
    }

    /// Whether the tag text ends in `/>` (before its closing `>`).
    private func tagClosesItself(in range: NSRange) -> Bool {
        let storage = text as NSString
        var index = range.location + range.length - 2
        while index > range.location {
            let unit = storage.character(at: index)
            if unit == 32 || unit == 9 { index -= 1; continue }
            return unit == 47
        }
        return false
    }

    // MARK: - expression content

    private mutating func scanExpressionContent(
        in storage: NSString, at index: Int, expression: MathExpressionScanState, base: Int
    ) -> (Int, MathExpressionScanState?) {
        var expression = expression
        let (next, finished) = expression.lexical.advance(in: storage, at: index)
        if finished {
            excludedZones.append(NSRange(location: expression.open, length: base + next - expression.open))
            return (next, nil)
        }
        return (next, expression)
    }

    // MARK: - character helpers

    private func backtickRunEnd(in storage: NSString, from start: Int) -> Int {
        var index = start
        while index < storage.length, storage.character(at: index) == 96 {
            index += 1
        }
        return index
    }

    func isEscaped(_ index: Int, in storage: NSString) -> Bool {
        var backslashes = 0
        var probe = index
        while probe > 0, storage.character(at: probe - 1) == 92 {
            backslashes += 1
            probe -= 1
        }
        return Self.pipeIsEscaped(backslashCount: backslashes)
    }
}

/// Letters above ASCII. Surrogate pairs are not identifiers; JSX names the
/// preview accepts here (`É`, CJK) are in the BMP.
func isUnicodeLetter(_ unit: unichar) -> Bool {
    guard unit > 127, let scalar = Unicode.Scalar(unit) else { return false }
    return CharacterSet.letters.contains(scalar)
}
