import CoreGraphics
import Foundation

/// What the line-number gutter draws for the layout fragments it can see.
///
/// Pure: the gutter view collects fragments from TextKit and draws the labels. A label
/// costs one binary search in the shared `EditorScrollLineIndex`, so nothing here grows
/// with the document or with the text above the viewport.
enum EditorLineNumberGutterLayout {
    /// One visual line, in text view coordinates.
    struct Line: Equatable {
        var frame: CGRect
        /// The y of the line's text baseline; numbers sit on it.
        var baseline: CGFloat
    }

    /// One TextKit layout fragment (a paragraph), in text view coordinates.
    struct Fragment: Equatable {
        /// UTF-16 offset where the paragraph starts.
        var location: Int
        /// Its first visual line; wrapped continuation lines get no number.
        var firstLine: Line?
        /// All its visual lines except an extra line fragment: the band behind the
        /// current line number covers the whole wrapped paragraph.
        var bodyFrame: CGRect?
        /// TextKit's extra line fragment: the empty line after a final line break.
        var extraLine: Line?
    }

    struct Label: Equatable {
        var number: Int
        var baseline: CGFloat
        /// The lines the number stands for, for the current-line band.
        var frame: CGRect
        var isCurrent: Bool
    }

    /// Numbers follow `EditorScrollLineIndex`: only `\n` starts a line, as in scroll sync
    /// and the preview. A paragraph TextKit starts elsewhere (lone `\r`, U+2029) continues
    /// its source line and gets no number.
    static func labels(
        for fragments: [Fragment],
        lineIndex: EditorScrollLineIndex,
        selection: NSRange?
    ) -> [Label] {
        let currentLines = currentLineRange(for: selection, in: lineIndex)
        var labels: [Label] = []
        labels.reserveCapacity(fragments.count)
        for fragment in fragments {
            if let firstLine = fragment.firstLine,
               let number = lineNumber(startingAt: fragment.location, in: lineIndex)
            {
                labels.append(Label(
                    number: number,
                    baseline: firstLine.baseline,
                    frame: fragment.bodyFrame ?? firstLine.frame,
                    isCurrent: currentLines?.contains(number) == true
                ))
            }
            if let extraLine = fragment.extraLine,
               let number = lineNumber(startingAt: lineIndex.textUTF16Count, in: lineIndex)
            {
                labels.append(Label(
                    number: number,
                    baseline: extraLine.baseline,
                    frame: extraLine.frame,
                    isCurrent: currentLines?.contains(number) == true
                ))
            }
        }
        return labels
    }

    /// The source line that starts exactly at `offset`, if one does.
    static func lineNumber(startingAt offset: Int, in lineIndex: EditorScrollLineIndex) -> Int? {
        guard offset >= 0, offset <= lineIndex.textUTF16Count else { return nil }
        let line = lineIndex.oneBasedLine(containingUTF16Offset: offset)
        return lineIndex.utf16Offset(forOneBasedLine: line) == offset ? line : nil
    }

    /// Lines touched by the selection; a selection ending right after a line break does
    /// not touch the next line.
    static func currentLineRange(for selection: NSRange?, in lineIndex: EditorScrollLineIndex) -> ClosedRange<Int>? {
        guard let selection, selection.location != NSNotFound, selection.location >= 0 else {
            return nil
        }
        let first = lineIndex.oneBasedLine(containingUTF16Offset: selection.location)
        let last = selection.length > 0
            ? lineIndex.oneBasedLine(containingUTF16Offset: NSMaxRange(selection) - 1)
            : first
        return first ... max(first, last)
    }
}

/// Gutter width in digits. It grows as soon as the line count needs another digit, but
/// shrinks only once the count is well below the narrower width's limit, so typing or
/// deleting around 999/1000 lines does not re-wrap the document on every keystroke.
enum EditorLineNumberGutterDigits {
    static let minimum = 3

    static func required(forLineCount lineCount: Int) -> Int {
        max(minimum, String(max(lineCount, 1)).count)
    }

    static func next(forLineCount lineCount: Int, current: Int?) -> Int {
        let required = required(forLineCount: lineCount)
        guard let current, required < current else {
            return required
        }
        return lineCount < shrinkThreshold(below: current) ? required : current
    }

    /// 90% of the largest count the next narrower width can show.
    static func shrinkThreshold(below digits: Int) -> Int {
        var limit = 1
        for _ in 0 ..< max(digits - 1, 0) {
            limit *= 10
        }
        return limit * 9 / 10
    }
}
