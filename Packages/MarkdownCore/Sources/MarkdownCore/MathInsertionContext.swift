import Foundation

/// Outcome of the conservative context guard for the math insertion commands.
enum MathInsertionVerdict: Equatable {
    /// Insertion may proceed.
    case allowed
    /// The context cannot safely take a new formula; the command is a no-op.
    case refused
    /// The selection is already inside a formula; the command selects `inner`.
    case existingFormula(inner: NSRange)
}

/// Conservative, line-level guard for Format ▸ Insert Inline Math / Insert Display Math.
///
/// It runs only when a command is invoked (never per keystroke or selection change)
/// and looks at UTF-16 lines, not a parse tree. Rules:
/// 1. Refuse when the selection touches YAML frontmatter (`---` at offset 0 through the
///    next `---` / `...` line; an unclosed opener is not frontmatter).
/// 2. Refuse inside fenced code (``` or ~~~, closing fence of the same character and at
///    least the opener's length, up to three spaces of indent). A `math` fence and a
///    `$$` block are formulas instead: a selection inside them selects the inner lines.
/// 3. Refuse inside (or partially overlapping) an inline code span on the selected lines.
/// 4. A `$…$` / `$$…$$` span paired on one line (ignoring `\$`) is an existing formula.
/// 5. MDX only: refuse on selected lines that start with `import ` or `export `.
/// 6. Display math also refuses a selected line that starts (after ≤3 spaces) with `>`,
///    `#`, `|` or a list marker, and a selection that spans more than one paragraph.
///
/// Known limitations, accepted: MDX `{…}` expressions and JSX are not detected;
/// blockquote/list/table containers, indented code, HTML blocks, and setext headings
/// are only approximated by the line-prefix checks in rule 6; formulas spanning
/// several lines other than `$$` blocks and math fences are not recognised. The
/// edit is one Undo away and the preview reports formula errors.
enum MathInsertionContext {
    static func evaluate(
        in text: String,
        selection: NSRange,
        fileKind: FileKind,
        display: Bool
    ) -> MathInsertionVerdict {
        let selection = MarkdownTextEditingSupport.clamped(selection, to: text)
        let start = selection.location
        let end = NSMaxRange(selection)

        if let verdict = blockVerdict(in: text, start: start, end: end) { return verdict }

        let lines = selectedLines(in: text, from: start, end: end)
        if fileKind == .mdx, lines.contains(where: isMDXModuleLine) { return .refused }
        for line in lines {
            if let verdict = inlineVerdict(in: line, selection: selection) { return verdict }
        }
        if display, !allowsDisplayMath(on: lines) { return .refused }
        return .allowed
    }

    // MARK: - Lines

    private static func nextLine(after line: MarkdownLine, in text: String) -> MarkdownLine? {
        guard line.fullEndLocation > line.endLocation else { return nil }
        return MarkdownTextEditingSupport.line(containing: line.fullEndLocation, in: text)
    }

    /// Lines the selection overlaps; a selection ending exactly at a line start
    /// does not include that following line.
    private static func selectedLines(in text: String, from start: Int, end: Int) -> [MarkdownLine] {
        let first = MarkdownTextEditingSupport.line(containing: start, in: text)
        var lines = [first]
        var cursor = first
        while cursor.endLocation < end, let next = nextLine(after: cursor, in: text), next.range.location < end {
            lines.append(next)
            cursor = next
        }
        return lines
    }

    private static func isMDXModuleLine(_ line: MarkdownLine) -> Bool {
        line.text.hasPrefix("import ") || line.text.hasPrefix("export ")
    }

    // MARK: - Frontmatter, fences, and `$$` blocks

    private enum OpenRegionKind {
        case fence(marker: unichar, length: Int)
        case dollarBlock
    }

    private struct OpenRegion {
        let kind: OpenRegionKind
        let isFormula: Bool
        let start: Int
        let innerStart: Int
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func blockVerdict(in text: String, start: Int, end: Int) -> MathInsertionVerdict? {
        var next: MarkdownLine? = MarkdownTextEditingSupport.line(containing: 0, in: text)
        if let first = next, isDelimiter(first.text, closing: false) {
            var probe = nextLine(after: first, in: text)
            while let candidate = probe {
                if isDelimiter(candidate.text, closing: true) {
                    if start <= candidate.endLocation { return .refused }
                    next = nextLine(after: candidate, in: text)
                    break
                }
                probe = nextLine(after: candidate, in: text)
            }
        }

        var openRegion: OpenRegion?
        var previousContentEnd = 0
        while let line = next {
            if let region = openRegion {
                if closes(region, line: line) {
                    let outer = NSRange(location: region.start, length: line.endLocation - region.start)
                    let inner = NSRange(
                        location: region.innerStart,
                        length: max(0, previousContentEnd - region.innerStart)
                    )
                    if start <= NSMaxRange(outer), end >= outer.location {
                        let contained = start >= outer.location && end <= NSMaxRange(outer)
                        return contained && region.isFormula ? .existingFormula(inner: inner) : .refused
                    }
                    openRegion = nil
                } else {
                    previousContentEnd = line.endLocation
                }
            } else {
                if line.range.location > end { return nil }
                if let opened = opener(for: line) {
                    openRegion = opened
                    previousContentEnd = line.fullEndLocation
                }
            }
            next = nextLine(after: line, in: text)
        }
        // An unclosed fence or `$$` block runs to the end of the document.
        if let region = openRegion, end >= region.start { return .refused }
        return nil
    }

