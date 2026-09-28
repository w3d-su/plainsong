import Foundation

/// Blockquote / list-item containers a line sits inside. Only what the math
/// zone scan needs: blockquotes strip a `>` marker per line, list items keep
/// their content column so continuation lines and nested containers resolve.
enum MathLineContainer: Equatable {
    case quote
    /// Absolute column where the item's content begins. Tabs advance to the
    /// next stop every 4 columns; this is not a UTF-16 offset.
    case list(contentColumn: Int)
}

/// Where a line's markdown content begins after container prefixes. Inline
/// scans, fence/`$$` detection, and indented-code checks all operate on the
/// stripped content so constructs inside quotes and lists match the preview.
struct MathLineContext {
    /// UTF-16 offset in `line.text` where block-level content begins, after
    /// container markers and before any remaining indent whitespace.
    let contentStart: Int
    /// Matched container count; block constructs opened inside containers
    /// abort when a line matches fewer containers than this depth.
    let containerDepth: Int
    /// Column width of the content's own indent, measured from the container
    /// edge. A tab advances to the next multiple of 4. This is not a UTF-16
    /// length — use `contentIndex` to address source text.
    let contentIndent: Int
    /// UTF-16 offset of the first non-whitespace content character, or the
    /// line length when the stripped content is whitespace-only.
    let contentIndex: Int
    let isBlank: Bool
    /// The line continues an open paragraph lazily (a quote's `>` is
    /// missing). CommonMark never reads such a line as a setext underline.
    var isLazyContinuation = false

    /// Column of the first non-whitespace content character, or nil when the
    /// stripped content is whitespace-only.
    func firstNonWhitespace(in text: NSString) -> Int? {
        contentIndex < text.length ? contentIndex : nil
    }
}

/// Tracks the open container stack while scanning lines top to bottom.
struct MathContainerResolver {
    private(set) var containers: [MathLineContainer] = []
    /// True when this resolve opened any new container — a quote, or a list
    /// item that is sibling/nested rather than a continuation. Either way the
    /// line starts a new leaf block, so inline delimiters must not pair
    /// across it.
    private(set) var didOpenContainer = false

    /// `paragraphDepth` is the previous line's paragraph container depth, or
    /// nil when the previous line was not a paragraph. A continuing paragraph
    /// constrains list markers: a `1.` or a non-empty bullet can interrupt,
    /// but `2.` or an empty marker is lazy paragraph content.
    mutating func resolve(
        _ line: MarkdownLine,
        openingContainers: Bool = true,
        paragraphDepth: Int? = nil
    ) -> MathLineContext {
        didOpenContainer = false
        let storage = line.text as NSString
        let rawBlank = MarkdownTextEditingSupport.isBlank(line.text)
        var cursor = Cursor()
        var matched = 0
        var lazyContinued = false
        let originalCount = containers.count

        // Phase 1: continue open containers, outermost first. A block quote
        // whose `>` is missing stays open when the line is a lazy paragraph
        // continuation, so a later `>` is the same quote rather than a new one.
        matchLoop: while matched < containers.count {
            switch containers[matched] {
            case .quote:
                if matchQuote(in: storage, cursor: &cursor) {
                    matched += 1
                } else if paragraphDepth == originalCount, !rawBlank,
                          !interruptsOpenParagraph(in: storage, at: cursor.index)
                {
                    lazyContinued = true
                    matched = containers.count
                    break matchLoop
                } else {
                    break matchLoop
                }
            case let .list(contentColumn):
                if rawBlank || reachColumn(contentColumn, in: storage, cursor: &cursor) {
                    matched += 1
                } else {
                    break matchLoop
                }
            }
        }
        if !lazyContinued {
            containers = Array(containers.prefix(matched))
        }
        let paragraphContinues = paragraphDepth == containers.count

        // Phase 2: a non-blank line may open deeper containers. Lexical
        // tag/expression continuations must not treat a raw `>` as a new quote.
        if !rawBlank, openingContainers, !lazyContinued {
            openContainers(in: storage, cursor: &cursor, mustInterrupt: paragraphContinues)
        }

        let contentStart = cursor.index
        let edge = cursor.edge
        consumeWhitespace(in: storage, cursor: &cursor)
        // `>` alone is blank inside the quote. The raw line is not.
        let contentBlank = cursor.index >= storage.length
        return MathLineContext(
            contentStart: contentStart,
            containerDepth: containers.count,
            contentIndent: cursor.column - edge,
            contentIndex: cursor.index,
            isBlank: contentBlank,
            isLazyContinuation: lazyContinued
        )
    }

    private struct Cursor {
        var index = 0
        var column = 0
        /// Column where the current container's content indent is measured.
        var edge = 0
    }

