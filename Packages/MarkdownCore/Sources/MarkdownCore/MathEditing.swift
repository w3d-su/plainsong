import Foundation

/// Pure logic for Format ▸ Insert Inline Math / Insert Display Math.
///
/// Context detection is line scanning over UTF-16 ranges — no parser — and the same
/// function backs command execution and any validation, so an invalid context is a
/// safe no-op (`nil`). Inside an existing formula the command never wraps again; it
/// selects the editable formula content instead (it is not a remove toggle).
enum MathEditing {
    static func insertInlineMath(in text: String, selection: NSRange, fileKind: FileKind) -> MarkdownEditResult? {
        let selection = MarkdownTextEditingSupport.clamped(selection, to: text)
        return insertInlineMath(
            in: text,
            selection: selection,
            zones: MathZones(text: text, fileKind: fileKind)
        )
    }

    static func insertDisplayMath(in text: String, selection: NSRange, fileKind: FileKind) -> MarkdownEditResult? {
        let selection = MarkdownTextEditingSupport.clamped(selection, to: text)
        return insertDisplayMath(
            in: text,
            selection: selection,
            zones: MathZones(text: text, fileKind: fileKind)
        )
    }

    /// Menu enablement evaluates both commands against one zone scan, so the
    /// eligibility answer is identical to what command execution computes.
    static func commandAvailability(
        in text: String,
        selection: NSRange,
        fileKind: FileKind
    ) -> MarkdownMathCommandAvailability {
        let selection = MarkdownTextEditingSupport.clamped(selection, to: text)
        let zones = MathZones(text: text, fileKind: fileKind)
        return MarkdownMathCommandAvailability(
            canInsertInlineMath: insertInlineMath(in: text, selection: selection, zones: zones) != nil,
            canInsertDisplayMath: insertDisplayMath(in: text, selection: selection, zones: zones) != nil
        )
    }

    private static func insertInlineMath(
        in text: String,
        selection: NSRange,
        zones: MathZones
    ) -> MarkdownEditResult? {
        if let inner = zones.editableMathInnerRange(containing: selection) {
            return selectionOnly(inner, at: selection.location)
        }
        guard !zones.blocksMathCommand(selection) else { return nil }
        // New delimiters must stand alone: an adjacent `$` would merge into a
        // `$$` run, and a preceding backslash escapes the opening `$`.
        guard !touchesDollarOrEscape(selection, in: text) else { return nil }

        guard selection.length > 0 else {
            return MarkdownTextEditingSupport.replacement(
                range: selection,
                string: "$x$",
                selection: NSRange(location: selection.location + 1, length: 1)
            )
        }

        // Inline math stays on one line; multi-line selections are a safe no-op.
        let selected = MarkdownTextEditingSupport.substring(selection, in: text)
        guard !selected.contains("\n"), !selected.contains("\r") else { return nil }
        // Math text has no backslash escapes: any `$` inside the selection
        // closes the formula early, and an odd trailing `\` run leaves `$…\$`
        // as a KaTeX error. Refuse rather than write something that is not a formula.
        guard !selected.contains("$"),
              !isEscaped(at: NSMaxRange(selection), in: text as NSString)
        else { return nil }

        return MarkdownTextEditingSupport.replacement(
            range: selection,
            string: "$\(selected)$",
            selection: NSRange(location: selection.location + 1, length: selection.length)
        )
    }

    private static func insertDisplayMath(
        in text: String,
        selection: NSRange,
        zones: MathZones
    ) -> MarkdownEditResult? {
        if let inner = zones.editableMathInnerRange(containing: selection) {
            return selectionOnly(inner, at: selection.location)
        }
        guard !zones.blocksDisplayMathCommand(selection) else { return nil }

        // On a blank line the block replaces the (possibly whitespace-only) line
        // content; anywhere else it inserts at the caret.
        let insertionRange: NSRange
        if selection.length == 0 {
            let line = MarkdownTextEditingSupport.line(containing: selection.location, in: text)
            insertionRange = MarkdownTextEditingSupport.isBlank(line.text) ? line.range : selection
        } else {
            insertionRange = selection
        }

        let selected = MarkdownTextEditingSupport.substring(selection, in: text)
        let trimmed = selected.trimmingCharacters(in: .newlines)
        let inner = trimmed.isEmpty ? "x" : trimmed
        let prefix = leadingParagraphBreaks(before: insertionRange.location, in: text)
        let suffix = trailingParagraphBreaks(
            after: insertionRange.location + insertionRange.length,
            in: text
        )
        let replacement = "\(prefix)$$\n\(inner)\n$$\(suffix)"
        let innerStart = insertionRange.location + MarkdownTextEditingSupport.utf16Length(prefix) + 3
        return MarkdownTextEditingSupport.replacement(
            range: insertionRange,
            string: replacement,
            selection: NSRange(
                location: innerStart,
                length: MarkdownTextEditingSupport.utf16Length(inner)
            )
        )
    }

    private static func touchesDollarOrEscape(_ range: NSRange, in text: String) -> Bool {
        let storage = text as NSString
        let end = NSMaxRange(range)
        if end < storage.length, storage.character(at: end) == dollar { return true }
        guard range.location > 0 else { return false }
        let previous = storage.character(at: range.location - 1)
        if previous == dollar { return !isEscaped(at: range.location - 1, in: storage) }
        return isEscaped(at: range.location, in: storage)
    }

    /// Odd run of backslashes immediately before `location`.
    private static func isEscaped(at location: Int, in storage: NSString) -> Bool {
        var count = 0
        var index = location
        while index > 0, storage.character(at: index - 1) == backslash {
            count += 1
            index -= 1
        }
        return count % 2 == 1
    }

    private static let dollar: unichar = 0x24
    private static let backslash: unichar = 0x5C

    private static func selectionOnly(_ selection: NSRange, at location: Int) -> MarkdownEditResult {
        MarkdownTextEditingSupport.replacement(
            range: NSRange(location: location, length: 0),
            string: "",
            selection: selection
        )
    }

    /// A $$ block needs a paragraph break on each side. Count the line terminators
    /// already adjacent (CRLF counts once) and supply only the missing ones.
    private static func leadingParagraphBreaks(before location: Int, in text: String) -> String {
        guard location > 0 else { return "" }
        switch lineBreakCount(before: location, in: text) {
        case 0: return "\n\n"
        case 1: return "\n"
        default: return ""
        }
    }

    private static func trailingParagraphBreaks(after location: Int, in text: String) -> String {
        let storage = text as NSString
        guard location < storage.length else { return "" }
        switch lineBreakCount(after: location, in: text) {
        case 0: return "\n\n"
        case 1: return "\n"
        default: return ""
        }
    }

    private static func lineBreakCount(before location: Int, in text: String) -> Int {
        let storage = text as NSString
        var count = 0
        var index = location
        while index > 0 {
            let unit = storage.character(at: index - 1)
            if unit == 10, index >= 2, storage.character(at: index - 2) == 13 {
                index -= 2
            } else if unit == 10 || unit == 13 {
                index -= 1
            } else {
                break
            }
            count += 1
        }
        return count
    }

    private static func lineBreakCount(after location: Int, in text: String) -> Int {
        let storage = text as NSString
        var count = 0
        var index = location
        while index < storage.length {
            let unit = storage.character(at: index)
            if unit == 13, index + 1 < storage.length, storage.character(at: index + 1) == 10 {
                index += 2
            } else if unit == 10 || unit == 13 {
                index += 1
            } else {
                break
            }
            count += 1
        }
        return count
    }
}