    private static func isDelimiter(_ line: String, closing: Bool) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "---" || (closing && trimmed == "...")
    }

    private static func opener(for line: MarkdownLine) -> OpenRegion? {
        let units = Array(line.text.utf16)
        let indent = leadingSpaces(units)
        guard indent <= 3, indent < units.count else { return nil }
        let marker = units[indent]
        let start = line.range.location
        if marker == backtick || marker == tilde {
            let run = runLength(units, at: indent, of: marker)
            guard run >= 3 else { return nil }
            let info = String(decoding: units[(indent + run)...], as: UTF16.self)
                .trimmingCharacters(in: .whitespaces)
            if marker == backtick, info.contains("`") { return nil }
            let word = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map { String($0) } ?? ""
            return OpenRegion(
                kind: .fence(marker: marker, length: run),
                isFormula: word.lowercased() == "math",
                start: start,
                innerStart: line.fullEndLocation
            )
        }
        if isDollarBlockLine(units) {
            return OpenRegion(kind: .dollarBlock, isFormula: true, start: start, innerStart: line.fullEndLocation)
        }
        return nil
    }

    private static func closes(_ region: OpenRegion, line: MarkdownLine) -> Bool {
        let units = Array(line.text.utf16)
        switch region.kind {
        case .dollarBlock:
            return isDollarBlockLine(units)
        case let .fence(marker, length):
            let indent = leadingSpaces(units)
            guard indent <= 3, indent < units.count, units[indent] == marker else { return false }
            let run = runLength(units, at: indent, of: marker)
            guard run >= length else { return false }
            return units[(indent + run)...].allSatisfy { $0 == 32 || $0 == 9 }
        }
    }

    private static func isDollarBlockLine(_ units: [unichar]) -> Bool {
        let indent = leadingSpaces(units)
        guard indent <= 3 else { return false }
        return String(decoding: units[indent...], as: UTF16.self).trimmingCharacters(in: .whitespaces) == "$$"
    }

    // MARK: - Inline code and `$…$` spans

    private static func inlineVerdict(in line: MarkdownLine, selection: NSRange) -> MathInsertionVerdict? {
        let units = Array(line.text.utf16)
        let base = line.range.location
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit == backslash {
                index += 2
                continue
            }
            guard unit == backtick || unit == dollar else {
                index += 1
                continue
            }
            let run = runLength(units, at: index, of: unit)
            guard let close = closingRun(in: units, from: index + run, length: run, of: unit),
                  close > index + run
            else {
                index += run
                continue
            }
            let outer = NSRange(location: base + index, length: close + run - index)
            let intersects = selection.length > 0
                ? selection.location < NSMaxRange(outer) && NSMaxRange(selection) > outer.location
                : selection.location > outer.location && selection.location < NSMaxRange(outer)
            if intersects {
                let contained = selection.location >= outer.location && NSMaxRange(selection) <= NSMaxRange(outer)
                guard unit == dollar, contained else { return .refused }
                let inner = NSRange(location: base + index + run, length: close - index - run)
                return .existingFormula(inner: inner)
            }
            index = close + run
        }
        return nil
    }

    private static func closingRun(in units: [unichar], from start: Int, length: Int, of marker: unichar) -> Int? {
        var index = start
        while index < units.count {
            if marker == dollar, units[index] == backslash {
                index += 2
            } else if units[index] == marker {
                let run = runLength(units, at: index, of: marker)
                if run == length { return index }
                index += run
            } else {
                index += 1
            }
        }
        return nil
    }

    // MARK: - Display math

    private static func allowsDisplayMath(on lines: [MarkdownLine]) -> Bool {
        var sawContent = false
        var sawGapAfterContent = false
        for line in lines {
            if MarkdownTextEditingSupport.isBlank(line.text) {
                if sawContent { sawGapAfterContent = true }
                continue
            }
            if sawGapAfterContent || startsBlockConstruct(line.text) { return false }
            sawContent = true
        }
        return true
    }

    private static func startsBlockConstruct(_ line: String) -> Bool {
        let units = Array(line.utf16)
        let indent = leadingSpaces(units)
        guard indent <= 3, indent < units.count else { return false }
        let first = units[indent]
        if first == 0x3E || first == 0x23 || first == 0x7C { return true } // > # |
        if first == 0x2D || first == 0x2A || first == 0x2B { // - * +
            let next = indent + 1
            return next < units.count && (units[next] == 32 || units[next] == 9)
        }
        var digits = 0
        while indent + digits < units.count, (0x30 ... 0x39).contains(units[indent + digits]) {
            digits += 1
        }
        let after = indent + digits
        guard digits > 0, digits <= 9, after + 1 < units.count else { return false }
        return (units[after] == 0x2E || units[after] == 0x29) && (units[after + 1] == 32 || units[after + 1] == 9)
    }

    // MARK: - Helpers

    private static func leadingSpaces(_ units: [unichar]) -> Int {
        var count = 0
        while count < units.count, units[count] == 32 {
            count += 1
        }
        return count
    }

    private static func runLength(_ units: [unichar], at index: Int, of marker: unichar) -> Int {
        var length = 0
        while index + length < units.count, units[index + length] == marker {
            length += 1
        }
        return length
    }

    private static let backtick: unichar = 0x60
    private static let tilde: unichar = 0x7E
    private static let dollar: unichar = 0x24
    private static let backslash: unichar = 0x5C
}
