import Foundation

/// Fixed-capacity set of recently loaded composed-character ranges.
///
/// Composed character sequences partition the storage, so at most one retained range can
/// contain a given location and any hit is *the* answer. Retention order therefore only
/// affects hit rate, never correctness. Eviction overwrites the oldest slot in place: the
/// previous `append` + `removeFirst` pair ran on every cache miss, and while skipping a
/// rejected whole-word run in a 1 MiB non-ASCII document that is one miss per character.
private struct TextSearchComposedRangeRing {
    private var slots: [NSRange]
    private var count = 0
    private var oldest = 0

    init(capacity: Int) {
        slots = Array(repeating: NSRange(location: NSNotFound, length: 0), count: capacity)
    }

    func range(containing location: Int) -> NSRange? {
        var index = 0
        while index < count {
            let candidate = slots[index]
            if location >= candidate.location, location - candidate.location < candidate.length {
                return candidate
            }
            index += 1
        }
        return nil
    }

    mutating func insert(_ range: NSRange) {
        slots[oldest] = range
        oldest = (oldest + 1) % slots.count
        if count < slots.count { count += 1 }
    }
}

struct TextSearchComposedSequenceCache {
    private static let capacity = 8

    let storage: NSString
    let instrumentation: TextSearchInstrumentation?
    private var recentRanges = TextSearchComposedRangeRing(capacity: capacity)
    private var pinnedOversizedRanges = TextSearchComposedRangeRing(capacity: capacity)
    /// Serves the marching linear scans, where the range containing `location - 1` is the
    /// one the previous step just loaded. Retained separately so that hit costs a single
    /// bounds check rather than a scan of both rings.
    private var mostRecentRange: NSRange?
    private var wordSegmentation: TextSearchWordSegmentation?

    init(storage: NSString, instrumentation: TextSearchInstrumentation?) {
        self.storage = storage
        self.instrumentation = instrumentation
    }

    /// Whether word segmentation places a boundary at composed boundary `location`. The
    /// segmenter is created on first use, so searches that never touch a script written
    /// without spaces never tokenize anything.
    mutating func isWordSegmentationBoundary(_ location: Int) -> Bool {
        if wordSegmentation == nil {
            wordSegmentation = TextSearchWordSegmentation(storage: storage, instrumentation: instrumentation)
        }
        return wordSegmentation!.isBoundary(location)
    }

    mutating func range(containing location: Int) -> NSRange {
        precondition(location >= 0 && location < storage.length)

        if let mostRecent = mostRecentRange, mostRecent.contains(location) {
            return mostRecent
        }
        if let pinned = pinnedOversizedRanges.range(containing: location) {
            mostRecentRange = pinned
            return pinned
        }
        if let cached = recentRanges.range(containing: location) {
            mostRecentRange = cached
            return cached
        }

        let loaded = storage.rangeOfComposedCharacterSequence(at: location)
        instrumentation?.recordComposedSequenceLoad(length: loaded.length)
        mostRecentRange = loaded
        if loaded.length > TextSearchEngine.maximumPreviewContextUTF16PerSide {
            pinnedOversizedRanges.insert(loaded)
        } else {
            recentRanges.insert(loaded)
        }
        return loaded
    }
}

enum TextSearchWordBoundary {
    /// A match is a whole word when both ends are composed-character boundaries and each
    /// end is a word edge (see `isWordEdge`).
    static func isWholeWordMatch(
        _ range: NSRange,
        storage: NSString,
        composedSequences: inout TextSearchComposedSequenceCache
    ) -> Bool {
        let matchEnd = range.location + range.length
        guard range.location >= 0, range.length > 0, matchEnd <= storage.length else {
            return false
        }
        guard isBoundary(range.location, storage: storage, cache: &composedSequences) else {
            return false
        }
        guard isBoundary(matchEnd, storage: storage, cache: &composedSequences) else {
            return false
        }
        guard isWordEdge(
            at: range.location,
            outside: range.location - 1,
            inside: range.location,
            storage: storage,
            cache: &composedSequences
        ) else {
            return false
        }
        return isWordEdge(
            at: matchEnd,
            outside: matchEnd,
            inside: matchEnd - 1,
            storage: storage,
            cache: &composedSequences
        )
    }

    /// Whether a whole word may start or end at `edge`, given the composed characters just
    /// outside the match (`outside`) and just inside it (`inside`).
    ///
    /// The edge holds when nothing or a non-word character lies outside. Otherwise it holds
    /// only where either character belongs to a script written without spaces between
    /// words (Han, kana, Thai, …) and word segmentation puts a boundary at the edge: there
    /// every letter is a word character, so the scalar rule alone would reject every match
    /// inside running text, such as 中文 in 我喜歡中文 or Swift in 使用Swift開發.
    private static func isWordEdge(
        at edge: Int,
        outside: Int,
        inside: Int,
        storage: NSString,
        cache: inout TextSearchComposedSequenceCache
    ) -> Bool {
        guard outside >= 0, outside < storage.length else { return true }
        let outsideRange = cache.range(containing: outside)
        guard isWordCharacter(in: outsideRange, storage: storage) else { return true }
        let insideRange = cache.range(containing: inside)
        guard usesWordSegmentation(in: outsideRange, storage: storage)
            || usesWordSegmentation(in: insideRange, storage: storage)
        else {
            return false
        }
        return cache.isWordSegmentationBoundary(edge)
    }

