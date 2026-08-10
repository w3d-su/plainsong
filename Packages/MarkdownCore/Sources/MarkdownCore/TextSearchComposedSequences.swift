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

    init(storage: NSString, instrumentation: TextSearchInstrumentation?) {
        self.storage = storage
        self.instrumentation = instrumentation
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
        guard !isWordCharacter(before: range.location, storage: storage, cache: &composedSequences) else {
            return false
        }
        return !isWordCharacter(at: matchEnd, storage: storage, cache: &composedSequences)
    }

    private static func isBoundary(
        _ location: Int,
        storage: NSString,
        cache: inout TextSearchComposedSequenceCache
    ) -> Bool {
        if location == 0 || location == storage.length { return true }
        return cache.range(containing: location).location == location
    }

    private static func isWordCharacter(
        before location: Int,
        storage: NSString,
        cache: inout TextSearchComposedSequenceCache
    ) -> Bool {
        guard location > 0 else { return false }
        return isWordCharacter(
            in: cache.range(containing: location - 1),
            storage: storage
        )
    }

    private static func isWordCharacter(
        at location: Int,
        storage: NSString,
        cache: inout TextSearchComposedSequenceCache
    ) -> Bool {
        guard location < storage.length else { return false }
        return isWordCharacter(in: cache.range(containing: location), storage: storage)
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
