@testable import MarkdownCore
import XCTest

/// Covers the scalar decoding and caching that whole-word boundary detection relies on.
///
/// `isWordCharacter(in:storage:)` decodes UTF-16 out of the storage directly rather than
/// materializing a substring, so these differential tests pin it to the substring-based
/// `isWordCharacter(in: String)` overload that expresses the original behavior.
final class TextSearchWordBoundaryScalarTests: XCTestCase {
    private func assertMatchesSubstringReference(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertMatchesSubstringReference(text as NSString, file: file, line: line)
    }

    private func assertMatchesSubstringReference(
        _ storage: NSString,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var location = 0
        while location < storage.length {
            let range = storage.rangeOfComposedCharacterSequence(at: location)
            XCTAssertEqual(
                TextSearchWordBoundary.isWordCharacter(in: range, storage: storage),
                TextSearchWordBoundary.isWordCharacter(in: storage.substring(with: range)),
                "composed range \(range) of \(storage.debugDescription)",
                file: file,
                line: line
            )
            location = NSMaxRange(range)
        }
    }

    func testEveryASCIIScalarAgreesWithTheSubstringReference() {
        let ascii = String(String.UnicodeScalarView((0 ..< 128).compactMap(Unicode.Scalar.init)))
        XCTAssertEqual(ascii.unicodeScalars.count, 128)
        assertMatchesSubstringReference(ascii)
    }

    /// The substring reference above shares `isWordScalar`, so it cannot see a bug in the
    /// ASCII shortcut inside it. This oracle is the general-category rule the shortcut is
    /// supposed to reproduce, restated independently.
    func testEveryASCIIScalarAgreesWithTheGeneralCategoryRule() {
        for value in 0 ..< 128 {
            guard let scalar = Unicode.Scalar(UInt16(value)) else {
                return XCTFail("U+\(String(value, radix: 16)) is not a scalar")
            }
            let isWordCategory = switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter,
                 .otherLetter, .decimalNumber, .letterNumber, .otherNumber:
                true
            default:
                false
            }
            let storage = String(scalar) as NSString
            XCTAssertEqual(storage.length, 1)
            XCTAssertEqual(
                TextSearchWordBoundary.isWordCharacter(
                    in: NSRange(location: 0, length: 1),
                    storage: storage
                ),
                isWordCategory || scalar.value == 0x5F,
                "U+\(String(format: "%04X", value))"
            )
        }
    }

    func testAstralAndCombiningScalarsAgreeWithTheSubstringReference() {
        // Astral letters and digits are word characters; astral symbols are not. Combining
        // sequences exercise the multi-unit loop, and a lone lead surrogate exercises the
        // unpaired branch, which `substring(with:)` reports as U+FFFD.
        assertMatchesSubstringReference("𝐀𝟎😀🙂\u{1F1E6}\u{1F1E8}e\u{0301}_\u{FE0F}가 a1_.")
        // Swift string literals cannot hold unpaired surrogates, but an NSString can, and
        // the search engine reads its storage as an NSString.
        assertMatchesSubstringReference(Self.makeNSString([0xD800]))
        assertMatchesSubstringReference(Self.makeNSString([0x61, 0xD800, 0x62]))
        assertMatchesSubstringReference(Self.makeNSString([0x61, 0xDC00, 0x62]))
    }

    func testUnpairedSurrogateIsNotAWordCharacter() {
        for units: [UInt16] in [[0xD800], [0xDC00]] {
            let storage = Self.makeNSString(units)
            XCTAssertEqual(storage.length, 1)
            XCTAssertFalse(
                TextSearchWordBoundary.isWordCharacter(
                    in: NSRange(location: 0, length: 1),
                    storage: storage
                )
            )
        }
    }

    func testRangeSplittingASurrogatePairIsNotAWordCharacter() {
        let storage = "𝐀" as NSString
        XCTAssertEqual(storage.length, 2)
        for range in [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1)] {
            XCTAssertFalse(
                TextSearchWordBoundary.isWordCharacter(in: range, storage: storage),
                "half of a surrogate pair is not a word character: \(range)"
            )
        }
        XCTAssertTrue(
            TextSearchWordBoundary.isWordCharacter(
                in: NSRange(location: 0, length: 2),
                storage: storage
            )
        )
    }

    func testAstralLetterAdjacentToACandidateBlocksTheWholeWordMatch() {
        let text = "𝐀foo foo foo𝟎"
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "foo", caseSensitivity: .sensitive, wholeWord: true),
            limit: 10
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(
            (text as NSString).substring(with: matches[0].range),
            "foo"
        )
        XCTAssertEqual(matches[0].range.location, (text as NSString).range(of: " foo ").location + 1)
    }

    func testAstralSymbolAdjacentToACandidateAllowsTheWholeWordMatch() {
        let text = "😀foo😀"
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "foo", caseSensitivity: .sensitive, wholeWord: true),
            limit: 10
        )

        XCTAssertEqual(matches.map(\.range), [(text as NSString).range(of: "foo")])
    }

    func testComposedSequenceCacheReturnsFoundationRangesBeyondItsCapacity() {
        // Distinct composed sequences, comfortably past the eight-slot retention, walked
        // forward and then revisited so retention and eviction are both exercised.
        let text = "a\u{0301}b\u{0302}c\u{0303}d\u{0304}e\u{0305}f\u{0306}g\u{0307}"
            + "h\u{0308}i\u{0309}j\u{030A}k\u{030B}l\u{030C}😀m가"
        let storage = text as NSString
        var cache = TextSearchComposedSequenceCache(storage: storage, instrumentation: nil)

        var starts: [Int] = []
        var location = 0
        while location < storage.length {
            let range = storage.rangeOfComposedCharacterSequence(at: location)
            starts.append(location)
            location = NSMaxRange(range)
        }
        XCTAssertGreaterThan(starts.count, 8)

        for start in starts + starts.reversed() + starts {
            let expected = storage.rangeOfComposedCharacterSequence(at: start)
            XCTAssertEqual(cache.range(containing: start), expected, "start \(start)")
            for interior in start ..< NSMaxRange(expected) {
                XCTAssertEqual(cache.range(containing: interior), expected, "interior \(interior)")
            }
        }
    }

    func testComposedSequenceCacheCountsOnlyUncachedLoads() {
        let text = "a\u{0301}bc"
        let storage = text as NSString
        let instrumentation = TextSearchInstrumentation()
        var cache = TextSearchComposedSequenceCache(
            storage: storage,
            instrumentation: instrumentation
        )

        XCTAssertEqual(cache.range(containing: 0), NSRange(location: 0, length: 2))
        XCTAssertEqual(instrumentation.uncachedComposedUTF16UnitsVisited, 2)

        // Repeat lookups inside the same composed sequence must not reload it.
        XCTAssertEqual(cache.range(containing: 1), NSRange(location: 0, length: 2))
        XCTAssertEqual(cache.range(containing: 0), NSRange(location: 0, length: 2))
        XCTAssertEqual(instrumentation.uncachedComposedUTF16UnitsVisited, 2)

        XCTAssertEqual(cache.range(containing: 2), NSRange(location: 2, length: 1))
        XCTAssertEqual(instrumentation.uncachedComposedUTF16UnitsVisited, 3)

        // Returning to an already retained sequence still must not reload it.
        XCTAssertEqual(cache.range(containing: 0), NSRange(location: 0, length: 2))
        XCTAssertEqual(instrumentation.uncachedComposedUTF16UnitsVisited, 3)
    }

    private static func makeNSString(_ units: [UInt16]) -> NSString {
        NSString(characters: units, length: units.count)
    }
}
