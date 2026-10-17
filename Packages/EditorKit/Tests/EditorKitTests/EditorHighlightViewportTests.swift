@testable import EditorKit
import Foundation
import XCTest

@MainActor
final class EditorHighlightViewportTests: XCTestCase {
    func testSmallScrollsReusePendingAndCompletedHighlightWindowsInBothDirections() {
        let viewport = EditorHighlightViewport()
        XCTAssertTrue(viewport.update(NSRange(location: 10000, length: 2000)))
        viewport.beginRequest(selection: nil)
        XCTAssertEqual(viewport.requestedRange, NSRange(location: 8976, length: 4048))
        for location in stride(from: 10000, through: 11000, by: 100) {
            XCTAssertFalse(viewport.update(NSRange(location: location, length: 2000)))
        }
        viewport.didComplete(range: NSRange(location: 8900, length: 4300))
        XCTAssertFalse(viewport.update(NSRange(location: 9000, length: 2000)))
        XCTAssertTrue(viewport.update(NSRange(location: 8800, length: 2000)))
    }

    func testEditsAndSettingsAlwaysStartFreshRequestsAtLatestObservedViewport() {
        let viewport = EditorHighlightViewport()
        _ = viewport.update(NSRange(location: 10000, length: 2000))
        viewport.beginRequest(selection: nil)
        viewport.didComplete(range: NSRange(location: 0, length: 20000))
        XCTAssertFalse(viewport.update(NSRange(location: 11000, length: 2000)))
        viewport.beginRequest(selection: nil)
        XCTAssertEqual(viewport.requestedRange, NSRange(location: 9976, length: 4048))
        XCTAssertTrue(viewport.update(NSRange(location: 15000, length: 2000)))
    }

    func testInvalidOrTransientEmptyViewportsDoNotLoseLatestLocation() {
        let viewport = EditorHighlightViewport()
        _ = viewport.update(NSRange(location: 10000, length: 2000))
        XCTAssertFalse(viewport.update(NSRange(location: NSNotFound, length: 0)))
        XCTAssertFalse(viewport.update(NSRange(location: 0, length: 0)))
        XCTAssertFalse(viewport.update(NSRange(location: Int.max - 1, length: 10)))
        XCTAssertEqual(viewport.visibleRange, NSRange(location: 10000, length: 2000))
    }

    func testPaddingIsBoundedAndDoesNotOverflow() {
        XCTAssertEqual(EditorHighlightViewport.padded(NSRange(location: 0, length: 1000)),
                       NSRange(location: 0, length: 2024))
        XCTAssertEqual(EditorHighlightViewport.padded(NSRange(location: 10000, length: 50000)),
                       NSRange(location: 5904, length: 58192))
        let tail = EditorHighlightViewport.padded(NSRange(location: Int.max - 20, length: 10))
        XCTAssertEqual(NSMaxRange(tail), Int.max)
    }
}
