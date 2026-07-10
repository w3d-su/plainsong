import Foundation

final class TextSearchInstrumentation {
    private(set) var literalCandidatesExamined = 0
    private(set) var lineUTF16UnitsVisited = 0
    private(set) var uncachedComposedUTF16UnitsVisited = 0
    private(set) var previewUTF16UnitsCopied = 0
    private(set) var literalSourceUTF16UnitsVisited = 0
    private(set) var literalKeyUTF16UnitsVisited = 0

    func recordCandidate() {
        literalCandidatesExamined += 1
    }

    func recordLineVisit(length: Int) {
        lineUTF16UnitsVisited += length
    }

    func recordComposedSequenceLoad(length: Int) {
        uncachedComposedUTF16UnitsVisited += length
    }

    func recordPreviewCopy(length: Int) {
        previewUTF16UnitsCopied += length
    }

    func recordLiteralVisit(sourceLength: Int, keyLength: Int) {
        literalSourceUTF16UnitsVisited += sourceLength
        literalKeyUTF16UnitsVisited += keyLength
    }
}

struct TextSearchScanner {
    let query: TextSearchQuery
    let limit: Int
    let contextGraphemes: Int

    private let storage: NSString
    private let instrumentation: TextSearchInstrumentation?
    private var lineCursor: TextSearchLineCursor?
    private var composedSequences: TextSearchComposedSequenceCache
    private var literalMatches: TextSearchLiteralCursor

    init(
        text: String,
        query: TextSearchQuery,
        limit: Int,
        previewContextGraphemes: Int,
        instrumentation: TextSearchInstrumentation?
    ) {
        let storage = text as NSString
        self.query = query
        self.limit = limit
        contextGraphemes = max(0, previewContextGraphemes)
        self.storage = storage
        self.instrumentation = instrumentation
        lineCursor = nil
        let caseSensitive = Self.resolvesCaseSensitive(query)
        composedSequences = TextSearchComposedSequenceCache(
            storage: storage,
            instrumentation: instrumentation
        )
        literalMatches = TextSearchLiteralCursor(
            storage: storage,
            pattern: query.pattern,
            caseSensitive: caseSensitive,
            wholeWord: query.wholeWord,
            useASCIIFastPath: TextSearchASCIIFastPath.supports(
                text: text,
                pattern: query.pattern,
                caseSensitive: caseSensitive
            ),
            instrumentation: instrumentation
        )
    }

    mutating func matches() -> [TextSearchMatch] {
        var results: [TextSearchMatch] = []
        results.reserveCapacity(min(limit, 64))
        var minimumLocation = 0

        while results.count < limit, minimumLocation < storage.length {
            guard let found = literalMatches.next(minimumLocation: minimumLocation) else { break }
            instrumentation?.recordCandidate()

            if query.wholeWord {
                if !isWholeWord(found) {
                    minimumLocation = nextWholeWordSearchLocation(after: found)
                    continue
                }
            }

            results.append(makeMatch(found))
            minimumLocation = found.location + max(found.length, 1)
        }

        return results
    }

    private static func resolvesCaseSensitive(_ query: TextSearchQuery) -> Bool {
        switch query.caseSensitivity {
        case .sensitive:
            true
        case .insensitive:
            false
        case .smart:
            query.pattern.unicodeScalars.contains { scalar in
                scalar.properties.isUppercase
                    || scalar.properties.generalCategory == .titlecaseLetter
            }
        }
    }

    private mutating func isWholeWord(_ range: NSRange) -> Bool {
        TextSearchWordBoundary.isWholeWordMatch(
            range,
            storage: storage,
            composedSequences: &composedSequences
        )
    }

    private mutating func nextWholeWordSearchLocation(after rejected: NSRange) -> Int {
        let nextLocation = rejected.location + 1
        guard nextLocation < storage.length else { return storage.length }

        let containing = composedSequences.range(containing: nextLocation)
        if containing.location != nextLocation {
            return NSMaxRange(containing)
        }

        // A valid whole-word match must begin at this composed boundary with a
        // non-word predecessor. Restarting there also keeps Foundation from
        // preferring a later collation-equivalent hit over an earlier valid one.
        return findNextEligibleWholeWordStart(from: nextLocation)
    }

