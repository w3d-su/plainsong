import Foundation

/// The `MathZones` scanner: a line-wise state machine over container-aware
/// lines (frontmatter, fenced code, `$$` blocks, indented code, `.md` HTML
/// blocks) plus persistent inline spans (code, tags, `$`/`$$` pairs, MDX
/// `{…}` expressions) delegated to `MathZoneInlineScan`.
extension MathZones {
    enum ScanBlock {
        case normal
        case fence(MathFence)
        case displayMath(openLocation: Int, contentStart: Int, openRunLength: Int, depth: Int)
        case indentedCode(start: Int, depth: Int, lastLineEnd: Int)
        case htmlBlock(start: Int, end: MathHtmlBlockEnd, depth: Int)
    }

    enum MathHtmlBlockEnd {
        case blank
        case marker(String)
    }

    mutating func scan(fileKind: FileKind) {
        let storage = text as NSString
        delimiterHorizons.removeAll()
        var cursor = 0
        if let frontmatter = frontmatterZone() {
            excludedBlockZones.append(frontmatter.excluded)
            cursor = frontmatter.resume
        }

        var resolver = MathContainerResolver()
        var inline = MathInlineScanState()
        var block = ScanBlock.normal
        var previous = ParagraphScanState(wasParagraph: false, paragraphDepth: 0)
        var previousLineEnd = cursor

        // `<= length` rescans the last line when the document has no trailing
        // newline (`line(containing: EOF)` walks back to that line). One pass.
        while cursor < storage.length {
            let line = MarkdownTextEditingSupport.line(containing: cursor, in: text)
            defer {
                previousLineEnd = line.endLocation
                cursor = line.fullEndLocation > cursor ? line.fullEndLocation : storage.length + 1
            }
            previous = scanFreeLine(
                line,
                fileKind: fileKind,
                resolver: &resolver,
                inline: &inline,
                block: &block,
                previous: previous,
                previousLineEnd: previousLineEnd
            )
        }

        flushOpenZones(block: block, inline: inline, documentEnd: storage.length)
    }

    struct ParagraphScanState {
        var wasParagraph: Bool
        var paragraphDepth: Int
        /// Container-stripped text of a paragraph line: the header candidate
        /// for a GFM delimiter row on the next line.
        var content: String?
        /// Set on the delimiter row and carried through body rows. Nil ends
        /// the table. The count is the header width; body rows may differ.
        var tableColumns: Int?
        var tableDepth: Int?
    }

    /// One line that is not inside an already-open fence, display-math, indented
    /// code, or HTML block. Returns the paragraph flag for the following line.
    mutating func scanFreeLine(
        _ line: MarkdownLine,
        fileKind: FileKind,
        resolver: inout MathContainerResolver,
        inline: inout MathInlineScanState,
        block: inout ScanBlock,
        previous: ParagraphScanState,
        previousLineEnd: Int
    ) -> ParagraphScanState {
        let wasParagraph = previous.wasParagraph
        let paragraphDepth = previous.paragraphDepth
        let continuingLexical = inline.tag != nil || inline.expression != nil
        let ctx = resolver.resolve(
            line,
            openingContainers: !continuingLexical,
            paragraphDepth: wasParagraph ? paragraphDepth : nil
        )
        if consumeBlockLine(
            line, context: ctx, block: &block, previousLineEnd: previousLineEnd
        ) {
            return ParagraphScanState(wasParagraph: wasParagraph, paragraphDepth: paragraphDepth)
        }
        // A heading's inline content cannot continue, and a line that opens a
        // new container — a quote or a sibling/nested list item — is a new
        // leaf block, not the previous paragraph. Lazy and indented
        // continuations open nothing, so their delimiters still pair.
        if !wasParagraph || resolver.didOpenContainer {
            inline.resetDelimiters()
        }
        if continuingLexical {
            let events = scanInline(
                line, context: ctx, fileKind: fileKind, resolver: resolver, state: &inline
            )
            if fileKind == .mdx {
                applyContainerEvents(events, in: line, context: ctx)
            }
            return ParagraphScanState(wasParagraph: false, paragraphDepth: paragraphDepth)
        }
        if ctx.isBlank {
            inline.resetDelimiters()
            return ParagraphScanState(wasParagraph: false, paragraphDepth: paragraphDepth)
        }

        let paragraphContinues = wasParagraph && ctx.containerDepth == paragraphDepth
        if ctx.contentIndent >= 4, !paragraphContinues {
            block = .indentedCode(
                start: line.range.location, depth: ctx.containerDepth, lastLineEnd: line.endLocation
            )
            inline.resetDelimiters()
            return ParagraphScanState(wasParagraph: false, paragraphDepth: paragraphDepth)
        }
        if let fence = fenceOpening(in: line, context: ctx) {
            block = .fence(fence)
            inline.resetDelimiters()
            return ParagraphScanState(wasParagraph: false, paragraphDepth: paragraphDepth)
        }
        if let open = mathFlowOpen(in: line, context: ctx) {
            block = .displayMath(
                openLocation: open.location, contentStart: open.contentStart,
                openRunLength: open.runLength, depth: ctx.containerDepth
            )
            inline.resetDelimiters()
            return ParagraphScanState(wasParagraph: false, paragraphDepth: paragraphDepth)
        }
        if beginHTMLBlockIfNeeded(
            line, context: ctx, fileKind: fileKind, block: &block,
            paragraphContinues: paragraphContinues, inline: &inline
        ) {
            return ParagraphScanState(wasParagraph: false, paragraphDepth: paragraphDepth)
        }

        return finishParagraphLine(
            line, context: ctx, fileKind: fileKind, resolver: resolver,
            inline: &inline, previous: previous
        )
    }

