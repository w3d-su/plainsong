import Foundation
@testable import MarkdownCore
import XCTest

final class ExactSourceTextTests: XCTestCase {
    private let samples = [
        "",
        "a",
        "plain ascii\n",
        "e\u{301} vs \u{E9}",
        "中文 🧪 \0 tail",
        String(repeating: "段落 text\n", count: 5000),
    ]

    func testNativeCopyPreservesEveryUTF16CodeUnitAndIsNative() throws {
        for sample in samples {
            let storage = NSTextStorage(string: sample)
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
            let copy = try XCTUnwrap(ExactSourceText.nativeCopy(of: storage.mutableString))
            XCTAssertEqual(Array(copy.utf16), Array(("x" + sample).utf16))
            XCTAssertNotNil(copy.utf8.withContiguousStorageIfAvailable { _ in true }, "copy must be native")
        }
    }

    func testNativeCopyRefusesUnpairedSurrogatesInsteadOfReplacingThem() {
        let lone = NSString(characters: [0x61, 0xD83E, 0x62], length: 3)
        XCTAssertNil(ExactSourceText.nativeCopy(of: lone))
        let trailing = NSString(characters: [0x61, 0xDDEA], length: 2)
        XCTAssertNil(ExactSourceText.nativeCopy(of: trailing))
    }

    func testNativeCopyMatchesEveryRandomUTF16SequenceOrRefusesAnUnpairedSurrogate() throws {
        // Encoding boundaries, CJK, a valid pair and both lone halves, including at the ends.
        let pool: [[UInt16]] = [
            [0x61], [0x0A], [0x00], [0x7F], [0x80], [0xE9], [0x7FF], [0x800], [0x4E2D], [0xD7FF], [0xE000],
            [0xFFFD], [0xFFFF], [0xD83E, 0xDDEA], [0xD800, 0xDC00], [0xDBFF, 0xDFFF], [0xD83E], [0xDDEA],
        ]
        // A fixed linear congruential sequence, so a failure reproduces.
        var seed: UInt64 = 0x5EED_2026_1118
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        for _ in 0 ..< 2000 {
            var units: [UInt16] = []
            for _ in 0 ..< next(40) {
                units += pool[next(pool.count)]
            }
            // A plain NSString, and the text storage's own string class, which the editor passes.
            for text in [NSString(characters: units, length: units.count), Self.storageString(units)] {
                try Self.assertNativeCopy(of: text, matches: units)
            }
        }
    }

    func testNativeCopyKeepsASurrogatePairAtEveryOffsetOfALongStorageString() throws {
        // CoreFoundation reads a text storage's string in chunks; a pair may straddle one.
        let filler = Array(String(repeating: "a段", count: 1500).utf16)
        for offset in stride(from: 0, through: 1200, by: 1) {
            var units = filler
            units.insert(contentsOf: [0xD83E, 0xDDEA], at: offset)
            try Self.assertNativeCopy(of: Self.storageString(units), matches: units)
        }
        for offset in [0, 1, 63, 64, 1023, 1024, 2999] {
            var units = filler
            units.insert(0xD83E, at: offset)
            try Self.assertNativeCopy(of: Self.storageString(units), matches: units)
            units[offset] = 0xDDEA
            try Self.assertNativeCopy(of: Self.storageString(units), matches: units)
        }
    }

    /// A text storage string holding exactly `units`, unpaired surrogates included.
    private static func storageString(_ units: [UInt16]) -> NSString {
        let storage = NSTextStorage()
        // Lazy bridging hands the same NSString back to Foundation, so nothing is repaired.
        storage.mutableString.setString(NSString(characters: units, length: units.count) as String)
        return storage.mutableString
    }

    private static func assertNativeCopy(
        of text: NSString,
        matches units: [UInt16],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var stored = [UInt16](repeating: 0, count: text.length)
        text.getCharacters(&stored, range: NSRange(location: 0, length: text.length))
        XCTAssertEqual(stored, units, "the test string itself was altered", file: file, line: line)
        let copy = ExactSourceText.nativeCopy(of: text)
        if isWellFormedUTF16(units) {
            let native = try XCTUnwrap(copy, "valid \(units.count)-unit text refused", file: file, line: line)
            XCTAssertEqual(Array(native.utf16), units, file: file, line: line)
            XCTAssertNotNil(native.utf8.withContiguousStorageIfAvailable { _ in true }, file: file, line: line)
        } else {
            XCTAssertNil(copy, "unpaired surrogate in \(units.count)-unit text was copied", file: file, line: line)
        }
    }

    private static func isWellFormedUTF16(_ units: [UInt16]) -> Bool {
        var index = 0
        while index < units.count {
            let unit = units[index]
            if (0xD800 ..< 0xDC00).contains(unit) {
                guard index + 1 < units.count, (0xDC00 ..< 0xE000).contains(units[index + 1]) else { return false }
                index += 2
            } else if (0xDC00 ..< 0xE000).contains(unit) {
                return false
            } else {
                index += 1
            }
        }
        return true
    }

    func testNativeFastPathKeepsLiteralCodeUnitSemantics() {
        let composed = "\u{E9}"
        let decomposed = "e\u{301}"
        XCTAssertEqual(ExactSourceText.nativeUTF8Matches(composed, composed + ""), true)
        XCTAssertEqual(ExactSourceText.nativeUTF8Matches(composed, decomposed), false)
        XCTAssertEqual(ExactSourceText.nativeUTF8Matches("a\0b", "a\0b"), true)
        XCTAssertEqual(ExactSourceText.nativeUTF8Matches("a\0b", "a\0c"), false)
        XCTAssertFalse(ExactSourceText.matches(composed, decomposed))

        // Bridged strings take Foundation's literal comparison, alone or mixed.
        let bridged = NSTextStorage(string: "中文 \u{E9}").string
        XCTAssertNil(ExactSourceText.nativeUTF8Matches(bridged, "中文 \u{E9}"))
        XCTAssertTrue(ExactSourceText.matches(bridged, "中文 \u{E9}"))
        XCTAssertFalse(ExactSourceText.matches(bridged, "中文 e\u{301}"))
    }
}