    private mutating func findNextEligibleWholeWordStart(from start: Int) -> Int {
        var location = start
        while location < storage.length {
            while location < storage.length,
                  Self.isASCIIWord(storage.character(at: location - 1)),
                  Self.isASCIIWord(storage.character(at: location))
            {
                location += 1
            }
            guard location < storage.length else { return storage.length }

            let previous = composedSequences.range(containing: location - 1)
            if !TextSearchWordBoundary.isWordCharacter(in: previous, storage: storage) {
                return location
            }

            location = NSMaxRange(composedSequences.range(containing: location))
        }
        return storage.length
    }

    private static func isASCIIWord(_ unit: UInt16) -> Bool {
        (unit >= 48 && unit <= 57)
            || (unit >= 65 && unit <= 90)
            || (unit >= 97 && unit <= 122)
            || unit == 95
    }

    private mutating func makeMatch(_ range: NSRange) -> TextSearchMatch {
        if lineCursor == nil {
            lineCursor = TextSearchLineCursor(storage: storage, instrumentation: instrumentation)
        }
        lineCursor?.advance(toMatchLocation: range.location)
        guard let lineCursor else {
            preconditionFailure("line cursor must exist before building a search match")
        }
        let request = TextSearchPreviewRequest(
            storage: storage,
            matchRange: range,
            lineRange: NSRange(
                location: lineCursor.contentStart,
                length: lineCursor.contentEnd - lineCursor.contentStart
            ),
            contextGraphemes: contextGraphemes,
            instrumentation: instrumentation
        )
        let snippet = TextSearchPreview.make(request, composedSequences: &composedSequences)
        return TextSearchMatch(
            range: range,
            line: lineCursor.lineNumber,
            preview: snippet.preview,
            previewMatchRange: snippet.matchRange
        )
    }
}

struct TextSearchLineCursor {
    let storage: NSString
    let instrumentation: TextSearchInstrumentation?
    private(set) var lineNumber = 1
    private(set) var contentStart = 0
    private(set) var contentEnd = 0
    private var nextLineStart = 0

    init(storage: NSString, instrumentation: TextSearchInstrumentation?) {
        self.storage = storage
        self.instrumentation = instrumentation
        let bounds = Self.lineBounds(from: 0, storage: storage, instrumentation: instrumentation)
        contentEnd = bounds.contentEnd
        nextLineStart = bounds.nextLineStart
    }

    mutating func advance(toMatchLocation location: Int) {
        while location >= nextLineStart, nextLineStart < storage.length {
            lineNumber += 1
            contentStart = nextLineStart
            let bounds = Self.lineBounds(
                from: contentStart,
                storage: storage,
                instrumentation: instrumentation
            )
            contentEnd = bounds.contentEnd
            nextLineStart = bounds.nextLineStart
        }
    }

    private static func lineBounds(
        from start: Int,
        storage: NSString,
        instrumentation: TextSearchInstrumentation?
    ) -> (contentEnd: Int, nextLineStart: Int) {
        guard start < storage.length else { return (storage.length, storage.length) }

        var contentEnd = start
        while contentEnd < storage.length {
            let unit = storage.character(at: contentEnd)
            if unit == 10 || unit == 13 { break }
            contentEnd += 1
        }

        let nextLineStart = lineTerminatorEnd(from: contentEnd, storage: storage)
        instrumentation?.recordLineVisit(length: nextLineStart - start)
        return (contentEnd, nextLineStart)
    }

    private static func lineTerminatorEnd(from contentEnd: Int, storage: NSString) -> Int {
        guard contentEnd < storage.length else { return contentEnd }
        guard storage.character(at: contentEnd) == 13 else { return contentEnd + 1 }

        let afterCarriageReturn = contentEnd + 1
        if afterCarriageReturn < storage.length, storage.character(at: afterCarriageReturn) == 10 {
            return afterCarriageReturn + 1
        }
        return afterCarriageReturn
    }
}
