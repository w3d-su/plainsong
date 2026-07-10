import Foundation

enum TextSearchASCIIFastPath {
    static func supports(text: String, pattern: String, caseSensitive: Bool) -> Bool {
        guard pattern.utf8.allSatisfy({ $0 < 0x80 }) else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.value < 0x80 || isTransparentSymbol(scalar, caseSensitive: caseSensitive)
        }
    }

    private static func isTransparentSymbol(
        _ scalar: Unicode.Scalar,
        caseSensitive: Bool
    ) -> Bool {
        switch scalar.properties.generalCategory {
        case .otherSymbol:
            break
        default:
            return false
        }
        guard !scalar.properties.isDefaultIgnorableCodePoint else { return false }

        let source = String(scalar)
        let comparable = caseSensitive
            ? source.decomposedStringWithCanonicalMapping
            : source.folding(options: [.caseInsensitive], locale: nil)
            .decomposedStringWithCompatibilityMapping
        return !comparable.isEmpty
            && comparable.unicodeScalars.allSatisfy { $0.value >= 0x80 }
    }
}

struct TextSearchLiteralCursor {
    private enum Backend {
        case foundation
        case ascii(TextSearchASCIILiteralCursor)
    }

    private let storage: NSString
    private let pattern: String
    private let options: NSString.CompareOptions
    private var backend: Backend

    init(
        storage: NSString,
        pattern: String,
        caseSensitive: Bool,
        wholeWord: Bool,
        useASCIIFastPath: Bool,
        instrumentation: TextSearchInstrumentation?
    ) {
        self.storage = storage
        self.pattern = pattern
        options = caseSensitive ? [] : [.caseInsensitive]
        if useASCIIFastPath {
            backend = .ascii(
                TextSearchASCIILiteralCursor(
                    storage: storage,
                    pattern: pattern,
                    caseSensitive: caseSensitive,
                    wholeWord: wholeWord,
                    instrumentation: instrumentation
                )
            )
        } else {
            backend = .foundation
        }
    }

    mutating func next(minimumLocation: Int) -> NSRange? {
        switch backend {
        case .foundation:
            return nextFoundationMatch(from: minimumLocation)
        case var .ascii(cursor):
            let match = cursor.next(minimumLocation: minimumLocation)
            backend = .ascii(cursor)
            return match
        }
    }

    private func nextFoundationMatch(from location: Int) -> NSRange? {
        let searchRange = NSRange(location: location, length: storage.length - location)
        let found = storage.range(of: pattern, options: options, range: searchRange)
        return found.location == NSNotFound ? nil : found
    }
}

private struct TextSearchASCIILiteralCursor {
    let storage: NSString
    let pattern: [UInt16]
    let prefixTable: [Int]
    let caseSensitive: Bool
    let wholeWord: Bool
    let instrumentation: TextSearchInstrumentation?

    private var sourceLocation = 0
    private var matchedLength = 0

    init(
        storage: NSString,
        pattern: String,
        caseSensitive: Bool,
        wholeWord: Bool,
        instrumentation: TextSearchInstrumentation?
    ) {
        self.storage = storage
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.instrumentation = instrumentation
        let units = pattern.utf16.map { Self.fold($0, caseSensitive: caseSensitive) }
        self.pattern = units
        prefixTable = Self.makePrefixTable(for: units)
    }

    mutating func next(minimumLocation: Int) -> NSRange? {
        guard !pattern.isEmpty else { return nil }

        var unitsVisited = 0
        while sourceLocation < storage.length {
            let sourceUnit = Self.fold(
                storage.character(at: sourceLocation),
                caseSensitive: caseSensitive
            )
            while matchedLength > 0, sourceUnit != pattern[matchedLength] {
                matchedLength = prefixTable[matchedLength - 1]
            }
            if sourceUnit == pattern[matchedLength] {
                matchedLength += 1
            }
            sourceLocation += 1
            unitsVisited += 1

            guard matchedLength == pattern.count else { continue }
            let match = NSRange(location: sourceLocation - pattern.count, length: pattern.count)
            matchedLength = prefixTable[matchedLength - 1]
            if match.location >= minimumLocation, isEligible(match) {
                instrumentation?.recordLiteralVisit(
                    sourceLength: unitsVisited,
                    keyLength: unitsVisited
                )
                return match
            }
        }

        instrumentation?.recordLiteralVisit(sourceLength: unitsVisited, keyLength: unitsVisited)
        return nil
    }

    private func isEligible(_ range: NSRange) -> Bool {
        guard wholeWord else { return true }
        let before = range.location - 1
        let after = NSMaxRange(range)
        return (before < 0 || !Self.isASCIIWord(storage.character(at: before)))
            && (after >= storage.length || !Self.isASCIIWord(storage.character(at: after)))
    }

    private static func makePrefixTable(for pattern: [UInt16]) -> [Int] {
        guard !pattern.isEmpty else { return [] }
        var table = Array(repeating: 0, count: pattern.count)
        var prefixLength = 0
        for index in 1 ..< pattern.count {
            while prefixLength > 0, pattern[index] != pattern[prefixLength] {
                prefixLength = table[prefixLength - 1]
            }
            if pattern[index] == pattern[prefixLength] {
                prefixLength += 1
                table[index] = prefixLength
            }
        }
        return table
    }

    private static func fold(_ unit: UInt16, caseSensitive: Bool) -> UInt16 {
        guard !caseSensitive, unit >= 65, unit <= 90 else { return unit }
        return unit + 32
    }

    private static func isASCIIWord(_ unit: UInt16) -> Bool {
        (unit >= 48 && unit <= 57)
            || (unit >= 65 && unit <= 90)
            || (unit >= 97 && unit <= 122)
            || unit == 95
    }
}
