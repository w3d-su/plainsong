@testable import EditorKit
import Foundation
import XCTest

final class ExactUTF16TextTests: XCTestCase {
    func testCanonicalEquivalentReorderedCombiningMarksAreNotExactUTF16Matches() {
        let acuteThenCedilla = "a\u{301}\u{327}"
        let cedillaThenAcute = "a\u{327}\u{301}"

        XCTAssertEqual(acuteThenCedilla, cedillaThenAcute)
        XCTAssertEqual(acuteThenCedilla.utf16.count, cedillaThenAcute.utf16.count)
        XCTAssertFalse(ExactUTF16Text.matches(acuteThenCedilla, cedillaThenAcute))
        XCTAssertNotEqual(Array(acuteThenCedilla.utf16), Array(cedillaThenAcute.utf16))
        XCTAssertNotEqual(Data(acuteThenCedilla.utf8), Data(cedillaThenAcute.utf8))
    }
}
