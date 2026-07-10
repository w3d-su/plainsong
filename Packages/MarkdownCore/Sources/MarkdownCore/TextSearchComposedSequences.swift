import Foundation

struct TextSearchComposedSequenceCache {
    private static let capacity = 8

    let storage: NSString
    let instrumentation: TextSearchInstrumentation?
    private var recentRanges: [NSRange] = []
    private var pinnedOversizedRanges: [NSRange] = []

    init(storage: NSString, instrumentation: TextSearchInstrumentation?) {
        self.storage = storage
        self.instrumentation = instrumentation
    }

    mutating func range(containing location: Int) -> NSRange {
        precondition(location >= 0 && location < storage.length)

        if let index = pinnedOversizedRanges.lastIndex(where: { $0.contains(location) }) {
            let pinned = pinnedOversizedRanges.remove(at: index)
            pinnedOversizedRanges.append(pinned)
            return pinned
        }
        if let index = recentRanges.lastIndex(where: { $0.contains(location) }) {
            let cached = recentRanges.remove(at: index)
            recentRanges.append(cached)
            return cached
        }

        let loaded = storage.rangeOfComposedCharacterSequence(at: location)
        instrumentation?.recordComposedSequenceLoad(length: loaded.length)
        if loaded.length > TextSearchEngine.maximumPreviewContextUTF16PerSide {
            pinnedOversizedRanges.append(loaded)
            if pinnedOversizedRanges.count > Self.capacity {
                pinnedOversizedRanges.removeFirst()
            }
            return loaded
        }
        recentRanges.append(loaded)
        if recentRanges.count > Self.capacity {
            recentRanges.removeFirst()
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

    static func isWordCharacter(in range: NSRange, storage: NSString) -> Bool {
        storage.substring(with: range).unicodeScalars.contains(where: isWordScalar)
    }

    static func isWordCharacter(in character: Character) -> Bool {
        character.unicodeScalars.contains(where: isWordScalar)
    }

    static func isWordCharacter(in string: String) -> Bool {
        string.unicodeScalars.contains(where: isWordScalar)
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0x5F { return true }
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