    private mutating func openContainers(
        in storage: NSString, cursor: inout Cursor, mustInterrupt: Bool
    ) {
        var first = true
        while true {
            let saved = cursor
            consumeWhitespace(in: storage, cursor: &cursor)
            let indent = cursor.column - saved.edge
            guard indent <= 3 else {
                cursor = saved
                return
            }
            guard cursor.index < storage.length else {
                cursor = saved
                return
            }
            if storage.character(at: cursor.index) == 62 {
                consumeCharacter(in: storage, cursor: &cursor)
                consumeQuoteSpace(in: storage, cursor: &cursor)
                containers.append(.quote)
                didOpenContainer = true
                first = false
                continue
            }
            // The interruption rule applies to the first marker only: once a
            // container opens, deeper markers live in a fresh leaf block.
            if openListItem(
                in: storage, cursor: &cursor, mustInterrupt: mustInterrupt && first
            ) {
                didOpenContainer = true
                first = false
                continue
            }
            cursor = saved
            return
        }
    }

    /// `>` plus at most one following column, after ≤ 3 columns of indent.
    private func matchQuote(in storage: NSString, cursor: inout Cursor) -> Bool {
        let saved = cursor
        consumeWhitespace(in: storage, cursor: &cursor)
        guard cursor.column - saved.edge <= 3,
              cursor.index < storage.length,
              storage.character(at: cursor.index) == 62
        else {
            cursor = saved
            return false
        }
        consumeCharacter(in: storage, cursor: &cursor)
        consumeQuoteSpace(in: storage, cursor: &cursor)
        return true
    }

    /// The optional column after `>` is exactly one. A tab wider than the
    /// remaining stop leaves its extra columns as content indent.
    private func consumeQuoteSpace(in storage: NSString, cursor: inout Cursor) {
        let markerColumn = cursor.column
        guard consumeColumns(1, in: storage, cursor: &cursor) else {
            cursor.edge = cursor.column
            return
        }
        cursor.edge = markerColumn + 1
    }

    /// Advance to `target` by consuming whitespace. A tab may cross the target;
    /// columns past it stay in `cursor.column` and count as content indent.
    private func reachColumn(
        _ target: Int,
        in storage: NSString,
        cursor: inout Cursor
    ) -> Bool {
        cursor.edge = target
        if cursor.column >= target { return true }
        let saved = cursor
        guard consumeColumns(target - cursor.column, in: storage, cursor: &cursor) else {
            cursor = saved
            return false
        }
        cursor.edge = target
        return true
    }

    /// `-`/`*`/`+` or `N.`/`N)` followed by whitespace or end of line. The
    /// content column follows CommonMark: marker width plus 1…4 columns, or
    /// marker width plus 1 when the gap is wider. When `mustInterrupt` the
    /// marker would break a paragraph, so only a non-empty item — and, for an
    /// ordered list, one starting at 1 — counts as a list.
    private mutating func openListItem(
        in storage: NSString, cursor: inout Cursor, mustInterrupt: Bool
    ) -> Bool {
        let markerStart = cursor.index
        guard markerStart < storage.length else { return false }
        var markerEnd = markerStart
        var orderedValue = 0
        var isOrdered = false
        let unit = storage.character(at: markerStart)
        if unit == 45 || unit == 42 || unit == 43 {
            markerEnd = markerStart + 1
        } else if unit >= 48, unit <= 57 {
            isOrdered = true
            var digits = markerStart
            var count = 0
            while digits < storage.length, count < 10,
                  storage.character(at: digits) >= 48, storage.character(at: digits) <= 57
            {
                orderedValue = orderedValue * 10 + Int(storage.character(at: digits) - 48)
                digits += 1
                count += 1
            }
            guard digits < storage.length, count <= 9,
                  storage.character(at: digits) == 46 || storage.character(at: digits) == 41
            else { return false }
            markerEnd = digits + 1
        } else {
            return false
        }

        let markerWidth = markerEnd - markerStart
        cursor.index = markerEnd
        cursor.column += markerWidth
        let markerColumn = cursor.column
        let gap = peekWhitespaceColumns(in: storage, from: cursor)
        guard gap > 0 || markerEnd >= storage.length else { return false }
        let prefix = gap <= 4 ? gap : 1
        _ = consumeColumns(prefix, in: storage, cursor: &cursor)
        cursor.edge = markerColumn + prefix
        if mustInterrupt {
            // A wider gap only consumes one column, so leftover spaces are
            // not item content. An empty item cannot interrupt a paragraph.
            guard hasNonWhitespace(in: storage, from: cursor.index),
                  !isOrdered || orderedValue == 1
            else { return false }
        }
        containers.append(.list(contentColumn: cursor.edge))
        return true
    }

