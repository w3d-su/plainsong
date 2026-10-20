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
