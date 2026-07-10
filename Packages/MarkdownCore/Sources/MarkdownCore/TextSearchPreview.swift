import Foundation

struct TextSearchPreviewSnippet {
    let preview: String
    let matchRange: NSRange
}

struct TextSearchPreviewRequest {
    let storage: NSString
    let matchRange: NSRange
    let lineRange: NSRange
    let contextGraphemes: Int
    let instrumentation: TextSearchInstrumentation?
}

enum TextSearchPreview {
    private struct CoreBounds {
        let left: Int
        let right: Int
    }

    static func make(
        _ request: TextSearchPreviewRequest,
        composedSequences: inout TextSearchComposedSequenceCache
    ) -> TextSearchPreviewSnippet {
        let lineStart = min(max(request.lineRange.location, 0), request.storage.length)
        let requestedLineEnd = request.lineRange.location + request.lineRange.length
        let lineEnd = min(max(requestedLineEnd, lineStart), request.storage.length)
        let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
        let exactMatch = clamped(request.matchRange, to: request.storage.length)
        let enclosing = enclosingRange(
            exactMatch,
            lineStart: lineStart,
            lineEnd: lineEnd,
            cache: &composedSequences
        )
        let core = boundedCore(
            exactMatch: exactMatch,
            enclosing: enclosing,
            lineRange: lineRange,
            contextGraphemes: request.contextGraphemes,
            cache: &composedSequences
        )
        return assemble(
            request: request,
            exactMatch: exactMatch,
            core: core,
            lineRange: lineRange
        )
    }

    private static func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let start = min(max(range.location, 0), length)
        let end = min(max(range.location + range.length, start), length)
        return NSRange(location: start, length: end - start)
    }

    private static func enclosingRange(
        _ match: NSRange,
        lineStart: Int,
        lineEnd: Int,
        cache: inout TextSearchComposedSequenceCache
    ) -> NSRange {
        guard match.length > 0 else { return match }
        let first = cache.range(containing: match.location)
        let last = cache.range(containing: match.location + match.length - 1)
        let start = max(first.location, lineStart)
        let end = min(last.location + last.length, lineEnd)
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func boundedCore(
        exactMatch: NSRange,
        enclosing: NSRange,
        lineRange: NSRange,
        contextGraphemes: Int,
        cache: inout TextSearchComposedSequenceCache
    ) -> CoreBounds {
        let matchEnd = exactMatch.location + exactMatch.length
        let enclosingEnd = enclosing.location + enclosing.length
        let cap = TextSearchEngine.maximumPreviewContextUTF16PerSide
        let enclosedLeft = exactMatch.location - enclosing.location
        let enclosedRight = enclosingEnd - matchEnd
        let baseLeft = enclosedLeft <= cap ? enclosing.location : exactMatch.location
        let baseRight = enclosedRight <= cap ? enclosingEnd : matchEnd

        let left = expandBackward(
            from: baseLeft,
            to: lineRange.location,
            graphemeLimit: contextGraphemes,
            utf16Budget: cap - min(enclosedLeft, cap),
            cache: &cache
        )
        let right = expandForward(
            from: baseRight,
            to: lineRange.location + lineRange.length,
            graphemeLimit: contextGraphemes,
            utf16Budget: cap - min(enclosedRight, cap),
            cache: &cache
        )
        return CoreBounds(left: left, right: right)
    }

    private static func expandBackward(
        from start: Int,
        to limit: Int,
        graphemeLimit: Int,
        utf16Budget: Int,
        cache: inout TextSearchComposedSequenceCache
    ) -> Int {
        var cursor = start
        var remainingGraphemes = graphemeLimit
        var remainingUTF16 = utf16Budget
        while remainingGraphemes > 0, remainingUTF16 > 0, cursor > limit {
            let previous = cache.range(containing: cursor - 1)
            guard previous.location >= limit else { break }
            let step = cursor - previous.location
            guard step <= remainingUTF16 else { break }
            cursor = previous.location
            remainingGraphemes -= 1
            remainingUTF16 -= step
        }
        return cursor
    }

    private static func expandForward(
        from start: Int,
        to limit: Int,
        graphemeLimit: Int,
        utf16Budget: Int,
        cache: inout TextSearchComposedSequenceCache
    ) -> Int {
        var cursor = start
        var remainingGraphemes = graphemeLimit
        var remainingUTF16 = utf16Budget
        while remainingGraphemes > 0, remainingUTF16 > 0, cursor < limit {
            let next = cache.range(containing: cursor)
            let nextEnd = next.location + next.length
            guard nextEnd <= limit else { break }
            let step = nextEnd - cursor
            guard step <= remainingUTF16 else { break }
            cursor = nextEnd
            remainingGraphemes -= 1
            remainingUTF16 -= step
        }
        return cursor
    }

    private static func assemble(
        request: TextSearchPreviewRequest,
        exactMatch: NSRange,
        core: CoreBounds,
        lineRange: NSRange
    ) -> TextSearchPreviewSnippet {
        let truncatedLeft = core.left > lineRange.location
        let truncatedRight = core.right < lineRange.location + lineRange.length
        let coreRange = NSRange(location: core.left, length: core.right - core.left)
        request.instrumentation?.recordPreviewCopy(length: coreRange.length)

        let leading = truncatedLeft ? TextSearchEngine.previewEllipsis : ""
        let trailing = truncatedRight ? TextSearchEngine.previewEllipsis : ""
        let preview = leading + request.storage.substring(with: coreRange) + trailing
        let leadingLength = (leading as NSString).length
        let previewMatch = NSRange(
            location: leadingLength + exactMatch.location - core.left,
            length: exactMatch.length
        )
        return TextSearchPreviewSnippet(preview: preview, matchRange: previewMatch)
    }
}