    /// A line that would end the open paragraph, so a missing quote marker
    /// really closes the quote instead of lazy-continuing it.
    private func interruptsOpenParagraph(in storage: NSString, at index: Int) -> Bool {
        var cursor = Cursor()
        cursor.index = index
        let edge = cursor.column
        consumeWhitespace(in: storage, cursor: &cursor)
        if cursor.column - edge >= 4 || cursor.index >= storage.length { return false }
        if isParagraphEndingMarker(in: storage, at: cursor.index) { return true }
        return startsListItem(in: storage, at: cursor.index)
    }

    /// Block openers that can interrupt a paragraph from a lazy line. A setext
    /// underline cannot be lazy, so `=` and short `-` runs stay paragraph
    /// text; only a real thematic break (three or more) ends the quote.
    private func isParagraphEndingMarker(in storage: NSString, at index: Int) -> Bool {
        let unit = storage.character(at: index)
        if unit == 35 || unit == 96 || unit == 126 {
            var end = index
            while end < storage.length, storage.character(at: end) == unit {
                end += 1
            }
            let run = end - index
            if unit == 35 {
                guard run >= 1, run <= 6 else { return false }
                if end >= storage.length { return true }
                let after = storage.character(at: end)
                return after == 32 || after == 9
            }
            guard run >= 3 else { return false }
            // A backtick fence's info string cannot contain a backtick.
            return unit == 126 || !storage.substring(from: end).contains("`")
        }
        let rest = storage.substring(from: index)
        let compact = rest.filter { $0 != " " && $0 != "\t" }
        guard let marker = compact.first, compact.allSatisfy({ $0 == marker }) else { return false }
        switch marker {
        case "-", "*", "_": return compact.count >= 3
        default: return false
        }
    }

    /// Any list marker followed by whitespace or the line end. A lazy line is
    /// read outside the quote, where the paragraph-interruption limits (empty
    /// items, ordered starts other than 1) do not apply: `-` or `2. x` there
    /// opens a list and closes the quote, matching the preview's parser.
    private func startsListItem(in storage: NSString, at index: Int) -> Bool {
        let unit = storage.character(at: index)
        var markerEnd = index
        if unit == 45 || unit == 42 || unit == 43 {
            markerEnd = index + 1
        } else if unit >= 48, unit <= 57 {
            var digits = index
            var count = 0
            while digits < storage.length, count < 9,
                  storage.character(at: digits) >= 48, storage.character(at: digits) <= 57
            {
                digits += 1
                count += 1
            }
            guard digits < storage.length,
                  storage.character(at: digits) == 46 || storage.character(at: digits) == 41
            else { return false }
            markerEnd = digits + 1
        } else {
            return false
        }
        var cursor = Cursor()
        cursor.index = markerEnd
        let gap = peekWhitespaceColumns(in: storage, from: cursor)
        return gap > 0 || markerEnd >= storage.length
    }

    private func hasNonWhitespace(in storage: NSString, from index: Int) -> Bool {
        var cursor = index
        while cursor < storage.length {
            let unit = storage.character(at: cursor)
            if unit != 32, unit != 9 { return true }
            cursor += 1
        }
        return false
    }

    private func consumeWhitespace(in storage: NSString, cursor: inout Cursor) {
        while cursor.index < storage.length {
            let unit = storage.character(at: cursor.index)
            if unit == 32 {
                consumeCharacter(in: storage, cursor: &cursor)
            } else if unit == 9 {
                consumeTab(in: storage, cursor: &cursor)
            } else {
                return
            }
        }
    }

    /// Consume `count` columns of whitespace. Returns false if a non-whitespace
    /// character is hit first. A tab that crosses the count is still consumed.
    private func consumeColumns(
        _ count: Int,
        in storage: NSString,
        cursor: inout Cursor
    ) -> Bool {
        var remaining = count
        while remaining > 0 {
            guard cursor.index < storage.length else { return false }
            let unit = storage.character(at: cursor.index)
            if unit == 32 {
                consumeCharacter(in: storage, cursor: &cursor)
                remaining -= 1
            } else if unit == 9 {
                let width = tabWidth(at: cursor.column)
                consumeTab(in: storage, cursor: &cursor)
                remaining = max(0, remaining - width)
            } else {
                return false
            }
        }
        return true
    }

    private func peekWhitespaceColumns(in storage: NSString, from cursor: Cursor) -> Int {
        var probe = cursor
        let start = probe.column
        consumeWhitespace(in: storage, cursor: &probe)
        return probe.column - start
    }

    private func consumeCharacter(in storage: NSString, cursor: inout Cursor) {
        guard cursor.index < storage.length else { return }
        cursor.index += 1
        cursor.column += 1
    }

    private func consumeTab(in storage: NSString, cursor: inout Cursor) {
        guard cursor.index < storage.length else { return }
        cursor.column += tabWidth(at: cursor.column)
        cursor.index += 1
    }

    private func tabWidth(at column: Int) -> Int {
        4 - (column % 4)
    }
}