    /// Marker HTML blocks that close on the opening line exclude only that line.
    mutating func beginHTMLBlockIfNeeded(
        _ line: MarkdownLine,
        context ctx: MathLineContext,
        fileKind: FileKind,
        block: inout ScanBlock,
        paragraphContinues: Bool,
        inline: inout MathInlineScanState
    ) -> Bool {
        guard fileKind == .markdown,
              let head = lineStartTagHead(in: line, context: ctx),
              let end = htmlBlockEnd(
                  for: head, in: line, context: ctx, canInterrupt: !paragraphContinues
              )
        else { return false }

        if case let .marker(marker) = end, containsHTMLMarker(marker, in: line, context: ctx) {
            excludedBlockZones.append(NSRange(
                location: line.range.location,
                length: line.endLocation - line.range.location
            ))
        } else {
            block = .htmlBlock(start: line.range.location, end: end, depth: ctx.containerDepth)
        }
        inline.resetDelimiters()
        return true
    }

    // MARK: - block-state lines

    /// Returns true when the line is consumed by an open block construct.
    mutating func consumeBlockLine(
        _ line: MarkdownLine, context ctx: MathLineContext,
        block: inout ScanBlock, previousLineEnd: Int
    ) -> Bool {
        switch block {
        case .normal:
            return false
        case let .fence(fence):
            if ctx.containerDepth < fence.depth {
                appendZone(
                    openLocation: fence.openLocation, innerStart: fence.contentStart,
                    outerEnd: previousLineEnd, innerEnd: previousLineEnd,
                    isMath: fence.isMath, endInclusive: true
                )
                block = .normal
                return false
            }
            if isFenceClose(in: line, context: ctx, fence: fence) {
                closeBlockZone(
                    openLocation: fence.openLocation, innerStart: fence.contentStart,
                    closingLine: line, isMath: fence.isMath
                )
                block = .normal
            }
            return true
        case let .displayMath(openLocation, contentStart, openRunLength, depth):
            if ctx.containerDepth < depth {
                appendZone(
                    openLocation: openLocation, innerStart: contentStart,
                    outerEnd: previousLineEnd, innerEnd: previousLineEnd,
                    isMath: true, endInclusive: true
                )
                block = .normal
                return false
            }
            if isMathDelimiterClose(in: line, context: ctx, minimumRun: openRunLength) {
                closeBlockZone(
                    openLocation: openLocation, innerStart: contentStart,
                    closingLine: line, isMath: true
                )
                block = .normal
            }
            return true
        case let .indentedCode(start, depth, lastLineEnd):
            if ctx.isBlank { return true }
            if ctx.containerDepth < depth || ctx.contentIndent < 4 {
                excludedBlockZones.append(NSRange(location: start, length: lastLineEnd - start))
                block = .normal
                return false
            }
            block = .indentedCode(start: start, depth: depth, lastLineEnd: line.endLocation)
            return true
        case let .htmlBlock(start, end, depth):
            if ctx.containerDepth < depth {
                excludedBlockZones.append(NSRange(location: start, length: previousLineEnd - start))
                block = .normal
                return false
            }
            switch end {
            case .blank:
                if ctx.isBlank {
                    excludedBlockZones.append(NSRange(location: start, length: previousLineEnd - start))
                    block = .normal
                    return false
                }
            case let .marker(marker):
                if containsHTMLMarker(marker, in: line, context: ctx) {
                    excludedBlockZones.append(NSRange(
                        location: start, length: line.endLocation - start
                    ))
                    block = .normal
                }
            }
            return true
        }
    }