    private static func isBoundary(
        _ location: Int,
        storage: NSString,
        cache: inout TextSearchComposedSequenceCache
    ) -> Bool {
        if location == 0 || location == storage.length { return true }
        return cache.range(containing: location).location == location
    }

    /// Whether `range` holds a scalar of a script written without spaces between words,
    /// whose word boundaries come from segmentation rather than from the scalar rule.
    /// Decodes in place like `isWordCharacter(in:storage:)`.
    static func usesWordSegmentation(in range: NSRange, storage: NSString) -> Bool {
        var location = range.location
        let end = NSMaxRange(range)
        while location < end {
            let unit = storage.character(at: location)
            location += 1

            if let scalar = Unicode.Scalar(unit) {
                if usesWordSegmentation(scalar) { return true }
                continue
            }
            guard UTF16.isLeadSurrogate(unit), location < end else { continue }
            let trail = storage.character(at: location)
            guard UTF16.isTrailSurrogate(trail) else { continue }
            location += 1

            let value = 0x10000
                + (UInt32(unit - 0xD800) << 10)
                + UInt32(trail - 0xDC00)
            guard let scalar = Unicode.Scalar(value) else { continue }
            if usesWordSegmentation(scalar) { return true }
        }
        return false
    }

    /// Han ideographs (and the ideographic iteration marks and numerals), Hiragana,
    /// Katakana, Thai, Lao, Myanmar and Khmer: the scripts ICU segments with dictionaries.
    /// Hangul is not included: Korean separates words with spaces, as UAX #29 assumes.
    static func usesWordSegmentation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0 ..< 0x0E00:
            false
        case 0x0E00 ... 0x0EFF, // Thai, Lao
             0x1000 ... 0x109F, // Myanmar
             0x1780 ... 0x17FF, // Khmer
             0x3005 ... 0x3007, 0x3021 ... 0x3029, 0x3038 ... 0x303C, // 々〆〇, numerals, 〻〼
             0x3040 ... 0x30FF, // Hiragana, Katakana
             0x31F0 ... 0x31FF, // Katakana Phonetic Extensions
             0xFF66 ... 0xFF9F: // Halfwidth Katakana
            true
        case 0x0F00 ..< 0x2E80:
            false
        default:
            scalar.properties.isIdeographic
        }
    }

    /// Decodes `range` straight out of `storage` instead of materializing a substring.
    /// This runs once per composed character while skipping a rejected whole-word run,
    /// so allocating a `String` per character dominated 1 MiB non-ASCII searches.
    ///
    /// Equivalent to `storage.substring(with: range).unicodeScalars.contains(where:)`:
    /// a well-formed range decodes to the same scalars, and a range that splits a
    /// surrogate pair yields U+FFFD from `substring(with:)`, which is not a word scalar
    /// either — so skipping the unpaired unit reaches the same answer.
    static func isWordCharacter(in range: NSRange, storage: NSString) -> Bool {
        var location = range.location
        let end = NSMaxRange(range)
        while location < end {
            let unit = storage.character(at: location)
            location += 1

            if let scalar = Unicode.Scalar(unit) {
                if isWordScalar(scalar) { return true }
                continue
            }
            guard UTF16.isLeadSurrogate(unit), location < end else { continue }
            let trail = storage.character(at: location)
            guard UTF16.isTrailSurrogate(trail) else { continue }
            location += 1

            let value = 0x10000
                + (UInt32(unit - 0xD800) << 10)
                + UInt32(trail - 0xDC00)
            guard let scalar = Unicode.Scalar(value) else { continue }
            if isWordScalar(scalar) { return true }
        }
        return false
    }

    static func isWordCharacter(in character: Character) -> Bool {
        character.unicodeScalars.contains(where: isWordScalar)
    }

    static func isWordCharacter(in string: String) -> Bool {
        string.unicodeScalars.contains(where: isWordScalar)
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0x5F { return true }
        // ASCII resolves without an ICU general-category lookup, and to the same answer:
        // digits are decimalNumber, letters are upper/lowercaseLetter, and no other ASCII
        // scalar falls in a category below.
        if scalar.value < 0x80 {
            return (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter,
             .otherLetter, .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }
}

private extension NSRange {
    func contains(_ location: Int) -> Bool {
        location >= self.location && location < self.location + length
    }
}