    // MARK: - flush

    mutating func flushOpenZones(
        block: ScanBlock, inline: MathInlineScanState, documentEnd end: Int
    ) {
        // Unclosed constructs run to EOF, matching CommonMark/micromark.
        switch block {
        case .normal:
            break
        case let .fence(fence):
            appendZone(
                openLocation: fence.openLocation, innerStart: fence.contentStart,
                outerEnd: end, innerEnd: end, isMath: fence.isMath, endInclusive: true
            )
        case let .displayMath(openLocation, contentStart, _, _):
            appendZone(
                openLocation: openLocation, innerStart: contentStart,
                outerEnd: end, innerEnd: end, isMath: true, endInclusive: true
            )
        case let .indentedCode(start, _, lastLineEnd):
            excludedBlockZones.append(NSRange(location: start, length: lastLineEnd - start))
        case let .htmlBlock(start, _, _):
            excludedBlockZones.append(NSRange(location: start, length: end - start))
        }
        if let tag = inline.tag {
            excludedBlockZones.append(NSRange(location: tag.open, length: end - tag.open))
        }
        if let expression = inline.expression {
            excludedBlockZones.append(NSRange(location: expression.open, length: end - expression.open))
        }
        for container in containerStack {
            containerZones.append(
                NSRange(location: container.openLocation, length: end - container.openLocation)
            )
        }
    }

    mutating func closeBlockZone(
        openLocation: Int,
        innerStart: Int,
        closingLine: MarkdownLine,
        isMath: Bool
    ) {
        appendZone(
            openLocation: openLocation,
            innerStart: innerStart,
            outerEnd: closingLine.endLocation,
            innerEnd: closingLine.range.location - terminatorWidth(before: closingLine.range.location),
            isMath: isMath,
            endInclusive: true
        )
    }

    mutating func appendZone(
        openLocation: Int,
        innerStart: Int,
        outerEnd: Int,
        innerEnd: Int,
        isMath: Bool,
        endInclusive: Bool
    ) {
        let outer = NSRange(location: openLocation, length: outerEnd - openLocation)
        let inner = NSRange(location: innerStart, length: max(0, innerEnd - innerStart))
        if isMath {
            mathZones.append((outer: outer, inner: inner, endInclusive: endInclusive))
        } else {
            excludedBlockZones.append(outer)
        }
    }

    func terminatorWidth(before location: Int) -> Int {
        let storage = text as NSString
        guard location > 0 else { return 0 }
        if storage.character(at: location - 1) == 10 {
            return location >= 2 && storage.character(at: location - 2) == 13 ? 2 : 1
        }
        return storage.character(at: location - 1) == 13 ? 1 : 0
    }

    /// A closed frontmatter block at document start; an unclosed `---` is a
    /// thematic break, not frontmatter, so it excludes nothing.
    ///
    /// `excluded` stops at the closing line's content end so a caret on the
    /// following body line is outside the zone. `resume` skips the closing
    /// newline and is not part of the exclusion.
    func frontmatterZone() -> (excluded: NSRange, resume: Int)? {
        let storage = text as NSString
        let first = MarkdownTextEditingSupport.line(containing: 0, in: text)
        guard MarkdownTextEditingSupport.trimSpaces(first.text) == "---" else { return nil }

        var cursor = first.fullEndLocation
        while cursor < storage.length {
            let line = MarkdownTextEditingSupport.line(containing: cursor, in: text)
            let trimmed = MarkdownTextEditingSupport.trimSpaces(line.text)
            if trimmed == "---" || trimmed == "..." {
                return (
                    excluded: NSRange(location: 0, length: line.endLocation),
                    resume: line.fullEndLocation
                )
            }
            guard line.fullEndLocation > cursor else { return nil }
            cursor = line.fullEndLocation
        }
        return nil
    }

    func containsHTMLMarker(
        _ marker: String,
        in line: MarkdownLine,
        context ctx: MathLineContext
    ) -> Bool {
        strippedContent(in: line, context: ctx).range(
            of: marker,
            options: [.caseInsensitive]
        ) != nil
    }

    func strippedContent(in line: MarkdownLine, context ctx: MathLineContext) -> String {
        (line.text as NSString).substring(from: ctx.contentStart)
    }
}
